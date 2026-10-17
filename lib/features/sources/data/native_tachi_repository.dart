import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';

import '../../../core/diagnostics/diagnostic_error_type.dart';
import '../../../core/diagnostics/diagnostic_log.dart';

import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:tachi_runtime/tachi_runtime.dart';

import '../domain/catalogue.dart';
import '../domain/native_source_engine.dart';
import '../domain/source_filters.dart';
import '../domain/extension_backup.dart';
import 'extension_mutation_queue.dart';
import 'source_cover_cache.dart';

typedef NativeTachiExecutor = Future<String> Function(String request);
typedef NativeTachiBrowser = Future<Map<String, dynamic>> Function(String url);

/// APK bytes are stored locally and interpreted by the bundled Java runtime.
class NativeTachiRepository
    implements
        NativeSourceEngine,
        NativeImageEngine,
        NativeCoverImageEngine,
        NativeCoverCacheEngine,
        NativeSourceBrowserEngine,
        NativeSourceMaintenanceEngine,
        NativeCatalogueBrowserEngine,
        NativeExtensionManagementEngine,
        NativeExtensionFileEngine,
        NativeSourceFilterEngine,
        NativeExtensionBackupEngine,
        NativeExtensionBackupTransaction {
  NativeTachiRepository({
    NativeTachiExecutor? executor,
    NativeTachiBrowser? browser,
    http.Client? client,
    Directory? storageDirectory,
    this.iconForPackage,
    this.canCacheCover,
    this.coverCacheEpoch,
  }) : _execute = executor ?? const TachiRuntime().invoke,
       _openBrowser = browser ?? const TachiRuntime().openBrowser,
       _client = client ?? http.Client(),
       _ownsClient = client == null,
       _directory = storageDirectory;

  final NativeTachiExecutor _execute;
  final NativeTachiBrowser _openBrowser;
  final http.Client _client;
  final bool _ownsClient;
  final String Function(String packageUrl)? iconForPackage;
  final bool Function()? canCacheCover;
  final int Function()? coverCacheEpoch;
  Future<SourceCoverCache>? _coverCache;
  final _pendingCovers = <String, Future<SourceImageData>>{};
  Future<SourceCoverCache> _coverStorage() => _coverCache ??= () async {
    final directory = await _storage();
    return SourceCoverCache(Directory('${directory.path}/cover-cache'));
  }();
  Directory? _directory;
  Future<void>? _initialization;
  bool _initialized = false;
  final _pageRequests = <Future<void> Function()>[];
  final _coverRequests = <Future<void> Function()>[];
  bool _loadingImage = false;
  int _loadingCovers = 0;

  // Keep at most one request on JNI. A library grid can enqueue hundreds of
  // covers; a chapter opened afterwards must not wait behind all of them.
  Future<SourceImageData> _enqueueImage(
    Future<SourceImageData> Function() load, {
    required bool cover,
  }) {
    final result = Completer<SourceImageData>();
    (cover ? _coverRequests : _pageRequests).add(() async {
      try {
        if (_disposed) throw StateError('Engine đã đóng.');
        result.complete(await load());
      } catch (error, stack) {
        result.completeError(error, stack);
      }
    });
    _pumpImages();
    return result.future;
  }

  void _pumpImages() {
    if (_loadingImage) return;
    if (_pageRequests.isNotEmpty) {
      if (_loadingCovers > 0) return;
      _loadingImage = true;
      unawaited(
        _pageRequests.removeAt(0)().whenComplete(() {
          _loadingImage = false;
          _pumpImages();
        }),
      );
      return;
    }
    while (_loadingCovers < 2 && _coverRequests.isNotEmpty) {
      _loadingCovers++;
      unawaited(
        _coverRequests.removeAt(0)().whenComplete(() {
          _loadingCovers--;
          _pumpImages();
        }),
      );
    }
  }

  bool _disposed = false;
  final Map<String, List<String>> _preferenceKeys = {};
  final _verifiedBookRefs = <String, String>{};

  Future<Directory> _storage() async => _directory ??= Directory(
    '${(await getApplicationSupportDirectory()).path}/TachiBooks/extension-runtime',
  );

  @override
  Future<T> exclusiveExtensionBackup<T>(Future<T> Function() action) async {
    final path = (await _storage()).absolute.uri.normalizePath().toFilePath();
    return ExtensionMutationQueue.run(
      'tachi:${Platform.isWindows ? path.toLowerCase() : path}',
      action,
    );
  }

  Future<dynamic> _request(String method, Map<String, dynamic> args) async {
    if ({
      'initialize',
      'install',
      'uninstall',
      'setPreference',
      'browserSession',
      'clearCookies',
      'clearSourceCache',
    }.contains(method)) {
      _verifiedBookRefs.clear();
      return exclusiveExtensionBackup(() => _requestUnlocked(method, args));
    }
    return _requestUnlocked(method, args);
  }

  Future<dynamic> _requestUnlocked(
    String method,
    Map<String, dynamic> args,
  ) async {
    try {
      final raw = await _execute(jsonEncode({'method': method, 'args': args}))
          .timeout(const Duration(seconds: 90));
      final value = _map(jsonDecode(raw));
      if (value['ok'] != true) {
        final error = value['error'] is Map
            ? _map(value['error'])
            : const <String, dynamic>{};
        throw ApiException(
          error['message'] is String
              ? error['message'] as String
              : 'Engine không thực hiện được yêu cầu.',
          code: error['code'] is String
              ? error['code'] as String
              : 'TACHI_RUNTIME_FAILED',
          diagnosticType: canonicalDiagnosticType(error['type']),
          statusCode:
              error['httpStatus'] is int &&
                  (error['httpStatus'] as int) >= 100 &&
                  (error['httpStatus'] as int) <= 599
              ? error['httpStatus'] as int
              : null,
        );
      }
      return value['result'];
    } on ApiException {
      rethrow;
    } on PlatformException catch (error) {
      throw ApiException(
        error.message ?? 'Không mở được engine trên thiết bị.',
        code: error.code,
      );
    } on TimeoutException {
      throw const ApiException(
        'Engine phản hồi quá lâu. Hãy thử lại.',
        code: 'TIMEOUT',
      );
    } on MissingPluginException {
      throw const ApiException(
        'Bản app chưa đóng gói engine iOS.',
        code: 'RUNTIME_MISSING',
      );
    } on FormatException {
      throw const ApiException(
        'Engine trả dữ liệu không hợp lệ.',
        code: 'INVALID_SOURCE_DATA',
      );
    }
  }

  Future<void> _ready() async {
    if (_disposed) {
      throw const ApiException('Engine đã đóng. Hãy mở lại nguồn.');
    }
    if (_initialized) return;
    return exclusiveExtensionBackup(() async {
      final pending = _initialization ??= () async {
        final directory = await _storage();
        await directory.create(recursive: true);
        await _request('initialize', {'dataDirectory': directory.path});
      }();
      try {
        await pending;
        _initialized = true;
      } catch (_) {
        if (identical(_initialization, pending)) _initialization = null;
        rethrow;
      }
    });
  }

  Future<dynamic> _call(
    String method, [
    Map<String, dynamic> args = const {},
  ]) async {
    try {
      await _ready();
      return await _request(method, args);
    } catch (error) {
      DiagnosticLogs.error('source', error, operation: method);
      rethrow;
    }
  }

  @override
  Future<Map<String, dynamic>> health() async => _map(await _call('health'));

  @override
  Future<void> clearSourceCache() async {
    await (await _coverStorage()).clear();
    await _call('clearSourceCache');
  }

  @override
  Future<void> clearCookies() async {
    await (await _coverStorage()).clear();
    await _call('clearCookies');
  }

  @override
  Future<List<CatalogueSource>> listSources() async => [
    for (final value in _list(await _call('sources'))) _source(_map(value)),
  ];

  CatalogueSource _source(Map<String, dynamic> item) => CatalogueSource(
    id: _text(item['id'], required: true),
    name: _text(item['name'], required: true),
    lang: _text(item['lang']),
    baseUrl: _text(item['baseUrl']),
    iconUrl: _text(item['iconUrl']),
    kind: ContentKind.manga,
    engine: SourceEngine.tachimanga,
  );

  @override
  Future<List<CatalogueExtension>> extensions() async => [
    for (final value in _list(await _call('extensions')))
      _extension(_map(value)),
  ];

  CatalogueExtension _extension(Map<String, dynamic> item) =>
      CatalogueExtension(
        id: _text(item['id'], required: true),
        name: _text(item['name'], required: true),
        version: _text(item['version']),
        engine: SourceEngine.tachimanga,
        installed: item['installed'] == true,
        packageUrl: _text(item['packageUrl']),
        iconUrl: _text(item['iconUrl']),
        lang: _text(item['lang']),
        sourceIds: item['sourceIds'] is List
            ? (item['sourceIds'] as List).whereType<String>().toList(
                growable: false,
              )
            : const [],
        loadError: _text(item['loadError']),
      );

  @override
  Future<void> installExtension(String packageUrl) async {
    final url = Uri.tryParse(packageUrl);
    if (url == null ||
        !['http', 'https'].contains(url.scheme) ||
        !url.hasAuthority ||
        url.userInfo.isNotEmpty ||
        url.hasFragment) {
      throw const ApiException(
        'Cần URL HTTP/HTTPS của gói APK trong kho extension.',
      );
    }
    await _ready();
    const limit = 32 * 1024 * 1024;
    final response = await _client
        .send(http.Request('GET', url))
        .timeout(const Duration(seconds: 30));
    if (response.statusCode < 200 ||
        response.statusCode >= 300 ||
        (response.contentLength ?? 0) > limit) {
      await response.stream.listen((_) {}).cancel();
      throw ApiException(
        'Không tải được gói APK (HTTP ${response.statusCode}).',
        code: 'DOWNLOAD_FAILED',
      );
    }
    final builder = BytesBuilder(copy: false);
    final deadline = DateTime.now().add(const Duration(seconds: 30));
    await for (final chunk in response.stream.timeout(
      const Duration(seconds: 30),
    )) {
      if (DateTime.now().isAfter(deadline) ||
          builder.length + chunk.length > limit) {
        throw const ApiException(
          'Gói APK vượt giới hạn tải.',
          code: 'PACKAGE_TOO_LARGE',
        );
      }
      builder.add(chunk);
    }
    await _installBytes(
      builder.takeBytes(),
      packageUrl: url.toString(),
      iconUrl: iconForPackage?.call(packageUrl) ?? '',
    );
  }

  @override
  Future<CatalogueExtension> installExtensionBytes(Uint8List input) async {
    if (input.length > 32 * 1024 * 1024) {
      throw const ApiException(
        'Gói APK vượt giới hạn 32 MiB.',
        code: 'PACKAGE_TOO_LARGE',
      );
    }
    // Copy before the first await: callers must not mutate a staged snapshot.
    final bytes = Uint8List.fromList(input);
    return _extension(await _installBytes(bytes));
  }

  Future<Map<String, dynamic>> _installBytes(
    Uint8List bytes, {
    String packageUrl = '',
    String iconUrl = '',
  }) async {
    if (bytes.length > 32 * 1024 * 1024) {
      throw const ApiException(
        'Gói APK vượt giới hạn 32 MiB.',
        code: 'PACKAGE_TOO_LARGE',
      );
    }
    if (bytes.length < 4 || bytes[0] != 0x50 || bytes[1] != 0x4b) {
      throw const ApiException(
        'Chưa có gói APK hợp lệ.',
        code: 'INVALID_PACKAGE',
      );
    }
    final digest = sha256.convert(bytes).toString();
    final directory = Directory('${(await _storage()).path}/staging');
    await directory.create(recursive: true);
    final file = File('${directory.path}/$digest.apk');
    await _stagePackage(file, bytes, digest);
    final result = _map(
      await _call('install', {
        'apkPath': file.path,
        'packageUrl': packageUrl,
        'packageHash': digest,
        'iconUrl': iconUrl,
      }),
    );
    if (result['installed'] != true) {
      throw const ApiException(
        'Engine chưa xác nhận đã cài và nạp nguồn.',
        code: 'INSTALL_NOT_CONFIRMED',
      );
    }
    _preferenceKeys.clear();
    return result;
  }

  static final _stagingTails = <String, Future<void>>{};

  Future<void> _stagePackage(File file, Uint8List bytes, String digest) {
    // The exists/rename boundary is shared across repository handles. Without
    // this lock a concurrent rename can overwrite an in-use input on POSIX or
    // fail with access denied on Windows. Retained input remains recoverable.
    final key = file.absolute.path;
    final previous = _stagingTails[key] ?? Future<void>.value();
    final result = previous.then(
      (_) => _writeStagedPackage(file, bytes, digest),
    );
    final tail = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    _stagingTails[key] = tail;
    unawaited(
      tail.then((_) {
        if (identical(_stagingTails[key], tail)) _stagingTails.remove(key);
      }),
    );
    return result;
  }

  Future<void> _writeStagedPackage(
    File file,
    Uint8List bytes,
    String digest,
  ) async {
    if (await file.exists()) {
      if (sha256.convert(await file.readAsBytes()).toString() != digest) {
        throw const ApiException(
          'Gói APK đã lưu bị hỏng.',
          code: 'PACKAGE_CORRUPT',
        );
      }
    } else {
      final staging = await file.parent.createTemp('$digest-');
      try {
        final temporary = File('${staging.path}/package.pending');
        await temporary.writeAsBytes(bytes, flush: true);
        // Concurrent downloads may have finished the same content first.
        if (await file.exists()) {
          if (sha256.convert(await file.readAsBytes()).toString() != digest) {
            throw const ApiException(
              'Gói APK đã lưu bị hỏng.',
              code: 'PACKAGE_CORRUPT',
            );
          }
        } else {
          await temporary.rename(file.path);
        }
      } finally {
        await staging.delete(recursive: true);
      }
    }
  }

  CatalogueBook _book(Map<String, dynamic> item, String sourceId) =>
      CatalogueBook(
        ref: _text(item['ref'], required: true),
        title: _text(item['title'], required: true),
        author: _text(item['author']),
        artist: _text(item['artist']),
        genres: item['genres'] is List
            ? _list(item['genres']).map((v) => _text(v)).toList()
            : const [],
        description: _text(item['description']),
        coverUrl: _text(item['coverUrl']),
        sourceId: sourceId,
        status: catalogueStatus(item['status']),
        kind: ContentKind.manga,
        engine: SourceEngine.tachimanga,
      );

  @override
  Future<List<CatalogueBook>> search(
    CatalogueSource source,
    String query, {
    int page = 1,
  }) async {
    if (page < 1) throw const ApiException('Số trang phải từ 1 trở lên.');
    return [
      for (final value in _list(
        _map(
          await _call('search', {
            'sourceId': source.id,
            'query': query,
            'page': page,
          }),
        )['items'],
      ))
        _book(_map(value), source.id),
    ];
  }

  @override
  Future<List<CatalogueBook>> browse(
    CatalogueSource source, {
    required SourceBrowseMode mode,
    int page = 1,
  }) async {
    if (page < 1) throw const ApiException('Số trang phải từ 1 trở lên.');
    return [
      for (final value in _list(
        _map(
          await _call('search', {
            'sourceId': source.id,
            'mode': mode.name,
            'page': page,
          }),
        )['items'],
      ))
        _book(_map(value), source.id),
    ];
  }

  @override
  Future<SourceFilterSet> sourceFilters(CatalogueSource source) async =>
      SourceFilterSet.fromJson(
        _map(await _call('filters', {'sourceId': source.id})),
      );

  @override
  Future<List<CatalogueBook>> searchFiltered(
    CatalogueSource source,
    String query,
    SourceFilterSet filters, {
    int page = 1,
  }) async {
    if (page < 1) throw const ApiException('Số trang phải từ 1 trở lên.');
    return [
      for (final value in _list(
        _map(
          await _call('search', {
            'sourceId': source.id,
            'query': query,
            'page': page,
            'filterSchema': filters.schema,
            'filters': filters.toJson()['filters'],
          }),
        )['items'],
      ))
        _book(_map(value), source.id),
    ];
  }

  @override
  Future<void> uninstallExtension(String packageId) async {
    if (packageId.isEmpty) throw const ApiException('Thiếu mã gói extension.');
    if (await _call('uninstall', {'id': packageId}) != true) {
      throw const ApiException('Extension không còn được cài trên thiết bị.');
    }
    _preferenceKeys.clear();
  }

  Future<Map<String, dynamic>> _ref(CatalogueBook book) async {
    // Numeric companion IDs cannot identify a title in a new on-device runtime.
    if (RegExp(r'^\d+$').hasMatch(book.ref)) {
      const unresolved = ApiException(
        'Truyện cũ dùng mã của server. Hãy mở lại đúng truyện từ nguồn đã cài.',
        code: 'RESTORED_TITLE_UNRESOLVED',
      );
      final known = book.knownChapterRefs.toSet();
      if (known.isEmpty ||
          known.any((ref) => ref.isEmpty || RegExp(r'^\d+$').hasMatch(ref))) {
        throw unresolved;
      }
      final key = sha256
          .convert(
            utf8.encode(
              jsonEncode([
                book.sourceId,
                book.ref,
                book.title,
                (known.toList()..sort()),
              ]),
            ),
          )
          .toString();
      final cached = _verifiedBookRefs[key];
      if (cached != null) {
        return {'sourceId': book.sourceId, 'ref': cached, 'title': book.title};
      }
      final source = CatalogueSource(
        id: book.sourceId,
        name: '',
        lang: '',
        baseUrl: '',
        kind: ContentKind.manga,
        engine: SourceEngine.tachimanga,
      );
      String normalized(String value) =>
          value.trim().replaceAll(RegExp(r'\s+'), ' ').toLowerCase();
      final candidates = (await search(source, book.title))
          .where(
            (candidate) =>
                normalized(candidate.title) == normalized(book.title) &&
                !RegExp(r'^\d+$').hasMatch(candidate.ref),
          )
          .toList();
      if (candidates.length > 5) throw unresolved;
      final deadline = DateTime.now().add(const Duration(seconds: 90));
      final matches = <String>{};
      for (final candidate in candidates) {
        if (DateTime.now().isAfter(deadline)) throw unresolved;
        // Do not skip failed candidates and then claim a unique match. Every
        // saved URL must be present; matching names alone are insufficient.
        final refs = (await chapters(candidate))
            .map((chapter) => chapter.ref)
            .toSet();
        if (refs.containsAll(known)) matches.add(candidate.ref);
      }
      if (matches.length != 1) throw unresolved;
      if (_verifiedBookRefs.length >= 64) _verifiedBookRefs.clear();
      _verifiedBookRefs[key] = matches.single;
      return {
        'sourceId': book.sourceId,
        'ref': matches.single,
        'title': book.title,
      };
    }
    return {'sourceId': book.sourceId, 'ref': book.ref, 'title': book.title};
  }

  @override
  Future<CatalogueBook> detail(CatalogueBook book) async =>
      _book(_map(await _call('detail', await _ref(book))), book.sourceId);

  @override
  Future<List<CatalogueChapter>> chapters(CatalogueBook book) async {
    final chapters = [
      for (final value in _list(await _call('chapters', await _ref(book))))
        _chapter(_map(value)),
    ];
    if (chapters.map((c) => c.ref).toSet().length != chapters.length ||
        chapters.map((c) => c.index).toSet().length != chapters.length) {
      throw const ApiException(
        'Nguồn trả chương trùng hoặc thứ tự không hợp lệ.',
        code: 'INVALID_SOURCE_DATA',
      );
    }
    chapters.sort((a, b) => a.index.compareTo(b.index));
    return chapters;
  }

  CatalogueChapter _chapter(Map<String, dynamic> item) {
    final index = item['index'];
    if (index is! int || index < 0) {
      throw const ApiException('Chỉ số chương không hợp lệ.');
    }
    return CatalogueChapter(
      ref: _text(item['ref'], required: true),
      title: _text(item['title'], required: true),
      index: index,
      number: catalogueChapterNumber(item['number']),
      uploadedAt: catalogueUploadDate(item['uploadedAt']),
      scanlator: _text(item['scanlator']),
    );
  }

  @override
  Future<ChapterContent> chapter(
    CatalogueBook book,
    CatalogueChapter chapter,
  ) async {
    if (RegExp(r'^\d+$').hasMatch(chapter.ref)) {
      throw const ApiException(
        'Chương cũ chưa có URL gốc. Hãy cập nhật mục lục nguồn.',
        code: 'CHAPTER_IDENTITY_CHANGED',
      );
    }
    final content = _map(
      await _call('chapter', {
        // A chapter URL identifies its content without the old server's manga
        // ID. Do not reject restored books that already have real chapter URLs.
        'sourceId': book.sourceId,
        'bookRef': book.ref,
        'ref': chapter.ref,
        'title': chapter.title,
      }),
    );
    final images = <String>[];
    final imageHeaders = <String, Map<String, String>>{};
    final rawHeaders = content['imageHeaders'] == null
        ? const <String, dynamic>{}
        : _map(content['imageHeaders']);
    for (final value in _list(content['images'])) {
      final item = value is String ? {'url': value} : _map(value);
      final text = _text(item['url'], required: true);
      final url = Uri.tryParse(text);
      if (url == null ||
          !['http', 'https'].contains(url.scheme) ||
          !url.hasAuthority ||
          url.userInfo.isNotEmpty) {
        throw const ApiException(
          'Nguồn trả URL ảnh không hợp lệ.',
          code: 'INVALID_SOURCE_DATA',
        );
      }
      images.add(text);
      if (rawHeaders[text] != null || item['headers'] != null) {
        imageHeaders[text] = {
          if (rawHeaders[text] != null) ..._headers(rawHeaders[text]),
          if (item['headers'] != null) ..._headers(item['headers']),
        };
      }
    }
    if (images.isEmpty || images.length > 10000) {
      throw const ApiException('Chương chưa có danh sách trang hợp lệ.');
    }
    return ChapterContent(
      kind: ContentKind.manga,
      images: images,
      headers: content['headers'] == null
          ? const {}
          : _headers(content['headers']),
      imageHeaders: imageHeaders,
    );
  }

  @override
  Future<SourceImageData> fetchCover(CatalogueBook book) {
    final key = _coverKey(book);
    return _pendingCovers.putIfAbsent(key, () async {
      try {
        final allowed = canCacheCover?.call() ?? true;
        final epoch = coverCacheEpoch?.call();
        final cache = await _coverStorage();
        if (_disposed) throw StateError('Engine đã đóng.');
        _validateCover(book);
        final generation = cache.generation;
        if (allowed) {
          final saved = await cache.read(key);
          if (saved != null && generation == cache.generation) {
            try {
              return _sourceImage(saved);
            } catch (_) {
              await cache.remove(key);
            }
          }
        }
        final image = await _enqueueImage(() => _fetchCover(book), cover: true);
        if (allowed &&
            (canCacheCover?.call() ?? true) &&
            epoch == coverCacheEpoch?.call()) {
          await cache.write(key, {
            'base64': base64Encode(image.bytes),
            'mimeType': image.mimeType,
          }, generation);
        }
        return image;
      } finally {
        _pendingCovers.remove(key);
      }
    });
  }

  String _coverKey(CatalogueBook book) => sha256
      .convert(
        utf8.encode(
          jsonEncode([book.engine.name, book.sourceId, book.coverUrl]),
        ),
      )
      .toString();

  @override
  Future<void> invalidateCover(CatalogueBook book) async =>
      (await _coverStorage()).remove(_coverKey(book));

  @override
  Future<void> clearCoverCache() async => (await _coverStorage()).clear();

  Future<SourceImageData> _fetchCover(CatalogueBook book) async {
    _validateCover(book);
    try {
      return _sourceImage(
        _map(
          await _call('cover', {
            'sourceId': book.sourceId,
            'url': book.coverUrl,
          }),
        ),
      );
    } on ApiException catch (error) {
      // An imported library can contain public thumbnails before its extension
      // is installed. Only that case permits an ordinary public cover GET;
      // loaded-source/challenge errors always keep the extension client path.
      final url = Uri.tryParse(book.coverUrl);
      if (error.code?.toLowerCase() != 'source_not_installed' ||
          url == null ||
          !url.hasAuthority ||
          !url.hasScheme) {
        rethrow;
      }
      final response = await _client
          .send(http.Request('GET', url))
          .timeout(const Duration(seconds: 15));
      if (response.statusCode != 200 ||
          (response.contentLength ?? 0) > 8 * 1024 * 1024) {
        await response.stream.listen((_) {}).cancel();
        throw ApiException(
          'Không tải được ảnh bìa công khai.',
          statusCode: response.statusCode,
        );
      }
      final bytes = BytesBuilder(copy: false);
      final started = DateTime.now();
      await for (final chunk in response.stream.timeout(
        const Duration(seconds: 15),
      )) {
        if (bytes.length + chunk.length > 8 * 1024 * 1024 ||
            DateTime.now().difference(started) > const Duration(seconds: 20)) {
          throw const ApiException(
            'Ảnh bìa quá lớn hoặc phản hồi quá lâu.',
            code: 'TIMEOUT',
          );
        }
        bytes.add(chunk);
      }
      return _sourceImage({
        'base64': base64Encode(bytes.takeBytes()),
        'mimeType': 'application/octet-stream',
      });
    }
  }

  void _validateCover(CatalogueBook book) {
    final url = Uri.tryParse(book.coverUrl);
    final sourceId = BigInt.tryParse(book.sourceId);
    if (book.engine != SourceEngine.tachimanga ||
        sourceId == null ||
        sourceId.toSigned(64) != sourceId ||
        book.coverUrl.isEmpty ||
        book.coverUrl.length > 16384 ||
        book.coverUrl.contains(RegExp(r'[\x00-\x20\\]')) ||
        url == null ||
        (url.hasScheme && !['http', 'https'].contains(url.scheme)) ||
        url.userInfo.isNotEmpty ||
        url.hasFragment) {
      throw const ApiException(
        'Nguồn hoặc URL ảnh bìa không hợp lệ.',
        code: 'INVALID_SOURCE_DATA',
      );
    }
    // The native source resolves relative cover URLs using its own base URL.
    // A legacy numeric book reference does not prevent loading its saved cover.
  }

  @override
  Future<SourceImageData> fetchImage(
    CatalogueBook book,
    CatalogueChapter chapter,
    int page,
    String url,
  ) {
    return _enqueueImage(
      () => _fetchImage(book, chapter, page, url),
      cover: false,
    );
  }

  Future<SourceImageData> _fetchImage(
    CatalogueBook book,
    CatalogueChapter chapter,
    int page,
    String url,
  ) async {
    final imageUrl = Uri.tryParse(url);
    if (page < 0 ||
        page >= 10000 ||
        imageUrl == null ||
        !imageUrl.hasAuthority ||
        !['http', 'https'].contains(imageUrl.scheme) ||
        imageUrl.userInfo.isNotEmpty ||
        chapter.ref.isEmpty ||
        RegExp(r'^\d+$').hasMatch(chapter.ref)) {
      throw const ApiException('Vị trí hoặc URL trang truyện không hợp lệ.');
    }
    final image = _map(
      await _call('image', {
        'sourceId': book.sourceId,
        'ref': book.ref,
        'title': book.title,
        'chapterRef': chapter.ref,
        'chapterTitle': chapter.title,
        'index': page,
        'url': url,
      }),
    );
    return _sourceImage(image);
  }

  SourceImageData _sourceImage(Map<String, dynamic> image) {
    final encoded = _text(image['base64'], required: true);
    if (encoded.length > 11184812) {
      throw const ApiException('Ảnh vượt giới hạn 8 MB.');
    }
    final Uint8List bytes;
    try {
      bytes = base64Decode(encoded);
    } on FormatException {
      throw const ApiException(
        'Engine trả mã ảnh không hợp lệ.',
        code: 'INVALID_SOURCE_DATA',
      );
    }
    if (bytes.isEmpty || bytes.length > 8 * 1024 * 1024) {
      throw const ApiException('Engine trả ảnh rỗng hoặc quá lớn.');
    }
    var mimeType = _text(image['mimeType'])
        .split(';')
        .first
        .trim()
        .toLowerCase();
    if (!mimeType.startsWith('image/')) {
      if (bytes.length >= 3 &&
          bytes[0] == 255 &&
          bytes[1] == 216 &&
          bytes[2] == 255) {
        mimeType = 'image/jpeg';
      } else if (bytes.length >= 8 &&
          bytes[0] == 137 &&
          bytes[1] == 80 &&
          bytes[2] == 78 &&
          bytes[3] == 71) {
        mimeType = 'image/png';
      } else if (bytes.length >= 6 &&
          ascii.decode(bytes.sublist(0, 3), allowInvalid: true) == 'GIF') {
        mimeType = 'image/gif';
      } else if (bytes.length >= 12 &&
          ascii.decode(bytes.sublist(0, 4), allowInvalid: true) == 'RIFF' &&
          ascii.decode(bytes.sublist(8, 12), allowInvalid: true) == 'WEBP') {
        mimeType = 'image/webp';
      } else {
        throw const ApiException('Nguồn trả về dữ liệu không phải ảnh.');
      }
    }
    return SourceImageData(bytes: bytes, mimeType: mimeType);
  }

  @override
  Future<void> openWebsite(CatalogueBook book) async {
    final resolved = await _ref(book);
    final sources = await listSources();
    final matches = sources.where((source) => source.id == book.sourceId);
    if (matches.length != 1) {
      throw const ApiException('Nguồn chưa được cài hoặc không còn trong app.');
    }
    final base = Uri.tryParse(matches.single.baseUrl);
    if (base == null ||
        !base.hasAuthority ||
        !['http', 'https'].contains(base.scheme) ||
        base.userInfo.isNotEmpty) {
      throw const ApiException('Nguồn chưa có địa chỉ trang web hợp lệ.');
    }
    final bookRef = resolved['ref'] as String;
    final url = bookRef.isEmpty ? base : base.resolve(bookRef);
    if (url.host != base.host ||
        url.userInfo.isNotEmpty ||
        !['http', 'https'].contains(url.scheme)) {
      throw const ApiException('Địa chỉ truyện không thuộc nguồn đang chọn.');
    }
    try {
      final session = await _openBrowser(url.toString());
      if (session['cancelled'] == true) return;
      if (session['url'] != url.toString() ||
          session['cookies'] is! List ||
          session['userAgent'] is! String) {
        throw const ApiException('Trình duyệt chưa trả phiên nguồn hợp lệ.');
      }
      await _call('browserSession', {
        'sourceId': book.sourceId,
        'url': url.toString(),
        'userAgent': session['userAgent'],
        'cookies': session['cookies'],
      });
    } on PlatformException catch (error) {
      throw ApiException(
        error.message ?? 'Không mở được trang nguồn.',
        code: error.code,
      );
    } on MissingPluginException {
      throw const ApiException(
        'Bản app chưa đóng gói trình duyệt nguồn iOS.',
        code: 'RUNTIME_MISSING',
      );
    }
  }

  @override
  Future<List<Map<String, dynamic>>> sourcePreferences(
    CatalogueSource source,
  ) async {
    final result = <Map<String, dynamic>>[];
    for (final value in _list(
      await _call('preferences', {'sourceId': source.id}),
    )) {
      final item = _map(value);
      final props = item['props'] is Map ? _map(item['props']) : item;
      final rawType = _text(item['type']);
      final type = rawType == 'Set<String>'
          ? 'MultiSelectListPreference'
          : props['entries'] is List && !rawType.endsWith('Preference')
          ? 'ListPreference'
          : ['Boolean', 'bool'].contains(rawType)
          ? 'SwitchPreferenceCompat'
          : rawType == 'String'
          ? 'EditTextPreference'
          : rawType;
      result.add({
        ...item,
        'type': type,
        'props': {
          ...props,
          'currentValue': props['currentValue'] ?? item['value'],
        },
      });
    }
    _preferenceKeys[source.id] = [
      for (final item in result) _text(_map(item['props'])['key']),
    ];
    return result;
  }

  @override
  Future<void> setSourcePreference(
    CatalogueSource source,
    int position,
    dynamic value,
  ) async {
    if (position < 0 ||
        !(value is String || value is bool || value is List<String>)) {
      throw const ApiException('Giá trị cấu hình nguồn không hợp lệ.');
    }
    var keys = _preferenceKeys[source.id];
    if (keys == null) {
      await sourcePreferences(source);
      keys = _preferenceKeys[source.id]!;
    }
    if (position >= keys.length) {
      throw const ApiException('Cấu hình nguồn không còn ở vị trí đã chọn.');
    }
    final key = keys[position];
    if (key.isEmpty) {
      throw const ApiException(
        'Mục cấu hình này không có giá trị để lưu.',
        code: 'UNSUPPORTED_CAPABILITY',
      );
    }
    await _call('setPreference', {
      'sourceId': source.id,
      'key': key,
      'value': value,
    });
  }

  @override
  Future<ExtensionBackup>
  captureExtensionBackup() => exclusiveExtensionBackup(() async {
    final root = await _storage(),
        registry = File('${(await _storage()).path}/registry.json');
    if (!await registry.exists()) return ExtensionBackup(const []);
    final before = await _backupFile(registry, 2 * 1024 * 1024);
    final document = _map(jsonDecode(utf8.decode(before)));
    if (document['version'] != 1 || document['packages'] is! Map) {
      throw const FormatException('Chỉ mục extension Tachiyomi không hợp lệ.');
    }
    final sources = {
      for (final source in await listSources()) source.id: source,
    };
    final packages = <ExtensionBackupPackage>[];
    for (final entry in _map(document['packages']).entries) {
      final metadata = _map(entry.value),
          hash = metadata['apkSha256'],
          filename = metadata['apk'];
      if (hash is! String ||
          !RegExp(r'^[a-f0-9]{64}$').hasMatch(hash) ||
          filename != '$hash.apk' ||
          metadata['id'] != entry.key) {
        throw const FormatException(
          'Gói APK đã lưu không có danh tính hoặc checksum hợp lệ.',
        );
      }
      final bytes = await _backupFile(
        File('${root.path}/packages/$filename'),
        32 * 1024 * 1024,
      );
      if (sha256.convert(bytes).toString() != hash) {
        throw const FormatException(
          'Gói APK đã lưu bị hỏng; không thể sao lưu.',
        );
      }
      final ids = _list(metadata['sourceIds']).cast<String>();
      final prefs = <String, Map<String, PublicSourcePreference>>{};
      for (final id in ids) {
        final source = sources[id];
        if (source == null) continue; // Original package is recoverable even if a source failed to load.
        final public = <String, PublicSourcePreference>{};
        for (final item in await sourcePreferences(source)) {
          final preference = PublicSourcePreference.fromScreen(item);
          if (preference != null) {
            public[_map(item['props'])['key'] as String] = preference;
          }
        }
        if (public.isNotEmpty) prefs[id] = public;
      }
      packages.add(
        ExtensionBackupPackage.create(
          engine: SourceEngine.tachimanga,
          id: entry.key,
          name: _text(metadata['name']),
          version: _text(metadata['version']),
          bytes: bytes,
          origin: _text(metadata['packageUrl']),
          sourceIds: ids,
          preferences: prefs,
        ),
      );
    }
    final after = await _backupFile(registry, 2 * 1024 * 1024);
    if (sha256.convert(before).toString() != sha256.convert(after).toString()) {
      throw StateError('Extension đã thay đổi trong khi sao lưu. Hãy thử lại.');
    }
    return ExtensionBackup(packages);
  });

  @override
  Future<void> validateExtensionBackup(ExtensionBackup backup) =>
      exclusiveExtensionBackup(() async {
        if (backup.packages.any(
          (package) => package.engine != SourceEngine.tachimanga,
        )) {
          throw const FormatException(
            'Bản extension không thuộc engine Tachiyomi.',
          );
        }
        for (final package in backup.packages) {
          final directory = Directory('${(await _storage()).path}/staging');
          await directory.create(recursive: true);
          final file = File('${directory.path}/${package.digest}.apk');
          await _stagePackage(file, package.bytes, package.digest);
          final metadata = _map(
            await _call('inspectPackage', {'apkPath': file.path}),
          );
          if (metadata['id'] != package.id ||
              metadata['apkSha256'] != package.digest) {
            throw const FormatException(
              'Manifest APK không khớp mã gói trong sao lưu. Thư viện chưa bị thay.',
            );
          }
        }
      });

  @override
  Future<void> restoreExtensionBackup(
    ExtensionBackup backup,
  ) => exclusiveExtensionBackup(() async {
    await validateExtensionBackup(backup);
    for (final package in backup.packages) {
      final result = _map(
        await _installBytes(package.bytes, packageUrl: package.origin),
      );
      final ids = _list(result['sourceIds']).cast<String>().toSet();
      if (result['id'] != package.id ||
          _text(result['apkSha256']) != package.digest ||
          ids.length != package.sourceIds.length ||
          !ids.containsAll(package.sourceIds)) {
        throw const FormatException(
          'Gói APK phục hồi không khớp danh tính nguồn gốc.',
        );
      }
      for (final entry in package.preferences.entries) {
        final source = (await listSources())
            .where((source) => source.id == entry.key)
            .single;
        for (final preference in entry.value.entries) {
          // Each write can reload source factories. Resolve the public screen/key
          // again rather than trusting a stale positional index from the backup.
          final screen = await sourcePreferences(source);
          final position = screen.indexWhere(
            (item) => _map(item['props'])['key'] == preference.key,
          );
          if (position < 0 ||
              !preference.value.matchesScreen(screen[position])) {
            throw StateError(
              'Tùy chọn công khai của nguồn đã thay đổi: ${preference.key}.',
            );
          }
          await setSourcePreference(source, position, preference.value.value);
        }
      }
    }
  });

  Future<Uint8List> _backupFile(File file, int limit) async {
    if (!await file.exists() || await file.length() > limit) {
      throw const FormatException('Thiếu hoặc quá lớn tệp extension đã cài.');
    }
    final result = BytesBuilder(copy: false);
    await for (final chunk in file.openRead()) {
      if (result.length + chunk.length > limit) {
        throw const FormatException('Tệp extension vượt giới hạn sao lưu.');
      }
      result.add(chunk);
    }
    return result.takeBytes();
  }

  @override
  void dispose() {
    _disposed = true;
    if (_ownsClient) _client.close();
  }
}

Map<String, dynamic> _map(dynamic value) {
  if (value is Map<String, dynamic>) return value;
  throw const ApiException(
    'Engine trả cấu trúc không hợp lệ.',
    code: 'INVALID_SOURCE_DATA',
  );
}

List<dynamic> _list(dynamic value) {
  if (value is List) return value;
  throw const ApiException(
    'Engine chưa trả danh sách hợp lệ.',
    code: 'INVALID_SOURCE_DATA',
  );
}

String _text(dynamic value, {bool required = false}) {
  if (value is String && (!required || value.trim().isNotEmpty)) return value;
  if (!required && value == null) return '';
  throw const ApiException(
    'Engine thiếu trường văn bản hợp lệ.',
    code: 'INVALID_SOURCE_DATA',
  );
}

Map<String, String> _headers(dynamic value) => _map(value).map((key, v) {
  if (v is! String) throw const ApiException('Header ảnh không hợp lệ.');
  return MapEntry(key, v);
});
