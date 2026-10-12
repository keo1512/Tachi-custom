import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:http/http.dart' as http;

import '../domain/catalogue.dart';

class ExtensionIndex {
  const ExtensionIndex(
    this.url,
    this.engine,
    this.entries, {
    this.error = '',
    this.name = '',
    this.label = '',
  });
  final String url, error, name, label;
  final SourceEngine engine;
  final List<CatalogueExtension> entries;
  String get identity => '${engine.name}:$url';
  String get displayName => label.isNotEmpty
      ? label
      : name.isNotEmpty
      ? name
      : engine == SourceEngine.tachimanga
      ? 'Tachimanga'
      : 'vBook';
  ExtensionIndex withLabel(String value) => ExtensionIndex(
    url,
    engine,
    entries,
    error: error,
    name: name,
    label: value,
  );
}

/// Reads public catalogues directly. Installation still uses an engine adapter.
class ExtensionIndexRepository {
  ExtensionIndexRepository(this.client);
  final http.Client client;
  static const maxBytes = 8 * 1024 * 1024;
  static const maxEntries = 10000;

  static Uri validUrl(String value) {
    final uri = Uri.tryParse(value.trim());
    if (uri == null ||
        !['https', 'http'].contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasFragment) {
      throw const FormatException('Link kho phải là HTTP/HTTPS hợp lệ.');
    }
    return uri;
  }

  static Uri normalize(String value, SourceEngine engine) {
    final uri = validUrl(value);
    final path = uri.path.replaceFirst(RegExp(r'/+$'), '');
    if (engine == SourceEngine.tachimanga &&
        ((uri.host == 'github.com' &&
                (path == '/keiyoushi/extensions' ||
                    path == '/keiyoushi/extensions/tree/repo')) ||
            (uri.host == 'raw.githubusercontent.com' &&
                uri.path.startsWith('/keiyoushi/extensions/repo/') &&
                [
                  'index.min.json',
                  'index.json',
                  'repo.json',
                ].contains(uri.pathSegments.last)))) {
      return Uri.parse(
        'https://raw.githubusercontent.com/keiyoushi/extensions/repo/index.pb',
      );
    }
    if (uri.host == 'github.com' &&
        uri.pathSegments.length >= 5 &&
        uri.pathSegments[2] == 'blob') {
      return uri.replace(
        host: 'raw.githubusercontent.com',
        pathSegments: [
          uri.pathSegments[0],
          uri.pathSegments[1],
          ...uri.pathSegments.skip(3),
        ],
      );
    }
    return uri;
  }

