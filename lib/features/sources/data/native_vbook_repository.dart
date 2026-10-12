import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html;
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../domain/catalogue.dart';
import '../domain/native_source_engine.dart';
import '../domain/extension_backup.dart';
import 'native_vbook_package.dart';
import 'extension_mutation_queue.dart';

typedef NativeVbookExecutor = Future<Map<String, dynamic>> Function(
  String method,
  Map<String, dynamic> arguments,
);

/// Original plaintext scripts are persisted in the app's sandbox and executed
/// through JavaScriptCore. No source call depends on a companion URL.
class NativeVbookRepository
    implements
        NativeSourceEngine,
        NativeExtensionBackupEngine,
        NativeExtensionBackupTransaction {
  NativeVbookRepository({
    NativeVbookExecutor? executor,
    http.Client? client,
    Directory? storageDirectory,
  }) : _execute = executor ?? _invokeNative,
       _client = client ?? http.Client(),
       _ownsClient = client == null,
       _directory = storageDirectory;

  static const channel = MethodChannel('dev.tachibooks/vbook_runtime');
  final NativeVbookExecutor _execute;
  final http.Client _client;
  final bool _ownsClient;
  Directory? _directory;
  Future<void>? _initialization;
  int? _loadedRevision;
  bool _loadedReady = false;
  final _packages = <String, NativeVbookPackage>{};
  final _origins = <String, String>{};
  static final _operations = <String, Future<void>>{};
  static final _indexRevisions = <String, int>{};

  static Future<Map<String, dynamic>> _invokeNative(
    String method,
    Map<String, dynamic> arguments,
  ) async {
    final result = await channel.invokeMapMethod<String, dynamic>(
      method,
      arguments,
    );
    if (result == null) {
      throw const ApiException(
        'Engine vBook chưa trả kết quả.',
        code: 'INVALID_SCRIPT_RESPONSE',
      );
    }
    return result;
  }

  Future<Map<String, dynamic>> _native(
    String method, [
    Map<String, dynamic> args = const {},
  ]) async {
    try {
      return await _execute(method, args).timeout(const Duration(seconds: 30));
    } on ApiException {
      rethrow;
    } on MissingPluginException {
      throw const ApiException(
        'Engine vBook native chưa có trong bản app này.',
        code: 'ENGINE_UNAVAILABLE',
      );
    } on PlatformException catch (error) {
      throw ApiException(
        error.message ?? 'Extension vBook không thực hiện được yêu cầu.',
        code: error.code,
      );
    } on TimeoutException {
      throw const ApiException(
        'Extension vBook phản hồi quá lâu.',
        code: 'SCRIPT_TIMEOUT',
      );
    }
  }

  Future<Directory> _storage() async => _directory ??= Directory(
    '${(await getApplicationSupportDirectory()).path}/TachiBooks/extension-runtime/vbook',
  );

  @override
  Future<T> exclusiveExtensionBackup<T>(Future<T> Function() action) async {
    final path = (await _storage()).absolute.uri.normalizePath().toFilePath();
    return ExtensionMutationQueue.run(
      'vbook:${Platform.isWindows ? path.toLowerCase() : path}',
      action,
    );
  }

  Future<void> _ready() async {
    final key = (await _storage()).absolute.path;
    if (_loadedReady &&
        _initialization != null &&
        _loadedRevision == (_indexRevisions[key] ?? 0)) {
      return;
    }
    return exclusiveExtensionBackup(_readyLocked);
  }

  Future<void> _readyLocked() async {
    final key = (await _storage()).absolute.path;
    while (true) {
      final revision = _indexRevisions[key] ?? 0;
      if (_loadedRevision != revision) {
        _initialization = null;
        _loadedReady = false;
        _loadedRevision = revision;
      }
      final pending = _initialization ??= _serialized('index', _load);
      try {
        await pending;
      } catch (_) {
        if (identical(_initialization, pending)) _initialization = null;
        rethrow;
      }
      // Another handle can publish while this handle is reading the old index.
      // Reload before exposing a catalogue from that earlier installation.
      if ((_indexRevisions[key] ?? 0) == revision) {
        _loadedReady = true;
        return;
      }
    }
  }

  Future<void> _load() async {
    final directory = await _storage();
    await directory.create(recursive: true);
    final index = await _readJson(File('${directory.path}/index.json'), {
      'extensions': <dynamic>[],
    });
    final loaded = <String, NativeVbookPackage>{}, origins = <String, String>{};
    final entries = _list(index['extensions']);
    if (entries.length > 512) {
      throw const ApiException(
        'Có quá nhiều extension đã lưu.',
        code: 'INVALID_RUNTIME_DATA',
      );
    }
    for (final value in entries) {
      final entry = _map(value),
          id = _text(_map(value)['id']),
          hash = _text(_map(value)['hash']);
      if (!RegExp(r'^vb-[a-f0-9]{24}$').hasMatch(id) ||
          !RegExp(r'^[a-f0-9]{64}$').hasMatch(hash) ||
          loaded.containsKey(id)) {
        throw const ApiException(
          'Chỉ mục extension vBook bị hỏng.',
          code: 'INVALID_RUNTIME_DATA',
        );
      }
      final file = File('${directory.path}/extensions/$id/$hash/package.zip');
      final bytes = await _readBounded(
        file,
        NativeVbookPackage.maxArchiveBytes,
      );
      if (sha256.convert(bytes).toString() != hash) {
        throw const ApiException(
          'Gói vBook đã lưu bị hỏng.',
          code: 'PACKAGE_CORRUPT',
        );
      }
      final package = NativeVbookPackage.parse(bytes);
      if (package.id != id || package.hash != hash) {
        throw const ApiException(
          'Mã nguồn trong gói không khớp chỉ mục.',
          code: 'PACKAGE_CORRUPT',
        );
      }
      loaded[id] = package;
      origins[id] = _text(entry['origin']);
    }
    _packages
      ..clear()
      ..addAll(loaded);
    _origins
      ..clear()
      ..addAll(origins);
  }

  Future<T> _serialized<T>(String key, Future<T> Function() work) async {
    if (key == 'index') {
      return exclusiveExtensionBackup(() => _serializedUnlocked(key, work));
    }
    return _serializedUnlocked(key, work);
  }

  Future<T> _serializedUnlocked<T>(
    String key,
    Future<T> Function() work,
  ) async {
    final operationKey = '${(await _storage()).absolute.path}\u0000$key';
    final previous = _operations[operationKey];
    final completer = Completer<void>();
    _operations[operationKey] = completer.future;
    try {
      if (previous != null) await previous;
      return await work();
    } finally {
      completer.complete();
      if (identical(_operations[operationKey], completer.future)) {
        _operations.remove(operationKey);
      }
    }
  }

  @override
  Future<Map<String, dynamic>> health() => _native('health');

  CatalogueSource _source(NativeVbookPackage package) => CatalogueSource(
    id: package.id,
    name: package.name,
    lang: _text(package.metadata['locale']),
    baseUrl: package.source,
    iconUrl: _optionalUrl(package.metadata['icon'], package.source),
    kind: package.kind,
    engine: SourceEngine.vbook,
  );

  @override
  Future<List<CatalogueSource>> listSources() async {
    await _ready();
    return _packages.values.map(_source).toList(growable: false);
  }

  @override
  Future<List<CatalogueExtension>> extensions() async {
    await _ready();
    return [
      for (final package in _packages.values)
        CatalogueExtension(
          id: package.id,
          name: package.name,
          version: _text(package.metadata['version']),
          engine: SourceEngine.vbook,
          installed: true,
          packageUrl: _origins[package.id] ?? '',
          iconUrl: _optionalUrl(package.metadata['icon'], package.source),
          lang: _text(package.metadata['locale']),
          limitations: const [
            'Chưa hỗ trợ script mã hóa, WebView, crypto native hoặc API native mới.',
          ],
        ),
    ];
  }

  @override
  Future<void> installExtension(String packageUrl) async {
    final url = _url(packageUrl);
    await installBytes(await _download(url), origin: url.toString());
  }

  /// Input is copied and verified before any persisted installation is changed.
  /// A new version's files may remain orphaned if index publication fails; the
  /// previous index and its complete package remain readable.
  Future<void> installBytes(Uint8List input, {String origin = ''}) async {
    final package = NativeVbookPackage.parse(input);
    final engine = await health();
    if (engine['engine'] != 'vbook') {
      throw const ApiException(
        'Engine chưa xác nhận hỗ trợ vBook.',
        code: 'ENGINE_UNAVAILABLE',
      );
    }
    await _serialized('index', () async {
      final directory = await _storage();
      final folder = Directory(
        '${directory.path}/extensions/${package.id}/${package.hash}',
      );
      await folder.create(recursive: true);
      final target = File('${folder.path}/package.zip');
      var intact = false;
      if (await target.exists()) {
        try {
          intact =
              sha256
                  .convert(
                    await _readBounded(
                      target,
                      NativeVbookPackage.maxArchiveBytes,
                    ),
                  )
                  .toString() ==
              package.hash;
        } on ApiException {
          intact = false;
        }
      }
      if (!intact) await _atomicBytes(target, package.bytes);
      final index = await _readJson(File('${directory.path}/index.json'), {
        'extensions': <dynamic>[],
      });
      final seen = <String>{};
      for (final value in _list(index['extensions'])) {
        final entry = _map(value);
        if (!RegExp(r'^vb-[a-f0-9]{24}$').hasMatch(_text(entry['id'])) ||
            !RegExp(r'^[a-f0-9]{64}$').hasMatch(_text(entry['hash'])) ||
            !seen.add(_text(entry['id']))) {
          throw const ApiException(
            'Chỉ mục extension vBook bị hỏng.',
            code: 'INVALID_RUNTIME_DATA',
          );
        }
      }
      final entries = _list(index['extensions'])
          .map(_map)
          .where((entry) => entry['id'] != package.id)
          .toList();
      entries.add({'id': package.id, 'hash': package.hash, 'origin': origin});
      await _atomicJson(File('${directory.path}/index.json'), {
        'version': 1,
        'extensions': entries,
      });
      final key = directory.absolute.path;
      _indexRevisions[key] = (_indexRevisions[key] ?? 0) + 1;
      _packages[package.id] = package;
      _origins[package.id] = origin;
      _initialization = null;
    });
  }

  Future<Uint8List> _download(Uri initial) async {
    var target = initial;
    final deadline = DateTime.now().add(const Duration(seconds: 30));
    try {
      for (var redirects = 0; redirects <= 5; redirects++) {
        final remaining = deadline.difference(DateTime.now());
        if (remaining.isNegative) throw TimeoutException('Package deadline');
        final response = await _client
            .send(http.Request('GET', target)..followRedirects = false)
            .timeout(remaining);
        if ([301, 302, 303, 307, 308].contains(response.statusCode)) {
          await response.stream.listen((_) {}).cancel();
          target = _url(
            target.resolve(response.headers['location'] ?? '').toString(),
          );
          continue;
        }
        if (response.statusCode < 200 ||
            response.statusCode >= 300 ||
            (response.contentLength ?? 0) >
                NativeVbookPackage.maxArchiveBytes) {
          await response.stream.listen((_) {}).cancel();
          throw ApiException(
            'Không tải được gói vBook (HTTP ${response.statusCode}).',
            code: 'DOWNLOAD_FAILED',
          );
        }
        final bytes = BytesBuilder(copy: false);
        await for (final chunk in response.stream.timeout(remaining)) {
          if (DateTime.now().isAfter(deadline) ||
              bytes.length + chunk.length >
                  NativeVbookPackage.maxArchiveBytes) {
            throw const ApiException(
              'Gói vBook vượt giới hạn tải 64 MB.',
              code: 'DOWNLOAD_LIMIT',
            );
          }
          bytes.add(chunk);
        }
        return bytes.takeBytes();
      }
      throw const ApiException(
        'Gói extension chuyển hướng quá nhiều lần.',
        code: 'DOWNLOAD_FAILED',
      );
    } on TimeoutException {
      throw const ApiException(
        'Tải gói vBook quá thời gian cho phép.',
        code: 'TIMEOUT',
      );
    }
  }

  NativeVbookPackage _package(String id) {
    final package = _packages[id];
    if (package == null) {
      throw const ApiException(
        'Chưa cài extension của nguồn này.',
        code: 'SOURCE_NOT_FOUND',
      );
    }
    return package;
  }

  Future<({NativeVbookPackage package, Map<String, dynamic> output})> _run(
    String id,
    String key,
    List<String> args, {
    ContentKind? expectedKind,
    String? expectedHash,
  }) async {
    return _serialized(id, () async {
      // An installation may be published while this request waits for an
      // earlier script. Resolve its package only after acquiring the source lock.
      await _ready();
      final package = _package(id);
      if (expectedKind != null && package.kind != expectedKind) {
        throw const ApiException(
          'Loại nội dung của nguồn đã thay đổi. Hãy mở lại nguồn hoặc truyện.',
          code: 'SOURCE_KIND_CHANGED',
        );
      }
      if (expectedHash != null && package.hash != expectedHash) {
        throw const ApiException(
          'Extension đã thay đổi trong lúc tải mục lục. Hãy thử lại.',
          code: 'SOURCE_VERSION_CHANGED',
        );
      }
      final mapping = _map(package.manifest['script']);
      final script = mapping[key];
      if (script is! String) {
        throw ApiException(
          'Extension chưa cung cấp script $key.',
          code: 'UNSUPPORTED_CAPABILITY',
        );
      }
      final path = '${(await _storage()).path}/extensions/$id/storage.json';
      final storage = await _readJson(File(path), {});
      final result = await _native('execute', {
        'manifest': package.manifest,
        'scripts': package.scripts,
        'script': script,
        'args': args,
        'storage': storage,
        'config': <String, dynamic>{},
      });
      final nextStorage = _map(result['storage']);
      if (nextStorage.values.any((value) => value is! String) ||
          utf8.encode(jsonEncode(nextStorage)).length > 2 * 1024 * 1024) {
        throw const ApiException(
          'Engine trả dữ liệu lưu extension không hợp lệ.',
          code: 'INVALID_SCRIPT_RESPONSE',
        );
      }
      await _atomicJson(File(path), nextStorage);
      // Decode the completed script using the immutable package it executed.
      // A concurrent install must not reinterpret its output as another kind.
      return (package: package, output: result);
    });
  }

  CatalogueBook _book(
    Map<String, dynamic> value,
    NativeVbookPackage package, {
    String? ref,
  }) {
    final base = _text(value['host']).isEmpty
        ? package.source
        : _url(_text(value['host']), package.source).toString();
    return CatalogueBook(
      ref:
          ref ??
          _url(
            _text(value['link'] ?? value['url'] ?? value['ref']),
            base,
          ).toString(),
      title: _required(value['name'] ?? value['title'], 'tên truyện'),
      author: _text(value['author']),
      artist: _text(value['artist']),
      genres: value['genres'] is List
          ? _list(value['genres']).map(_text).toList()
          : const [],
      description: _text(value['description']),
      coverUrl: _optionalUrl(value['cover'] ?? value['coverUrl'], base),
      sourceId: package.id,
      kind: package.kind,
      engine: SourceEngine.vbook,
    );
  }

  @override
  Future<List<CatalogueBook>> search(
    CatalogueSource source,
    String query, {
    int page = 1,
  }) async {
    if (source.engine != SourceEngine.vbook || page < 1) {
      throw const ApiException('Nguồn hoặc trang tìm kiếm không hợp lệ.');
    }
    final execution = await _run(source.id, 'search', [
      query,
      '$page',
    ], expectedKind: source.kind);
    final values = _list(execution.output['data']);
    if (values.length > 2000) {
      throw const ApiException(
        'Nguồn trả quá nhiều kết quả.',
        code: 'EXECUTION_LIMIT',
      );
    }
    return values
        .map((value) => _book(_map(value), execution.package))
        .toList(growable: false);
  }

  String _reference(CatalogueBook book) {
    if (book.engine != SourceEngine.vbook) {
      throw const ApiException('Nguồn không thuộc vBook.');
    }
    return _url(book.ref).toString().replaceFirst(RegExp(r'/$'), '');
  }

  @override
  Future<CatalogueBook> detail(CatalogueBook book) async {
    final ref = _reference(book),
        execution = await _run(book.sourceId, 'detail', [
          ref,
        ], expectedKind: book.kind);
    return _book(
      _map(execution.output['data']),
      execution.package,
      ref: book.ref,
    );
  }

  @override
  Future<List<CatalogueChapter>> chapters(CatalogueBook book) async {
    final ref = _reference(book);
    await _ready();
    final package = _package(book.sourceId);
    var pages = [ref];
    if (_map(package.manifest['script']).containsKey('page')) {
      final data = _list(
        (await _run(
          book.sourceId,
          'page',
          [ref],
          expectedKind: book.kind,
          expectedHash: package.hash,
        )).output['data'],
      );
      if (data.length > 50) {
        throw const ApiException(
          'Mục lục có quá nhiều trang.',
          code: 'EXECUTION_LIMIT',
        );
      }
      pages = data
          .map(
            (value) => _url(
              _required(value, 'URL trang mục lục'),
              package.source,
            ).toString(),
          )
          .toList();
    }
    final chapters = <CatalogueChapter>[], seen = <String>{};
    for (final page in pages) {
      final values = _list(
        (await _run(
          book.sourceId,
          'toc',
          [page.replaceFirst(RegExp(r'/$'), '')],
          expectedKind: book.kind,
          expectedHash: package.hash,
        )).output['data'],
      );
      for (final value in values) {
        final item = _map(value);
        final chapterRef = _url(
          _text(item['url'] ?? item['link']),
          _text(item['host']).isEmpty ? package.source : _text(item['host']),
        ).toString();
        if (!seen.add(chapterRef)) continue;
        if (chapters.length >= 20000) {
          throw const ApiException(
            'Mục lục vượt 20.000 chương.',
            code: 'EXECUTION_LIMIT',
          );
        }
        chapters.add(
          CatalogueChapter(
            ref: chapterRef,
            title: _required(item['name'] ?? item['title'], 'tên chương'),
            index: chapters.length,
          ),
        );
      }
    }
    return chapters;
  }

  @override
  Future<ChapterContent> chapter(
    CatalogueBook book,
    CatalogueChapter chapter,
  ) async {
    _reference(book);
    final ref = _url(chapter.ref).toString();
    final execution = await _run(book.sourceId, 'chap', [
      ref.replaceFirst(RegExp(r'/$'), ''),
    ], expectedKind: book.kind);
    final package = execution.package, result = execution.output;
    if (package.kind == ContentKind.novel) {
      if (result['data'] is! String) {
        throw const ApiException(
          'Nguồn chưa trả nội dung truyện chữ.',
          code: 'INVALID_SOURCE_DATA',
        );
      }
      final content = _sanitize(result['data'] as String, ref);
      if (content.trim().isEmpty) {
        throw const ApiException(
          'Chương truyện rỗng; nguồn có thể đã đổi.',
          code: 'EMPTY_CHAPTER',
        );
      }
      return ChapterContent(kind: ContentKind.novel, html: content);
    }
    final values = _list(result['data']);
    if (values.isEmpty || values.length > 2000) {
      throw const ApiException(
        'Chương chưa có danh sách ảnh hợp lệ.',
        code: 'EMPTY_CHAPTER',
      );
    }
    final images = <String>[], imageHeaders = <String, Map<String, String>>{};
    for (final value in values) {
      final item = value is String ? {'url': value} : _map(value);
      final url = _url(
        _required(item['url'] ?? item['src'] ?? item['link'], 'URL ảnh'),
        ref,
      ).toString();
      images.add(url);
      if (item['headers'] != null) {
        imageHeaders[url] = _headers(item['headers']);
      }
    }
    return ChapterContent(
      kind: ContentKind.manga,
      images: images,
      imageHeaders: imageHeaders,
    );
  }

  @override
  Future<List<Map<String, dynamic>>> sourcePreferences(
    CatalogueSource source,
  ) async {
    throw const ApiException(
      'Chưa có giao diện cấu hình động vBook; script dùng giá trị mặc định của gói.',
      code: 'UNSUPPORTED_CAPABILITY',
    );
  }

  @override
  Future<void> setSourcePreference(
    CatalogueSource source,
    int position,
    dynamic value,
  ) async {
    throw const ApiException(
      'Chưa hỗ trợ sửa cấu hình động vBook.',
      code: 'UNSUPPORTED_CAPABILITY',
    );
  }

  @override
  Future<ExtensionBackup> captureExtensionBackup() async {
    await _ready();
    return _serialized('index', () async {
      // _load reads verified original ZIPs and excludes script localStorage.
      await _load();
      return ExtensionBackup([
        for (final package in _packages.values)
          ExtensionBackupPackage.create(
            engine: SourceEngine.vbook,
            id: package.id,
            name: package.name,
            version: _text(package.metadata['version']),
            bytes: package.bytes,
            origin: _origins[package.id] ?? '',
            sourceIds: [package.id],
          ),
      ]);
    });
  }

  @override
  Future<void> validateExtensionBackup(ExtensionBackup backup) async {
    for (final item in backup.packages) {
      if (item.engine != SourceEngine.vbook || item.preferences.isNotEmpty) {
        throw const FormatException(
          'Engine vBook chưa hỗ trợ tùy chọn động ngoài gói.',
        );
      }
      final package = NativeVbookPackage.parse(item.bytes);
      if (package.id != item.id ||
          package.hash != item.digest ||
          item.sourceIds.length != 1 ||
          item.sourceIds.single != package.id) {
        throw const FormatException(
          'Gói vBook không khớp danh tính nguồn sao lưu.',
        );
      }
    }
  }

  @override
  Future<void> restoreExtensionBackup(ExtensionBackup backup) async {
    await validateExtensionBackup(backup);
    final parsed = {
      for (final item in backup.packages)
        item.id: NativeVbookPackage.parse(item.bytes),
    };
    if (parsed.isEmpty) return;
    final engine = await health();
    if (engine['engine'] != 'vbook') {
      throw const ApiException('Engine vBook chưa sẵn sàng.');
    }
    await _serialized('index', () async {
      await _load();
      final directory = await _storage();
      for (final package in parsed.values) {
        final target = File(
          '${directory.path}/extensions/${package.id}/${package.hash}/package.zip',
        );
        await _atomicBytes(target, package.bytes);
      }
      // Publish all verified packages once, retaining packages installed locally.
      final merged = {..._packages, ...parsed};
      final origins = {
        ..._origins,
        for (final item in backup.packages) item.id: item.origin,
      };
      await _atomicJson(File('${directory.path}/index.json'), {
        'version': 1,
        'extensions': [
          for (final package in merged.values)
            {
              'id': package.id,
              'hash': package.hash,
              'origin': origins[package.id] ?? '',
            },
        ],
      });
      final key = directory.absolute.path;
      _indexRevisions[key] = (_indexRevisions[key] ?? 0) + 1;
      _initialization = null;
      _packages
        ..clear()
        ..addAll(merged);
      _origins
        ..clear()
        ..addAll(origins);
    });
  }

  @override
  void dispose() {
    if (_ownsClient) _client.close();
  }
}

