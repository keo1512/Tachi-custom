import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../domain/catalogue.dart';
import '../domain/source_filters.dart';

/// Client for two companion runtimes; it does not execute APK or JS on-device.
class SourceRepository {
  SourceRepository({
    required String tachimangaUrl,
    required String vbookUrl,
    http.Client? client,
    this.timeout = const Duration(seconds: 30),
  }) : _tachimanga = _optionalBase(tachimangaUrl),
       _vbook = _optionalBase(vbookUrl),
       _client = client ?? http.Client(),
       _ownsClient = client == null;

  final Uri? _tachimanga;
  final Uri? _vbook;
  final http.Client _client;
  final bool _ownsClient;
  final Duration timeout;
  final Map<String, Future<String>> _restoredManga = {};

  bool requiresExternalConnection(SourceEngine engine) => true;

  bool usesNativeImageLoader(CatalogueBook book) => false;

  bool usesNativeCoverLoader(CatalogueBook book) => false;

  bool canOpenNativeWebsite(CatalogueBook book) => false;

  bool supportsCatalogueBrowsing(SourceEngine engine) => false;

  bool supportsSourceFilters(SourceEngine engine) => false;
  Future<SourceFilterSet> sourceFilters(CatalogueSource source) =>
      throw const ApiException('Engine này chưa cung cấp bộ lọc của nguồn.');
  Future<List<CatalogueBook>> searchFiltered(
    CatalogueSource source,
    String query,
    SourceFilterSet filters, {
    int page = 1,
  }) => throw const ApiException('Engine này chưa hỗ trợ tìm kiếm với bộ lọc.');

  Future<List<CatalogueBook>> browse(
    CatalogueSource source, {
    required SourceBrowseMode mode,
    int page = 1,
  }) => throw const ApiException(
    'Engine này chưa cung cấp danh sách phổ biến hoặc mới nhất.',
  );

  bool supportsExtensionRemoval(SourceEngine engine) => false;

  bool supportsExtensionFileImport(SourceEngine engine) => false;

  Future<CatalogueExtension> installExtensionBytes(
    SourceEngine engine,
    Uint8List bytes,
  ) => throw const ApiException(
    'Engine này chưa hỗ trợ nhập extension từ Files.',
  );

  Future<void> uninstallExtension(SourceEngine engine, String packageId) =>
      throw const ApiException(
        'Engine này chưa hỗ trợ gỡ extension trong ứng dụng.',
      );

  Future<void> openWebsite(CatalogueBook book) =>
      throw UnsupportedError('This engine has no native source browser.');

  Future<SourceImageData> fetchImage(
    CatalogueBook book,
    CatalogueChapter chapter,
    int page,
    String url,
  ) => throw UnsupportedError('This engine uses ordinary HTTP images.');

  Future<SourceImageData> fetchCover(CatalogueBook book) =>
      throw UnsupportedError('This engine uses ordinary HTTP covers.');

  bool _externalManga(CatalogueBook book) =>
      book.engine == SourceEngine.tachimanga &&
      !RegExp(r'^\d+$').hasMatch(book.ref);

  /// Backup URLs remain stable locally; resolve them against this companion.
  /// Never substitute a title match from another URL or another source.
  Future<String> _mangaId(CatalogueBook book) async {
    if (!_externalManga(book)) return book.ref;
    final key = jsonEncode([book.sourceId, book.ref]);
    final pending = _restoredManga.putIfAbsent(key, () => _resolveManga(book));
    try {
      return await pending;
    } catch (_) {
      if (identical(_restoredManga[key], pending)) _restoredManga.remove(key);
      rethrow;
    }
  }

