import 'dart:typed_data';

import 'package:archive/archive.dart';

/// Read selected ZIP members only, with limits before and during decompression.
class BoundedBackupZip {
  BoundedBackupZip(Uint8List bytes, {this.maximum = 128 * 1024 * 1024}) {
    final directory = ZipDirectory()..read(InputMemoryStream(bytes));
    if (directory.fileHeaders.length > 10000 ||
        directory.totalCentralDirectoryEntries !=
            directory.fileHeaders.length) {
      throw const FormatException('Sao lưu có quá nhiều tệp ZIP.');
    }
    var expanded = 0;
    for (final header in directory.fileHeaders) {
      final path = header.filename;
      if (path.startsWith('/') ||
          path.contains('\\') ||
          path.split('/').any((part) => part == '..' || part == '.') ||
          path.contains(':') ||
          files.containsKey(path) ||
          header.filename != header.file?.filename ||
          header.generalPurposeBitFlag & 1 != 0 ||
          ((header.externalFileAttributes >> 16) & 0xf000) == 0xa000 ||
          ![0, 8].contains(header.compressionMethod) ||
          header.uncompressedSize < 0) {
        throw const FormatException(
          'ZIP sao lưu có tên tệp hoặc cách nén không hợp lệ.',
        );
      }
      expanded += header.uncompressedSize;
      if (expanded > maximum) {
        throw const FormatException('ZIP giải nén vượt giới hạn 128 MB.');
      }
      files[path] = header;
    }
  }
  final int maximum;
  final Map<String, ZipFileHeader> files = {};

  Uint8List read(String name, {int? limit}) {
    final header = files[name];
    if (header == null) {
      throw const FormatException('ZIP sao lưu thiếu tệp bắt buộc.');
    }
    final bound = limit ?? maximum;
    if (header.uncompressedSize > bound) {
      throw const FormatException('Tệp sao lưu vượt giới hạn.');
    }
    final stream = header.file!.getStream(decompress: false);
    final output = BoundedBackupOutput(header.uncompressedSize);
    if (header.compressionMethod == 8) {
      Inflate.stream(stream, output: output);
    } else {
      output.writeStream(stream);
    }
    final bytes = output.getBytes();
    if (bytes.length != header.uncompressedSize ||
        getCrc32(bytes) != header.crc32) {
      throw const FormatException(
        'CRC hoặc kích thước ZIP sao lưu không đúng.',
      );
    }
    return bytes;
  }
}

class BoundedBackupOutput extends OutputMemoryStream {
  BoundedBackupOutput(this.maximum)
    : super(size: maximum > 32768 ? 32768 : maximum);
  final int maximum;
  void _check(int count) {
    if (length + count > maximum) {
      throw const FormatException('Dữ liệu giải nén vượt giới hạn.');
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