  Future<Uint8List> _download(Uri url) async {
    final response = await client
        .send(http.Request('GET', url))
        .timeout(const Duration(seconds: 30));
    if (response.statusCode != 200) {
      throw FormatException(
        'Không đọc được kho (HTTP ${response.statusCode}).',
      );
    }
    if ((response.contentLength ?? 0) > maxBytes) {
      throw const FormatException('Danh sách kho vượt giới hạn 8 MB.');
    }
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in response.stream.timeout(
      const Duration(seconds: 30),
    )) {
      if (bytes.length + chunk.length > maxBytes) {
        throw const FormatException('Danh sách kho vượt giới hạn 8 MB.');
      }
      bytes.add(chunk);
    }
    return bytes.takeBytes();
  }

  Future<ExtensionIndex> fetch(String value, SourceEngine engine) async {
    final url = normalize(value, engine);
    final bytes = _decode(await _download(url));
    if (engine == SourceEngine.tachimanga && url.path.endsWith('.pb')) {
      final store = _Proto(bytes);
      final embedded = store.optional(101);
      final listUrl = store.text(102);
      final Uint8List list;
      var resourceBase = url;
      if (embedded != null) {
        list = embedded;
      } else if (listUrl.isNotEmpty) {
        resourceBase = validUrl(url.resolve(listUrl).toString());
        list = _decode(await _download(resourceBase));
      } else {
        throw const FormatException('Kho protobuf thiếu danh sách extension.');
      }
      final entries = _Proto(list).values(1);
      if (entries.length > maxEntries) {
        throw const FormatException('Kho có quá nhiều extension.');
      }
      final ids = <String>{};
      return ExtensionIndex(
        url.toString(),
        engine,
        List.unmodifiable(
          entries.map((raw) {
            final item = _Proto(raw);
            final resources = _Proto(item.required(3));
            final id = _nonempty(item.text(2));
            if (!ids.add(id)) {
              throw const FormatException('Kho chứa extension trùng ID.');
            }
            final apkUrl = _nonempty(resources.text(1));
            final languages = item
                .values(8)
                .map((s) => _Proto(s).text(3))
                .toSet();
            return CatalogueExtension(
              id: id,
              name: _nonempty(item.text(1)),
              version: item.text(6),
              engine: engine,
              lang: languages.length == 1 ? languages.single : 'all',
              packageUrl: validUrl(resourceBase.resolve(apkUrl).toString())
                  .toString(),
              iconUrl: _iconUrl(resourceBase, resources.text(2)),
            );
          }),
        ),
        name: _repositoryName(store.text(1)),
      );
    }
    Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(bytes));
    } catch (_) {
      throw const FormatException(
        'Link này chưa trả danh sách kho. Với vbookext.me, hãy sao chép link kho JSON của tác giả trên trang đó.',
      );
    }
    if (engine == SourceEngine.tachimanga &&
        decoded is Map &&
        decoded['index_v2'] is String) {
      final next = validUrl(
        url.resolve(decoded['index_v2'] as String).toString(),
      );
      if (next == url || !next.path.endsWith('.pb')) {
        throw const FormatException('index_v2 không hợp lệ.');
      }
      final fetched = await fetch(next.toString(), engine);
      return ExtensionIndex(
        fetched.url,
        fetched.engine,
        fetched.entries,
        name: _repositoryName(decoded['name']).isEmpty
            ? fetched.name
            : _repositoryName(decoded['name']),
      );
    }
    final values = decoded is List
        ? decoded
        : decoded is Map
        ? engine == SourceEngine.tachimanga && decoded['extensionList'] is Map
              ? (decoded['extensionList'] as Map)['extensions']
              : decoded['data']
        : null;
    if (values is! List || values.length > maxEntries) {
      throw const FormatException('Kho không có danh sách extension hợp lệ.');
    }
    final ids = <String>{};
    final entries = values
        .map((raw) {
          if (raw is! Map) {
            throw const FormatException('Mục extension không hợp lệ.');
          }
          final String packageUrl, id;
          Object? icon;
          var version = '${raw['version'] ?? ''}';
          var lang =
              '${raw[engine == SourceEngine.vbook ? 'locale' : 'lang'] ?? ''}';
          if (engine == SourceEngine.tachimanga) {
            if (raw.containsKey('packageName') ||
                raw.containsKey('resources')) {
              id = _nonempty(raw['packageName']);
              final resources = raw['resources'];
              if (resources is! Map) {
                throw const FormatException('Mục extension thiếu resources.');
              }
              packageUrl = validUrl(
                url.resolve(_nonempty(resources['apkUrl'])).toString(),
              ).toString();
              icon = resources['iconUrl'] ?? '';
              version = '${raw['versionName'] ?? ''}';
              final sources = raw['sources'];
              if (sources is List) {
                final languages = sources
                    .whereType<Map>()
                    .map((source) => source['language'])
                    .whereType<String>()
                    .map((language) => language.trim())
                    .where((language) => language.isNotEmpty)
                    .toSet();
                lang = languages.length == 1 ? languages.single : 'all';
              }
            } else {
              id = _nonempty(raw['pkg']);
              final apk = _nonempty(raw['apk']);
              if (apk.contains('/') ||
                  apk.contains('\\') ||
                  !apk.endsWith('.apk')) {
                throw const FormatException('Tên APK không hợp lệ.');
              }
              packageUrl = validUrl(url.resolve('apk/$apk').toString())
                  .toString();
            }
          } else {
            packageUrl = validUrl(
              url.resolve(_nonempty(raw['path'])).toString(),
            ).toString();
            id = packageUrl;
          }
          if (!ids.add(id)) {
            throw const FormatException('Kho chứa extension trùng ID.');
          }
          return CatalogueExtension(
            id: id,
            name: _nonempty(raw['name']),
            version: version,
            engine: engine,
            packageUrl: packageUrl,
            iconUrl: _iconUrl(
              url,
              icon ??
                  raw['icon'] ??
                  raw['iconUrl'] ??
                  (engine == SourceEngine.tachimanga &&
                          RegExp(r'^[A-Za-z0-9_.]+$').hasMatch(id)
                      ? 'icon/$id.png'
                      : ''),
            ),
            lang: lang,
          );
        })
        .toList(growable: false);
    return ExtensionIndex(
      url.toString(),
      engine,
      entries,
      name: decoded is Map ? _repositoryName(decoded['name']) : '',
    );
  }

  static String _repositoryName(Object? value) =>
      value is String &&
          value.trim().length <= 100 &&
          !RegExp(r'[\x00-\x1f]').hasMatch(value)
      ? value.trim()
      : '';

  static String _nonempty(Object? value) {
    if (value is! String || value.trim().isEmpty || value.length > 4096) {
      throw const FormatException('Thiếu tên, ID hoặc link extension.');
    }
    return value.trim();
  }

  // Icons are optional. A malformed image link must not hide a valid package
  // catalogue or introduce a non-HTTP URL into the image loader.
  static String _iconUrl(Uri base, Object? value) {
    if (value is! String || value.trim().isEmpty || value.length > 4096) {
      return '';
    }
    try {
      return validUrl(base.resolve(value.trim()).toString()).toString();
    } on FormatException {
      return '';
    }
  }

  // The current Keiyoushi .pb is a gzip file, without Content-Encoding.
  // The sink caps expanded bytes. Verify the trailer explicitly because
  // native gzip can emit all content from a file missing part of its trailer.
  static Uint8List _decode(Uint8List bytes) {
    if (bytes.length < 2 || bytes[0] != 31 || bytes[1] != 139) return bytes;
    if (bytes.length < 18 || bytes[2] != 8 || bytes[3] & 0xe0 != 0) {
      throw const FormatException('Header gzip của kho không hợp lệ.');
    }
    final output = _IndexBytesSink(maxBytes);
    final decoder = gzip.decoder.startChunkedConversion(output);
    decoder.add(bytes);
    decoder.close();
    final decoded = output.bytes.takeBytes();
    final trailer = ByteData.sublistView(bytes, bytes.length - 8);
    if (trailer.getUint32(0, Endian.little) != getCrc32(decoded) ||
        trailer.getUint32(4, Endian.little) != decoded.length) {
      throw const FormatException(
        'CRC hoặc kích thước gzip của kho không đúng.',
      );
    }
    return decoded;
  }
}