  Future<String> _resolveManga(CatalogueBook book) async {
    final source = BigInt.tryParse(book.sourceId);
    if (source == null || source.toSigned(64) != source) {
      throw const ApiException('ID nguồn trong bản sao lưu không hợp lệ.');
    }
    final response = _map(
      await _json(
        'POST',
        _url(book.engine, ['api', 'graphql']),
        body: {
          'query': r'query RestoredManga($condition: MangaConditionInput!) { mangas(condition: $condition, first: 2) { nodes { id sourceId url } } }',
          'variables': {
            'condition': {'sourceId': book.sourceId, 'url': book.ref},
          },
        },
      ),
    );
    if (response['errors'] is List && (response['errors'] as List).isNotEmpty) {
      throw const ApiException(
        'Engine không tra được URL truyện trong bản sao lưu.',
        code: 'GRAPHQL_ERROR',
      );
    }
    final nodes = _list(_map(_map(response['data'])['mangas'])['nodes']);
    var matched = nodes
        .map(_map)
        .where(
          (item) =>
              _id(item['sourceId']) == book.sourceId &&
              _text(item['url']) == book.ref,
        )
        .toList();
    if (matched.isEmpty) {
      // Search populates the companion DB. Accept only the original URL.
      final result = _map(
        await _json(
          'POST',
          _url(
            book.engine,
            ['api', 'v1', 'source', book.sourceId, 'quick-search'],
            {'pageNum': '1'},
          ),
          body: {'searchTerm': book.title, 'filter': null},
        ),
      );
      matched = _list(result['mangaList'])
          .map(_map)
          .where(
            (item) =>
                _id(item['sourceId']) == book.sourceId &&
                _text(item['url']) == book.ref,
          )
          .toList();
    }
    if (matched.length != 1) {
      throw const ApiException(
        'Chưa tìm thấy đúng URL truyện trong nguồn gốc. Hãy cài extension tương ứng và tìm lại truyện ở nguồn đó.',
        code: 'RESTORED_TITLE_UNRESOLVED',
      );
    }
    final id = _id(matched.single['id']);
    if (!RegExp(r'^\d+$').hasMatch(id)) {
      throw const ApiException('Engine trả mã truyện không hợp lệ.');
    }
    return id;
  }

  Uri _base(SourceEngine engine) {
    final base = engine == SourceEngine.tachimanga ? _tachimanga : _vbook;
    if (base == null) {
      throw ApiException(
        'Chưa cấu hình kết nối ${engine == SourceEngine.tachimanga ? 'Suwayomi' : 'vBook'}.',
        code: 'NOT_CONFIGURED',
      );
    }
    return base;
  }

  Uri _url(
    SourceEngine engine,
    List<String> path, [
    Map<String, String>? query,
  ]) {
    final base = _base(engine);
    return base.replace(
      pathSegments: [
        ...base.pathSegments.where((part) => part.isNotEmpty),
        ...path,
      ],
      queryParameters: query,
    );
  }

  Future<Map<String, dynamic>> health(SourceEngine engine) async => _map(
    await _json(
      'GET',
      _url(
        engine,
        engine == SourceEngine.tachimanga
            ? ['api', 'v1', 'settings', 'about']
            : ['v1', 'health'],
      ),
    ),
  );

  Future<List<CatalogueSource>> listSources(SourceEngine engine) async {
    final result = _list(
      await _json(
        'GET',
        _url(
          engine,
          engine == SourceEngine.tachimanga
              ? ['api', 'v1', 'source', 'list']
              : ['v1', 'sources'],
        ),
      ),
    );
    return result
        .map((value) {
          final item = _map(value);
          return CatalogueSource(
            id: _id(item['id']),
            name: _requiredText(item['name'], 'tên nguồn'),
            lang: _text(item['lang']),
            baseUrl: _text(item['baseUrl']),
            iconUrl: _sourceIconUrl(engine, item['iconUrl']),
            kind: engine == SourceEngine.tachimanga
                ? ContentKind.manga
                : _kind(item['kind']),
            engine: engine,
          );
        })
        .toList(growable: false);
  }

