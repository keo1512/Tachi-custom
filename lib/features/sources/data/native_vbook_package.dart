import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';

import '../domain/catalogue.dart';

class NativeVbookPackage {
  NativeVbookPackage._({
    required this.id,
    required this.hash,
    required this.manifest,
    required this.scripts,
    required this.bytes,
    required this.kind,
  });

  static const maxArchiveBytes = 64 * 1024 * 1024;
  final String id, hash;
  final Map<String, dynamic> manifest;
  final Map<String, String> scripts;
  final Uint8List bytes;
  final ContentKind kind;
  Map<String, dynamic> get metadata =>
      manifest['metadata'] as Map<String, dynamic>;
  String get name => metadata['name'] as String;
  String get source => metadata['source'] as String;

  static NativeVbookPackage parse(Uint8List input) {
    try {
      if (input.isEmpty || input.length > maxArchiveBytes) {
        _invalid('Gói ZIP rỗng hoặc vượt 64 MB.');
      }
      final bytes = Uint8List.fromList(input);
      final directory = ZipDirectory()..read(InputMemoryStream(bytes));
      if (directory.fileHeaders.length > 512 ||
          directory.totalCentralDirectoryEntries !=
              directory.fileHeaders.length) {
        _invalid('Gói ZIP có quá nhiều mục hoặc thư mục trung tâm bị hỏng.');
      }
      final headers = <String, ZipFileHeader>{};
      final names = <String>{};
      var expanded = 0;
      for (final header in directory.fileHeaders) {
        final name = header.filename;
        final path = name.endsWith('/')
            ? name.substring(0, name.length - 1)
            : name;
        if (!_safePath(path) ||
            !names.add(path.toLowerCase()) ||
            name != header.file?.filename ||
            header.generalPurposeBitFlag & 1 != 0 ||
            ((header.externalFileAttributes >> 16) & 0xf000) == 0xa000 ||
            ![0, 8].contains(header.compressionMethod) ||
            header.uncompressedSize < 0 ||
            header.uncompressedSize > 10 * 1024 * 1024) {
          _invalid(
            'Gói ZIP có tên, kiểu nén, mã hóa hoặc kích thước không hợp lệ.',
          );
        }
        expanded += header.uncompressedSize;
        if (expanded > maxArchiveBytes) {
          _invalid('Gói ZIP giải nén vượt 64 MB.');
        }
        headers[name] = header;
      }
      Uint8List read(String name, int maximum) {
        final header = headers[name];
        if (header == null || header.uncompressedSize > maximum) {
          _invalid('Gói thiếu hoặc vượt giới hạn tệp $name.');
        }
        final stream = header.file!.getStream(decompress: false);
        final output = _BoundedOutput(header.uncompressedSize);
        if (header.compressionMethod == 8) {
          Inflate.stream(stream, output: output);
        } else {
          output.writeStream(stream);
        }
        final data = output.getBytes();
        if (data.length != header.uncompressedSize ||
            getCrc32(data) != header.crc32) {
          _invalid('CRC hoặc kích thước $name không đúng.');
        }
        return data;
      }

      final manifest = _object(
        jsonDecode(utf8.decode(read('plugin.json', 2 * 1024 * 1024))),
      );
      final metadata = _object(manifest['metadata']);
      final mappings = _object(manifest['script']);
      if (metadata['name'] is! String ||
          (metadata['name'] as String).trim().isEmpty ||
          metadata['source'] is! String ||
          (metadata['source'] as String).trim().isEmpty) {
        _invalid('Manifest cần tên và địa chỉ nguồn ổn định.');
      }
      final source = Uri.tryParse(metadata['source'] as String);
      if (source == null ||
          !source.hasAuthority ||
          !['http', 'https'].contains(source.scheme) ||
          source.userInfo.isNotEmpty) {
        _invalid('Địa chỉ nguồn phải là HTTP/HTTPS không chứa mật khẩu.');
      }
      if (metadata['encrypt'] == true) {
        throw const ApiException(
          'Chưa hỗ trợ script vBook mã hóa.',
          code: 'UNSUPPORTED_CAPABILITY',
        );
      }
      if (metadata['encrypt'] != null && metadata['encrypt'] is! bool) {
        _invalid('Cờ encrypt không hợp lệ.');
      }
      final type = (metadata['type'] ?? 'novel').toString().toLowerCase();
      if (!['novel', 'chinese_novel', 'comic'].contains(type)) {
        throw const ApiException(
          'Loại extension vBook chưa được hỗ trợ.',
          code: 'UNSUPPORTED_CAPABILITY',
        );
      }
      final scripts = <String, String>{};
      for (final name in headers.keys) {
        if (RegExp(r'^src/[^/]+\.js$').hasMatch(name)) {
          scripts[name.substring(4)] = utf8.decode(
            read(name, 10 * 1024 * 1024),
          );
        }
      }
      for (final key in ['detail', 'toc', 'chap']) {
        if (!mappings.containsKey(key)) {
          _invalid('Thiếu script $key trong manifest.');
        }
      }
      for (final entry in mappings.entries) {
        final name = entry.value;
        if (name is! String ||
            !RegExp(r'^[^/\\:\x00]+\.js$').hasMatch(name) ||
            !scripts.containsKey(name)) {
          _invalid(
            'Script ${entry.key} bị thiếu hoặc có đường dẫn không hợp lệ.',
          );
        }
      }
      if (manifest['config'] != null) _object(manifest['config']);
      final identity = sha256
          .convert(
            utf8.encode('${metadata['name']}\u0000${metadata['source']}'),
          )
          .toString();
      return NativeVbookPackage._(
        id: 'vb-${identity.substring(0, 24)}',
        hash: sha256.convert(bytes).toString(),
        manifest: manifest,
        scripts: Map.unmodifiable(scripts),
        bytes: bytes,
        kind: type == 'comic' ? ContentKind.manga : ContentKind.novel,
      );
    } on ApiException {
      rethrow;
    } catch (_) {
      _invalid('Gói extension không phải ZIP/manifest UTF-8 hợp lệ.');
    }
  }
}

bool _safePath(String name) =>
    name.isNotEmpty &&
    !name.startsWith('/') &&
    !RegExp(r'[\\:\x00]').hasMatch(name) &&
    !name.split('/').any((part) => part.isEmpty || part == '.' || part == '..');

Map<String, dynamic> _object(dynamic value) {
  if (value is Map<String, dynamic>) return value;
  _invalid('Manifest cần cấu trúc object hợp lệ.');
}

Never _invalid(String message) =>
    throw ApiException(message, code: 'INVALID_PACKAGE');

class _BoundedOutput extends OutputMemoryStream {
  _BoundedOutput(this.maximum) : super(size: maximum > 32768 ? 32768 : maximum);
  final int maximum;
  void _check(int count) {
    if (length + count > maximum) {
      _invalid('Dữ liệu ZIP giải nén vượt giới hạn khai báo.');
    }
  }

  @override
  void writeByte(int value) {
    _check(1);
    super.writeByte(value);
  }

  @override
  void writeBytes(List<int> bytes, {int? length}) {
    _check(length ?? bytes.length);
    super.writeBytes(bytes, length: length);
  }

  @override
  void writeStream(InputStream stream) {
    _check(stream.length);
    super.writeStream(stream);
  }

  @override
  void writeBackReference(int distance, int count) {
    _check(count);
    super.writeBackReference(distance, count);
  }
}
