import 'dart:convert';
import 'dart:io';

import 'backup_configuration.dart';

/// Private fixed-name files; no source book, credentials or external paths.
class ConfigurationRestoreFiles {
  ConfigurationRestoreFiles(String path)
    : directory = Directory(
        Directory(path).absolute.uri.normalizePath().toFilePath(),
      );
  final Directory directory;
  String get checkpointPath => '${directory.path}/configuration.json';
  String get journalPath => '${directory.path}/restore-journal.json';

  Future<void> _checkDirectory() async {
    Future<void> checkParents() async {
      var parent = directory;
      while (true) {
        final type = await FileSystemEntity.type(
          parent.path,
          followLinks: false,
        );
        if (type != FileSystemEntityType.notFound &&
            type != FileSystemEntityType.directory) {
          throw const FileSystemException(
            'Thư mục khôi phục thiết lập không được là liên kết hoặc file.',
          );
        }
        final next = parent.parent;
        if (next.path == parent.path) break;
        parent = next;
      }
    }

    await checkParents();
    await directory.create(recursive: true);
    await checkParents();
  }

  Future<String?> _read(String path, int limit) async {
    await _checkDirectory();
    final type = await FileSystemEntity.type(path, followLinks: false);
    if (type == FileSystemEntityType.notFound) return null;
    if (type != FileSystemEntityType.file) {
      throw const FileSystemException(
        'File khôi phục thiết lập không hợp lệ; dữ liệu được giữ nguyên.',
      );
    }
    final file = File(path);
    if (await file.length() > limit) {
      throw const FormatException('File khôi phục thiết lập vượt giới hạn.');
    }
    final bytes = <int>[];
    await for (final chunk in file.openRead()) {
      if (bytes.length + chunk.length > limit) {
        throw const FormatException('File khôi phục thiết lập vượt giới hạn.');
      }
      bytes.addAll(chunk);
    }
    return utf8.decode(bytes);
  }

  Future<void> _write(String path, String value, int limit) async {
    await _checkDirectory();
    final bytes = utf8.encode(value);
    if (bytes.length > limit) {
      throw const FormatException('File khôi phục thiết lập vượt giới hạn.');
    }
    final type = await FileSystemEntity.type(path, followLinks: false);
    if (type != FileSystemEntityType.notFound &&
        type != FileSystemEntityType.file) {
      throw const FileSystemException(
        'Không ghi đè liên kết hoặc thư mục khôi phục.',
      );
    }
    final pending = File('$path.pending');
    final pendingType = await FileSystemEntity.type(
      pending.path,
      followLinks: false,
    );
    if (pendingType != FileSystemEntityType.notFound &&
        pendingType != FileSystemEntityType.file) {
      throw const FileSystemException('File tạm khôi phục không hợp lệ.');
    }
    try {
      await pending.writeAsBytes(bytes, flush: true);
      if (await _read(pending.path, limit) != value) {
        throw const FileSystemException(
          'Không xác minh được file khôi phục thiết lập.',
        );
      }
      final destinationType = await FileSystemEntity.type(
        path,
        followLinks: false,
      );
      if (destinationType != FileSystemEntityType.notFound &&
          destinationType != FileSystemEntityType.file) {
        throw const FileSystemException(
          'Không ghi đè liên kết hoặc thư mục khôi phục.',
        );
      }
      // Rename replaces the previous file atomically; never delete it first.
      await pending.rename(path);
    } finally {
      if (await FileSystemEntity.type(pending.path, followLinks: false) ==
          FileSystemEntityType.file) {
        await pending.delete();
      }
    }
  }

  Future<BackupConfiguration?> readCheckpoint() async {
    final raw = await _read(checkpointPath, BackupConfiguration.maxBytes);
    return raw == null ? null : BackupConfiguration.fromJson(jsonDecode(raw));
  }

  Future<void> writeCheckpoint(BackupConfiguration value) => _write(
    checkpointPath,
    jsonEncode(value.toJson()),
    BackupConfiguration.maxBytes,
  );
  Future<String?> readJournal() =>
      _read(journalPath, BackupConfiguration.maxBytes * 2 + 4096);
  Future<void> writeJournal(Map<String, dynamic> value) => _write(
    journalPath,
    jsonEncode(value),
    BackupConfiguration.maxBytes * 2 + 4096,
  );
  Future<void> clearJournal() async {
    await _checkDirectory();
    final type = await FileSystemEntity.type(journalPath, followLinks: false);
    if (type == FileSystemEntityType.notFound) return;
    if (type != FileSystemEntityType.file) {
      throw const FileSystemException('File khôi phục thiết lập không hợp lệ.');
    }
    await File(journalPath).delete();
  }
}