  String _sourceIconUrl(SourceEngine engine, dynamic value) {
    if (value is! String || value.trim().isEmpty || value.length > 4096) {
      return '';
    }
    final icon = Uri.tryParse(value.trim());
    if (icon == null) return '';
    final base = _base(engine);
    final prefix = base.path.endsWith('/') ? base.path : '${base.path}/';
    // Suwayomi supplies /api/v1/extension/icon/<package>. Keep a configured
    // reverse-proxy prefix, as other companion API requests do.
    final resolved = icon.hasScheme || icon.hasAuthority
        ? base.resolveUri(icon)
        : base
              .replace(path: prefix)
              .resolveUri(
                icon.replace(path: icon.path.replaceFirst(RegExp(r'^/+'), '')),
              );
    try {
      return _validateUrl(resolved.toString()).toString();
    } on ApiException {
      // An optional malformed icon must not hide an otherwise usable source.
      return '';
    }
  }

  Future<List<Map<String, dynamic>>> sourcePreferences(
    CatalogueSource source,
  ) async {
    _requireSourcePreferences(source);
    final result = _list(
      await _json(
        'GET',
        _url(source.engine, ['api', 'v1', 'source', source.id, 'preferences']),
      ),
    );
    return result.map(_map).toList(growable: false);
  }

  Future<void> setSourcePreference(
    CatalogueSource source,
    int position,
    dynamic value,
  ) async {
    _requireSourcePreferences(source);
    if (position < 0) {
      throw const ApiException('Vị trí cấu hình nguồn không hợp lệ.');
    }
    // Suwayomi v2.4.2366 accepts a String, then converts it using the
    // preference's defaultValueType (String, Boolean or Set<String>).
    final String encoded;
    if (value is String || value is bool) {
      encoded = value.toString();
    } else if (value is List<String>) {
      encoded = jsonEncode(value);
    } else {
      throw const ApiException('Giá trị cấu hình nguồn chưa được hỗ trợ.');
    }
    await _json(
      'POST',
      _url(source.engine, ['api', 'v1', 'source', source.id, 'preferences']),
      body: {'position': position, 'value': encoded},
    );
  }

  void _requireSourcePreferences(CatalogueSource source) {
    if (source.engine != SourceEngine.tachimanga) {
      throw const ApiException(
        'Runtime vBook chưa hỗ trợ thay đổi cấu hình nguồn.',
        code: 'UNSUPPORTED_CAPABILITY',
      );
    }
  }

  Future<List<CatalogueBook>> search(
    CatalogueSource source,
    String query, {
    int page = 1,
  }) async {
    if (page < 1) {
      throw const ApiException('Số trang tìm kiếm phải từ 1 trở lên.');
    }
    if (source.engine == SourceEngine.tachimanga) {
      // REST v1 expects singular `filter`, and the page parameter is `pageNum`.
      final result = _map(
        await _json(
          'POST',
          _url(
            source.engine,
            ['api', 'v1', 'source', source.id, 'quick-search'],
            {'pageNum': '$page'},
          ),
          body: {'searchTerm': query, 'filter': null},
        ),
      );
      return _list(result['mangaList'])
          .map((item) => _manga(_map(item), source.id))
          .toList(growable: false);
    }
    final result = _list(
      await _json(
        'GET',
        _url(
          source.engine,
          ['v1', 'sources', source.id, 'search'],
          {'query': query, 'page': '$page'},
        ),
      ),
    );
    return result
        .map((item) => _vbookBook(_map(item), source.id, source.kind))
        .toList(growable: false);
  }

