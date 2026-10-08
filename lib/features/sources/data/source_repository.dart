import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../domain/catalogue.dart';

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
            kind: engine == SourceEngine.tachimanga
                ? ContentKind.manga
                : _kind(item['kind']),
            engine: engine,
          );
        })
        .toList(growable: false);
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
      return _manga(
        _map(
          await _json(
            'GET',
            _url(
              book.engine,
              ['api', 'v1', 'manga', book.ref],
              {'onlineFetch': 'true'},
            ),
          ),
        ),
        book.sourceId,
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
    final result = _list(
      await _json(
        'GET',
        _url(
          book.engine,
          book.engine == SourceEngine.tachimanga
              ? ['api', 'v1', 'manga', book.ref, 'chapters']
              : ['v1', 'sources', book.sourceId, 'chapters'],
          book.engine == SourceEngine.tachimanga
              ? {'onlineFetch': 'true'}
              : {'ref': book.ref},
        ),
      ),
    );
    return result
        .map((value) {
          final item = _map(value);
          final index = _integer(item['index']);
          return CatalogueChapter(
            // Suwayomi addresses chapters by source-order index, not database ID.
            ref: book.engine == SourceEngine.tachimanga
                ? '$index'
                : _id(item['ref']),
            title: _requiredText(
              item[book.engine == SourceEngine.tachimanga ? 'name' : 'title'],
              'tên chương',
            ),
            index: index,
          );
        })
        .toList(growable: false);
  }

  Future<ChapterContent> chapter(
    CatalogueBook book,
    CatalogueChapter chapter,
  ) async {
    if (book.engine == SourceEngine.tachimanga) {
      final info = _map(
        await _json(
          'GET',
          _url(book.engine, [
            'api',
            'v1',
            'manga',
            book.ref,
            'chapter',
            chapter.ref,
          ]),
        ),
      );
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
              book.ref,
              'chapter',
              chapter.ref,
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
      description: _text(item['description']),
      coverUrl: _url(SourceEngine.tachimanga, [
        'api',
        'v1',
        'manga',
        ref,
        'thumbnail',
      ]).toString(),
      sourceId: item['sourceId'] == null ? sourceId : _id(item['sourceId']),
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
