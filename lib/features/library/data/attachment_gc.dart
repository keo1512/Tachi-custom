import 'dart:io';

import 'package:crypto/crypto.dart';

class UnusedAttachment {
  const UnusedAttachment(this.file, this.key, this.size, this.digest);
  final File file;
  final String key, digest;
  final int size;
}

/// Never follows links, removes directories, or accepts paths outside the owned
/// content-addressed attachments directory. Unknown files remain untouched.
Future<List<UnusedAttachment>> findUnusedAttachments(
  Directory root,
  Set<String> retained, {
  void Function()? guard,
}) async {
  guard?.call();
  await _regularDirectory(root);
  final result = <UnusedAttachment>[];
  await for (final folder in root.list(followLinks: false)) {
    guard?.call();
    final name = folder.uri.pathSegments.where((part) => part.isNotEmpty).last;
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(name)) continue;
    if (await FileSystemEntity.type(folder.path, followLinks: false) !=
        FileSystemEntityType.directory) {
      throw const FileSystemException(
        'Thư mục ảnh không an toàn; chưa dọn dữ liệu.',
      );
    }
    await _regularDirectory(Directory(folder.path));
    await for (final entity in Directory(
      folder.path,
    ).list(followLinks: false)) {
      guard?.call();
      final digest = entity.uri.pathSegments.last;
      if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(digest)) continue;
      if (await FileSystemEntity.type(entity.path, followLinks: false) !=
          FileSystemEntityType.file) {
        throw const FileSystemException(
          'Tệp ảnh không an toàn; chưa dọn dữ liệu.',
        );
      }
      final key = '$name/$digest';
      if (retained.contains(key)) continue;
      final file = File(entity.path);
      final size = await file.length();
      if (size > 8 * 1024 * 1024 ||
          (await sha256.bind(file.openRead()).first).toString() != digest) {
        throw const FormatException(
          'Tệp ảnh không nhận diện hoặc hỏng; chưa dọn dữ liệu.',
        );
      }
      result.add(UnusedAttachment(file, key, size, digest));
    }
  }
  return result;
}

Future<void> verifyUnusedAttachment(
  UnusedAttachment candidate,
  Directory root,
) async {
  await _regularDirectory(root);
  final folder = Directory('${root.path}/${candidate.key.split('/').first}');
  await _regularDirectory(folder);
  final expected = File('${root.path}/${candidate.key}').absolute.uri
      .normalizePath();
  if (candidate.file.absolute.uri.normalizePath() != expected ||
      await FileSystemEntity.type(candidate.file.path, followLinks: false) !=
          FileSystemEntityType.file ||
      await candidate.file.length() != candidate.size ||
      (await sha256.bind(candidate.file.openRead()).first).toString() !=
          candidate.digest) {
    throw const FileSystemException('Tệp ảnh đã thay đổi; chưa dọn dữ liệu.');
  }
}

Future<void> _regularDirectory(Directory directory) async {
  final type = await FileSystemEntity.type(directory.path, followLinks: false);
  if (type != FileSystemEntityType.directory) {
    throw const FileSystemException(
      'Vị trí lưu ảnh không an toàn; chưa dọn dữ liệu.',
    );
  }
}