  Future<CatalogueBook> detail(CatalogueBook book) async {
    if (book.engine == SourceEngine.tachimanga) {
      final mangaId = await _mangaId(book);
      final detail = _manga(
        _map(
          await _json(
            'GET',
            _url(
              book.engine,
              ['api', 'v1', 'manga', mangaId],
              {'onlineFetch': 'true'},
            ),
          ),
        ),
        book.sourceId,
      );
      if (!_externalManga(book)) return detail;
      return CatalogueBook(
        ref: book.ref,
        title: detail.title,
        author: detail.author,
        artist: detail.artist,
        genres: detail.genres,
        description: detail.description,
        coverUrl: detail.coverUrl,
        sourceId: detail.sourceId,
        status: detail.status,
        kind: detail.kind,
        engine: detail.engine,
      );
    }
    return _vbookBook(
      _map(
        await _json(
          'GET',
          _url(
            book.engine,
            ['v1', 'sources', book.sourceId, 'detail'],
            {'ref': book.ref},
          ),
        ),
      ),
      book.sourceId,
      book.kind,
    );
  }

  Future<List<CatalogueChapter>> chapters(CatalogueBook book) async {
    final mangaId = book.engine == SourceEngine.tachimanga
        ? await _mangaId(book)
        : book.ref;
    if (book.engine == SourceEngine.tachimanga) {
      await _verifyMangaIdentity(book, mangaId);
    }
    final result = _list(
      await _json(
        'GET',
        _url(
          book.engine,
          book.engine == SourceEngine.tachimanga
              ? ['api', 'v1', 'manga', mangaId, 'chapters']
              : ['v1', 'sources', book.sourceId, 'chapters'],
          book.engine == SourceEngine.tachimanga
              ? {'onlineFetch': 'true'}
              : {'ref': book.ref},
        ),
      ),
    );
    final chapters = result
        .map((value) {
          final item = _map(value);
          final index = _integer(item['index']);
          return CatalogueChapter(
            // URLs are identities; the mutable source-order index is resolved
            // against the current source immediately before an uncached read.
            ref: book.engine == SourceEngine.tachimanga
                ? _requiredText(item['url'], 'URL chương')
                : _id(item['ref']),
            title: _requiredText(
              item[book.engine == SourceEngine.tachimanga ? 'name' : 'title'],
              'tên chương',
            ),
            index: index,
            number: book.engine == SourceEngine.tachimanga
                ? catalogueChapterNumber(item['chapterNumber'])
                : null,
            uploadedAt: book.engine == SourceEngine.tachimanga
                ? catalogueUploadDate(item['dateUpload'])
                : null,
            scanlator: _text(item['scanlator']),
          );
        })
        .toList(growable: false);
    if (book.engine == SourceEngine.tachimanga) {
      // Suwayomi source-order starts at the oldest chapter; REST lists it
      // newest-first. Keep reader "next" and library positions chronological.
      chapters.sort((a, b) => a.index.compareTo(b.index));
    }
    if (book.engine == SourceEngine.tachimanga &&
        (chapters.any((chapter) => chapter.index < 0) ||
            chapters.map((chapter) => chapter.ref).toSet().length !=
                chapters.length ||
            chapters.map((chapter) => chapter.index).toSet().length !=
                chapters.length)) {
      throw const ApiException(
        'Mục lục nguồn có URL hoặc thứ tự chương trùng, không thể xác định đúng chương.',
        code: 'CHAPTER_IDENTITY_CHANGED',
      );
    }
    return chapters;
  }