Future<Map<String, dynamic>> _readJson(
  File file,
  Map<String, dynamic> fallback,
) async {
  if (!await file.exists()) return fallback;
  try {
    return _map(
      jsonDecode(utf8.decode(await _readBounded(file, 2 * 1024 * 1024))),
    );
  } on ApiException {
    rethrow;
  } catch (_) {
    throw const ApiException(
      'Dữ liệu extension đã lưu bị hỏng.',
      code: 'INVALID_RUNTIME_DATA',
    );
  }
}

Future<Uint8List> _readBounded(File file, int maximum) async {
  try {
    if (await file.length() > maximum) {
      throw const ApiException(
        'Tệp extension vượt giới hạn.',
        code: 'PACKAGE_CORRUPT',
      );
    }
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in file.openRead()) {
      if (bytes.length + chunk.length > maximum) {
        throw const ApiException(
          'Tệp extension vượt giới hạn.',
          code: 'PACKAGE_CORRUPT',
        );
      }
      bytes.add(chunk);
    }
    return bytes.takeBytes();
  } on FileSystemException {
    throw const ApiException(
      'Thiếu hoặc không đọc được tệp extension.',
      code: 'PACKAGE_CORRUPT',
    );
  }
}

Future<void> _atomicJson(File target, Map<String, dynamic> value) =>
    _atomicBytes(target, utf8.encode(jsonEncode(value)));