class _IndexBytesSink implements Sink<List<int>> {
  _IndexBytesSink(this.limit);
  final int limit;
  final bytes = BytesBuilder(copy: false);
  @override
  void add(List<int> chunk) {
    if (bytes.length + chunk.length > limit) {
      throw const FormatException('Danh sách kho giải nén vượt giới hạn 8 MB.');
    }
    bytes.add(chunk);
  }

  @override
  void close() {}
}

// Schema: Mihon NetworkExtensionStore.kt, @ProtoNumber fields. Unknown scalar
// fields are skipped; lengths and count are bounded before copying any message.
class _Proto {
  _Proto(Uint8List bytes) {
    var offset = 0, fields = 0;
    int varint({bool scalar = false}) {
      var value = 0;
      for (var shift = 0; shift < 70; shift += 7) {
        if (offset >= bytes.length) {
          throw const FormatException('Protobuf bị cắt.');
        }
        final byte = bytes[offset++];
        if (scalar && shift == 63 && byte > 1) {
          throw const FormatException('Protobuf varint vượt quá 64 bit.');
        }
        if (!scalar && (shift > 28 || (shift == 28 && byte > 15))) {
          throw const FormatException('Protobuf tag hoặc length quá lớn.');
        }
        if (shift < 35) value |= (byte & 127) << shift;
        if (byte < 128) return value;
      }
      throw const FormatException('Protobuf varint quá dài.');
    }

    while (offset < bytes.length) {
      if (++fields > 100000) {
        throw const FormatException('Protobuf có quá nhiều trường.');
      }
      final tag = varint(), field = tag >> 3, wire = tag & 7;
      if (field == 0) {
        throw const FormatException('Protobuf field không hợp lệ.');
      }
      if (wire == 0) {
        varint(scalar: true);
        continue;
      }
      final length = wire == 1
          ? 8
          : wire == 5
          ? 4
          : wire == 2
          ? varint()
          : -1;
      if (length < 0 || offset + length > bytes.length) {
        throw const FormatException('Protobuf length không hợp lệ.');
      }
      if (wire == 2) {
        _fields
            .putIfAbsent(field, () => [])
            .add(Uint8List.sublistView(bytes, offset, offset + length));
      }
      offset += length;
    }
  }
  final _fields = <int, List<Uint8List>>{};
  List<Uint8List> values(int field) => _fields[field] ?? const [];
  Uint8List? optional(int field) => values(field).firstOrNull;
  Uint8List required(int field) =>
      optional(field) ??
      (throw const FormatException('Protobuf thiếu trường bắt buộc.'));
  String text(int field) =>
      optional(field) == null ? '' : utf8.decode(required(field));
}