  Future<ChapterContent> chapter(
    CatalogueBook book,
    CatalogueChapter chapter,
  ) async {
    if (book.engine == SourceEngine.tachimanga) {
      final mangaId = await _mangaId(book);
      await _verifyMangaIdentity(book, mangaId);
      final items = _list(
        await _json(
          'GET',
          _url(
            book.engine,
            ['api', 'v1', 'manga', mangaId, 'chapters'],
            {'onlineFetch': 'true'},
          ),
        ),
      ).map(_map).toList(growable: false);
      final legacyIndex = RegExp(r'^\d+$').hasMatch(chapter.ref)
          ? int.tryParse(chapter.ref)
          : null;
      final matched = items
          .where(
            (item) => legacyIndex == null
                ? _text(item['url']) == chapter.ref
                : _integer(item['index']) == legacyIndex,
          )
          .toList();
      if (matched.length != 1) {
        throw const ApiException(
          'Không xác định được đúng chương gốc trong mục lục nguồn.',
          code: 'CHAPTER_IDENTITY_CHANGED',
        );
      }
      final selected = matched.single;
      final index = _integer(selected['index']);
      final chapterUrl = _requiredText(selected['url'], 'URL chương');
      if (index < 0 ||
          items.where((item) => _integer(item['index']) == index).length != 1 ||
          items.where((item) => _text(item['url']) == chapterUrl).length != 1 ||
          (legacyIndex != null &&
              (chapter.index != legacyIndex ||
                  _text(selected['name']) != chapter.title ||
                  items
                          .where((item) => _text(item['name']) == chapter.title)
                          .length !=
                      1))) {
        throw const ApiException(
          'Thứ tự hoặc tên chương cũ đã thay đổi hoặc không xác định. Dữ liệu đã lưu được giữ nguyên; hãy mở lại đúng chương từ nguồn.',
          code: 'CHAPTER_IDENTITY_CHANGED',
        );
      }
      final chapterRef = '$index';
      final info = _map(
        await _json(
          'GET',
          _url(book.engine, [
            'api',
            'v1',
            'manga',
            mangaId,
            'chapter',
            chapterRef,
          ]),
        ),
      );
      if (_text(info['url']) != chapterUrl ||
          _integer(info['index']) != index ||
          (legacyIndex != null && _text(info['name']) != chapter.title)) {
        throw const ApiException(
          'Nguồn đã thay đổi chương trong lúc mở. Hãy thử lại từ mục lục.',
          code: 'CHAPTER_IDENTITY_CHANGED',
        );
      }
      final count = _integer(info['pageCount']);
      if (count < 1 || count > 10000) {
        throw const ApiException(
          'Runtime chưa trả danh sách trang hợp lệ cho chương này.',
        );
      }
      return ChapterContent(
        kind: ContentKind.manga,
        images: List.generate(
          count,
          (index) => _url(
            book.engine,
            [
              'api',
              'v1',
              'manga',
              mangaId,
              'chapter',
              chapterRef,
              'page',
              '$index',
            ],
            {'updateProgress': 'false'},
          ).toString(),
          growable: false,
        ),
      );
    }
    final content = _map(
      await _json(
        'GET',
        _url(
          book.engine,
          ['v1', 'sources', book.sourceId, 'chapter'],
          {'ref': chapter.ref},
        ),
      ),
    );
    final kind = _kind(content['kind']);
    if (kind == ContentKind.novel) {
      return ChapterContent(
        kind: kind,
        html: _requiredText(content['html'], 'nội dung chương'),
      );
    }
    final images = <String>[];
    final imageHeaders = <String, Map<String, String>>{};
    for (final image in _list(content['images'])) {
      final item = image is String ? {'url': image} : _map(image);
      final url = _validateUrl(_requiredText(item['url'], 'URL ảnh'))
          .toString();
      images.add(url);
      if (item['headers'] != null) {
        imageHeaders[url] = _headers(item['headers']);
      }
    }
    if (images.isEmpty) {
      throw const ApiException('Chương này chưa có ảnh để đọc.');
    }
    return ChapterContent(
      kind: kind,
      images: images,
      headers: content['headers'] == null
          ? const {}
          : _headers(content['headers']),
      imageHeaders: imageHeaders,
    );
  }

  Future<void> _verifyMangaIdentity(CatalogueBook book, String mangaId) async {
    final item = _map(
      await _json('GET', _url(book.engine, ['api', 'v1', 'manga', mangaId])),
    );
    if (_id(item['id']) != mangaId ||
        _id(item['sourceId']) != book.sourceId ||
        (_externalManga(book) && _text(item['url']) != book.ref)) {
      throw const ApiException(
        'Mã truyện hoặc nguồn đã thay đổi. Không thể mở nội dung bằng kết nối hiện tại.',
        code: 'MANGA_IDENTITY_CHANGED',
      );
    }
  }