Future<void> _atomicBytes(File target, List<int> bytes) async {
  await target.parent.create(recursive: true);
  final pending = await target.parent.createTemp('.pending-');
  try {
    final temporary = File('${pending.path}/contents');
    await temporary.writeAsBytes(bytes, flush: true);
    await temporary.rename(target.path);
  } finally {
    if (await pending.exists()) await pending.delete(recursive: true);
  }
}

Map<String, dynamic> _map(dynamic value) {
  if (value is Map) return Map<String, dynamic>.from(value);
  throw const ApiException(
    'Extension trả cấu trúc dữ liệu không hợp lệ.',
    code: 'INVALID_SOURCE_DATA',
  );
}

List<dynamic> _list(dynamic value) {
  if (value is List) return value;
  throw const ApiException(
    'Extension chưa trả danh sách hợp lệ.',
    code: 'INVALID_SOURCE_DATA',
  );
}

String _text(dynamic value) => value == null ? '' : value.toString();
String _required(dynamic value, String label) {
  if (value is String && value.trim().isNotEmpty) return value;
  throw ApiException('Extension thiếu $label.', code: 'INVALID_SOURCE_DATA');
}

Uri _url(String value, [String? base]) {
  final uri = Uri.tryParse(value.trim());
  final result = uri == null
      ? null
      : base == null
      ? uri
      : Uri.parse(base).resolveUri(uri);
  if (value.trim().isEmpty ||
      result == null ||
      !result.hasAuthority ||
      result.host.isEmpty ||
      !['http', 'https'].contains(result.scheme) ||
      result.userInfo.isNotEmpty ||
      result.hasFragment) {
    throw const ApiException(
      'Nguồn trả URL HTTP/HTTPS không hợp lệ.',
      code: 'INVALID_URL',
    );
  }
  return result;
}

