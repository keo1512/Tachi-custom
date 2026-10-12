import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class LocalComicFolder {
  const LocalComicFolder(this.id, this.label);
  final String id, label;
  factory LocalComicFolder.fromMap(Map<Object?, Object?> value) {
    final id = value['id'], label = value['label'];
    if (id is! String ||
        !RegExp(r'^[a-f0-9]{32}$').hasMatch(id) ||
        label is! String ||
        label.isEmpty ||
        label.length > 255) {
      throw const FormatException('Thư mục truyện không hợp lệ.');
    }
    return LocalComicFolder(id, label);
  }
}

class LocalComicFile {
  const LocalComicFile(this.path, this.size, this.stamp);
  final String path;
  final int size, stamp;
}

class LocalComicScan {
  const LocalComicScan(this.digest, this.files);
  final String digest;
  final List<LocalComicFile> files;
}

void validateLocalComicPath(String path) {
  if (path.isEmpty ||
      utf8.encode(path).length > 4096 ||
      path.startsWith('/') ||
      path.contains(RegExp(r'[\\:\x00-\x1f\x7f]')) ||
      path
          .split('/')
          .any((part) => part.isEmpty || part == '.' || part == '..')) {
    throw const FormatException('Đường dẫn thư mục truyện không hợp lệ.');
  }
}

abstract interface class LocalComicFilesPlatform {
  Future<LocalComicFolder?> current();
  Future<LocalComicFolder?> choose();
  Future<void> forget();
  Future<LocalComicScan> list(String folderId);
  Future<Uint8List> read(String folderId, LocalComicFile file);
  Future<void> confirm(String folderId, String digest);
  Future<Map<String, Uint8List>> extractRar(Uint8List data);
}

final localComicFilesPlatformProvider = Provider<LocalComicFilesPlatform>(
  (_) => NativeLocalComicFilesPlatform(),
);

class NativeLocalComicFilesPlatform implements LocalComicFilesPlatform {
  static const channel = MethodChannel('dev.tachibooks/local-comics');
  bool get available => !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;
  void _require() {
    if (!available) {
      throw UnsupportedError('Chọn thư mục và giải nén RAR cần iOS.');
    }
  }

  @override
  Future<LocalComicFolder?> current() async {
    if (!available) return null;
    final value = await channel.invokeMapMethod<Object?, Object?>('current');
    return value == null ? null : LocalComicFolder.fromMap(value);
  }

  @override
  Future<LocalComicFolder?> choose() async {
    _require();
    final value = await channel.invokeMapMethod<Object?, Object?>('choose');
    return value == null ? null : LocalComicFolder.fromMap(value);
  }

  @override
  Future<void> forget() async {
    _require();
    await channel.invokeMethod<void>('forget');
  }

  @override
  Future<LocalComicScan> list(String folderId) async {
    _require();
    final value = await channel.invokeMapMethod<Object?, Object?>('list', {
      'folderId': folderId,
    });
    if (value == null ||
        value['digest'] is! String ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(value['digest'] as String) ||
        value['files'] is! List) {
      throw const FormatException('Không đọc được danh sách thư mục truyện.');
    }
    final files = <LocalComicFile>[], identities = <String>{};
    for (final raw in value['files'] as List) {
      if (raw is! Map ||
          raw['path'] is! String ||
          raw['size'] is! int ||
          raw['stamp'] is! int ||
          (raw['size'] as int) < 0 ||
          (raw['size'] as int) > 100 * 1024 * 1024 ||
          (raw['stamp'] as int) < 0) {
        throw const FormatException('Thông tin tệp truyện không hợp lệ.');
      }
      final path = raw['path'] as String;
      validateLocalComicPath(path);
      if (!identities.add(path) || files.length >= 10000) {
        throw const FormatException('Tệp truyện trùng hoặc quá nhiều mục.');
      }
      files.add(LocalComicFile(path, raw['size'] as int, raw['stamp'] as int));
    }
    return LocalComicScan(value['digest'] as String, List.unmodifiable(files));
  }

  @override
  Future<Uint8List> read(String folderId, LocalComicFile file) async {
    _require();
    validateLocalComicPath(file.path);
    final bytes = await channel.invokeMethod<Uint8List>('read', {
      'folderId': folderId,
      'path': file.path,
      'size': file.size,
      'stamp': file.stamp,
    });
    if (bytes == null || bytes.length != file.size) {
      throw const FormatException('Tệp truyện thay đổi khi đang đọc.');
    }
    return bytes;
  }

  @override
  Future<void> confirm(String folderId, String digest) async {
    _require();
    await channel.invokeMethod<void>('confirm', {
      'folderId': folderId,
      'digest': digest,
    });
  }

  @override
  Future<Map<String, Uint8List>> extractRar(Uint8List data) async {
    _require();
    if (data.isEmpty || data.length > 100 * 1024 * 1024) {
      throw const FormatException('RAR trống hoặc vượt giới hạn 100 MB.');
    }
    final entries = await channel.invokeMapMethod<String, Object?>(
      'extractRar',
      data,
    );
    if (entries == null || entries.isEmpty || entries.length > 10000) {
      throw const FormatException('RAR không có nội dung hợp lệ.');
    }
    final result = <String, Uint8List>{};
    var total = 0;
    for (final entry in entries.entries) {
      validateLocalComicPath(entry.key);
      if (entry.value is! Uint8List ||
          (entry.value as Uint8List).length > 8 * 1024 * 1024) {
        throw const FormatException('Tệp trong RAR vượt giới hạn 8 MB.');
      }
      total += (entry.value as Uint8List).length;
      if (total > 200 * 1024 * 1024) {
        throw const FormatException('RAR vượt giới hạn 200 MB sau giải nén.');
      }
      result[entry.key] = entry.value as Uint8List;
    }
    return result;
  }
}