  Future<List<CatalogueExtension>> extensions(SourceEngine engine) async {
    final result = _list(
      await _json(
        'GET',
        _url(
          engine,
          engine == SourceEngine.tachimanga
              ? ['api', 'v1', 'extension', 'list']
              : ['v1', 'extensions'],
        ),
      ),
    );
    return result
        .map((value) {
          final item = _map(value);
          return CatalogueExtension(
            id: _id(item[engine == SourceEngine.tachimanga ? 'pkgName' : 'id']),
            name: _requiredText(item['name'], 'tên extension'),
            version: _text(
              item[engine == SourceEngine.tachimanga
                  ? 'versionName'
                  : 'version'],
            ),
            engine: engine,
            installed:
                engine == SourceEngine.vbook || item['installed'] == true,
            packageUrl: _text(item['packageUrl']),
            lang: _text(item['lang']),
            limitations: item['limitations'] is List
                ? (item['limitations'] as List)
                      .map(_text)
                      .toList(growable: false)
                : const [],
          );
        })
        .toList(growable: false);
  }

  Future<void> installExtension(SourceEngine engine, String packageUrl) async {
    if (engine == SourceEngine.vbook) {
      await _json(
        'POST',
        _url(engine, ['v1', 'extensions', 'install']),
        body: {'url': _validateUrl(packageUrl).toString()},
      );
      return;
    }
    if (RegExp(r'^eu\.kanade\.tachiyomi\.extension\.[A-Za-z0-9_.]+$')
        .hasMatch(packageUrl)) {
      await _send(
        http.Request(
          'GET',
          _url(engine, ['api', 'v1', 'extension', 'install', packageUrl]),
        ),
      );
      return;
    }
    final uri = _validateUrl(packageUrl);
    final bytes = (await _send(
      http.Request('GET', uri),
      maxBytes: 32 * 1024 * 1024,
    )).bodyBytes;
    if (bytes.isEmpty) throw const ApiException('Gói APK tải về rỗng.');
    final name =
        uri.pathSegments.isNotEmpty && uri.pathSegments.last.endsWith('.apk')
        ? uri.pathSegments.last
        : 'extension.apk';
    final request = http.MultipartRequest(
      'POST',
      _url(engine, ['api', 'v1', 'extension', 'install']),
    )..files.add(http.MultipartFile.fromBytes('file', bytes, filename: name));
    await _send(request);
  }

  Future<void> addRepository(SourceEngine engine, String registryUrl) async {
    final uri = _validateUrl(registryUrl);
    if (engine == SourceEngine.vbook) {
      await _json(
        'POST',
        _url(engine, ['v1', 'repositories']),
        body: {'url': uri.toString()},
      );
      return;
    }
    // Current upstream provides repository addition as a GraphQL mutation.
    // A server that lacks it must report an error instead of pretending success.
    final result = _map(
      await _json(
        'POST',
        _url(engine, ['api', 'graphql']),
        body: {
          'query': r'mutation AddStore($input: AddExtensionStoreInput!) { addExtensionStore(input: $input) { extensionStore { indexUrl } } }',
          'variables': {
            'input': {'indexUrl': uri.toString()},
          },
        },
      ),
    );
    if (result['errors'] is List && (result['errors'] as List).isNotEmpty) {
      throw ApiException(
        'Suwayomi không thêm được kho extension: ${_graphqlError(result['errors'])}',
        code: 'GRAPHQL_ERROR',
      );
    }
    final data = _map(result['data']);
    final added = _map(_map(data['addExtensionStore'])['extensionStore']);
    if (added['indexUrl'] is! String || (added['indexUrl'] as String).isEmpty) {
      throw const ApiException(
        'Suwayomi chưa xác nhận kho extension đã được thêm.',
      );
    }
  }