String _optionalUrl(dynamic value, String base) {
  if (value is! String || value.trim().isEmpty) return '';
  try {
    return _url(value, base).toString();
  } on ApiException {
    return '';
  }
}

Map<String, String> _headers(dynamic value) => _map(value).map((key, value) {
  if (value is! String) {
    throw const ApiException(
      'Header ảnh không hợp lệ.',
      code: 'INVALID_SOURCE_DATA',
    );
  }
  return MapEntry(key, value);
});
String _sanitize(String value, String base) {
  final fragment = html.parseFragment(value);
  for (final node in fragment.querySelectorAll(
    'script,style,iframe,object,embed,form,input,button,link,meta',
  )) {
    node.remove();
  }
  for (final node in fragment.querySelectorAll('*')) {
    for (final key in node.attributes.keys.toList()) {
      if (key.toString().toLowerCase().startsWith('on') ||
          ['style', 'srcdoc'].contains(key.toString().toLowerCase())) {
        node.attributes.remove(key);
      }
    }
    for (final key in ['href', 'src']) {
      final uri = node.attributes[key];
      if (uri == null) continue;
      try {
        node.attributes[key] = _url(uri, base).toString();
      } on ApiException {
        node.attributes.remove(key);
      }
    }
  }
  return fragment.nodes
      .map(
        (node) => node is dom.Element
            ? node.outerHtml
            : htmlEscape.convert(node.text ?? ''),
      )
      .join();
}