  CatalogueBook _manga(Map<String, dynamic> item, String sourceId) {
    final ref = _id(item['id']);
    return CatalogueBook(
      ref: ref,
      title: _requiredText(item['title'], 'tên truyện'),
      author: _text(item['author']),
      artist: _text(item['artist']),
      genres: item['genre'] is List
          ? _list(item['genre']).map(_text).toList(growable: false)
          : const [],
      description: _text(item['description']),
      coverUrl: _url(SourceEngine.tachimanga, [
        'api',
        'v1',
        'manga',
        ref,
        'thumbnail',
      ]).toString(),
      sourceId: item['sourceId'] == null ? sourceId : _id(item['sourceId']),
      status: catalogueStatus(item['status']),
      kind: ContentKind.manga,
      engine: SourceEngine.tachimanga,
    );
  }

  CatalogueBook _vbookBook(
    Map<String, dynamic> item,
    String sourceId,
    ContentKind kind,
  ) => CatalogueBook(
    ref: _id(item['ref']),
    title: _requiredText(item['title'], 'tên truyện'),
    author: _text(item['author']),
    description: _text(item['description']),
    coverUrl: _text(item['coverUrl']),
    sourceId: item['sourceId'] == null ? sourceId : _id(item['sourceId']),
    kind: item['kind'] == null ? kind : _kind(item['kind']),
    engine: SourceEngine.vbook,
  );

  Future<dynamic> _json(String method, Uri uri, {Object? body}) async {
    final request = http.Request(method, uri)
      ..headers['Accept'] = 'application/json';
    if (body != null) {
      request.headers['Content-Type'] = 'application/json';
      request.body = jsonEncode(body);
    }
    final response = await _send(request);
    try {
      return decodeCatalogueJson(response.body);
    } on FormatException {
      throw const ApiException(
        'Runtime trả dữ liệu không đúng định dạng JSON.',
      );
    }
  }

  Future<http.Response> _send(
    http.BaseRequest request, {
    int maxBytes = 8 * 1024 * 1024,
  }) async {
    request.followRedirects = false;
    try {
      final response = await (() async {
        final streamed = await _client.send(request);
        final bytes = BytesBuilder(copy: false);
        await for (final chunk in streamed.stream) {
          if (bytes.length + chunk.length > maxBytes) {
            throw const ApiException(
              'Dữ liệu runtime vượt quá kích thước cho phép.',
            );
          }
          bytes.add(chunk);
        }
        return http.Response.bytes(
          bytes.takeBytes(),
          streamed.statusCode,
          headers: streamed.headers,
          request: request,
        );
      })().timeout(timeout);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        String detail = '';
        String? code;
        try {
          final data = _map(decodeCatalogueJson(response.body));
          final error = data['error'];
          if (error is Map) {
            detail = _text(error['message']);
            code = _text(error['code']);
          } else {
            detail = _text(data['message'] ?? error);
          }
        } catch (_) {
          /* Do not display raw HTML, credentials or a stack trace. */
        }
        final auth = response.statusCode == 401 || response.statusCode == 403;
        final message = auth
            ? 'Runtime yêu cầu xác thực hoặc quyền truy cập.'
            : detail.isEmpty
            ? 'Runtime trả lỗi HTTP ${response.statusCode}.'
            : _short(detail);
        throw ApiException(
          message,
          statusCode: response.statusCode,
          code: code,
        );
      }
      return response;
    } on ApiException {
      rethrow;
    } on TimeoutException {
      throw const ApiException(
        'Runtime phản hồi quá lâu. Kiểm tra kết nối và thử lại.',
        code: 'TIMEOUT',
      );
    } catch (_) {
      throw const ApiException(
        'Không kết nối được runtime. Kiểm tra địa chỉ máy chủ và mạng.',
        code: 'CONNECTION_FAILED',
      );
    }
  }

  void dispose() {
    if (_ownsClient) _client.close();
  }
}

Uri _validateUrl(String value, {bool isBase = false}) {
  final uri = Uri.tryParse(value.trim());
  if (uri == null ||
      !uri.hasAuthority ||
      uri.host.isEmpty ||
      (uri.scheme != 'http' && uri.scheme != 'https') ||
      uri.userInfo.isNotEmpty ||
      uri.hasFragment ||
      (isBase && uri.hasQuery)) {
    throw const ApiException(
      'Địa chỉ phải là HTTP/HTTPS, không chứa tài khoản, mật khẩu hoặc fragment. Địa chỉ runtime không được có query.',
    );
  }
  return uri;
}

Uri? _optionalBase(String value) =>
    value.trim().isEmpty ? null : _validateUrl(value, isBase: true);

Map<String, dynamic> _map(dynamic value) {
  if (value is Map<String, dynamic>) return value;
  throw const ApiException('Runtime trả cấu trúc dữ liệu không hợp lệ.');
}

List<dynamic> _list(dynamic value) {
  if (value is List) return value;
  throw const ApiException('Runtime chưa trả danh sách hợp lệ.');
}

String _text(dynamic value) => value == null ? '' : value.toString();
String _requiredText(dynamic value, String label) {
  if (value is String && value.trim().isNotEmpty) return value;
  throw ApiException('Runtime thiếu $label hợp lệ.');
}

String _id(dynamic value) {
  if (value is int || value is String && value.isNotEmpty) {
    return value.toString();
  }
  throw const ApiException(
    'Runtime trả mã định danh không hợp lệ hoặc mất độ chính xác.',
  );
}

int _integer(dynamic value) {
  final result = value is int
      ? value
      : value is String
      ? int.tryParse(value)
      : null;
  if (result == null) {
    throw const ApiException('Runtime trả chỉ số chương/trang không hợp lệ.');
  }
  return result;
}

ContentKind _kind(dynamic value) => switch (value) {
  'manga' || 'comic' => ContentKind.manga,
  'novel' || 'chinese_novel' => ContentKind.novel,
  _ => throw const ApiException('Runtime trả loại nội dung chưa được hỗ trợ.'),
};

Map<String, String> _headers(dynamic value) => _map(value).map((key, value) {
  if (value is! String) {
    throw const ApiException('Runtime trả HTTP header không hợp lệ.');
  }
  return MapEntry(key, value);
});

String _short(String message) =>
    message.length > 600 ? '${message.substring(0, 600)}…' : message;
String _graphqlError(dynamic errors) => _short(
  (_list(errors).first as Map)['message']?.toString() ??
      'GraphQL không xác nhận thay đổi.',
);

/// Quotes oversized integer tokens before jsonDecode can round them on web.
/// String contents, decimal fractions and exponent tokens remain untouched.
dynamic decodeCatalogueJson(String input) {
  final output = StringBuffer();
  var quoted = false;
  var escaped = false;
  var index = 0;
  while (index < input.length) {
    final character = input[index];
    if (quoted) {
      output.write(character);
      if (escaped) {
        escaped = false;
      } else if (character == r'\') {
        escaped = true;
      } else if (character == '"') {
        quoted = false;
      }
      index++;
      continue;
    }
    if (character == '"') {
      quoted = true;
      output.write(character);
      index++;
      continue;
    }
    if (character == '-' || RegExp(r'[0-9]').hasMatch(character)) {
      final start = index++;
      while (index < input.length &&
          RegExp(r'[0-9eE+\.\-]').hasMatch(input[index])) {
        index++;
      }
      final token = input.substring(start, index);
      final integer = RegExp(r'^-?(0|[1-9][0-9]*)$').hasMatch(token)
          ? BigInt.tryParse(token)
          : null;
      output.write(
        integer != null && integer.abs() > BigInt.from(9007199254740991)
            ? '"$token"'
            : token,
      );
    } else {
      output.write(character);
      index++;
    }
  }
  return jsonDecode(output.toString());
}
