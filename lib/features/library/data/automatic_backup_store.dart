import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'backup_service.dart';

class StoredBackup {
  const StoredBackup(this.name, this.createdAt, this.size);
  final String name;
  final DateTime createdAt;
  final int size;
}

/// Private app storage; source documents and Files-provider inputs are untouched.
class AutomaticBackupStore {
  AutomaticBackupStore(this.directory, this.backup);
  final Directory directory;
  final BackupService backup;
  Future<void> _pending = Future.value();
  static final _name = RegExp(r'^tachibooks-auto-(\d{16,20})\.json$');

  Future<T> _serialized<T>(Future<T> Function() action) {
    final next = _pending.then((_) => action());
    _pending = next.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return next;
  }

  Future<List<StoredBackup>> list() async {
    if (!await directory.exists()) return [];
    final result = <StoredBackup>[];
    await for (final entity in directory.list(followLinks: false)) {
      if (entity is! File) continue;
      final name = entity.uri.pathSegments.last;
      final match = _name.firstMatch(name);
      final value = int.tryParse(match?.group(1) ?? '');
      if (value == null) continue;
      result.add(
        StoredBackup(
          name,
          DateTime.fromMicrosecondsSinceEpoch(value),
          await entity.length(),
        ),
      );
    }
    return result..sort((a, b) => b.name.compareTo(a.name));
  }

  File _file(String name) {
    if (!_name.hasMatch(name)) {
      throw const FormatException('Tên bản sao lưu không hợp lệ.');
    }
    return File('${directory.path}${Platform.pathSeparator}$name');
  }

  Future<Uint8List> read(String name) async {
    final file = _file(name);
    if (await file.length() > BackupService.maxBackupBytes) {
      throw const FormatException('Bản sao lưu vượt giới hạn 128 MB.');
    }
    final bytes = await file.readAsBytes();
    backup.validate(bytes);
    return bytes;
  }

  Future<StoredBackup> create(
    DateTime now, {
    int keep = 3,
    void Function()? beforeCapture,
  }) => _serialized(() async {
    if (keep < 1 || keep > 10) {
      throw ArgumentError('Giữ từ 1 đến 10 bản sao lưu.');
    }
    final bytes = await backup.export(beforeCapture: beforeCapture);
    await directory.create(recursive: true);
    var stamp = now.microsecondsSinceEpoch;
    while (await _file('tachibooks-auto-$stamp.json').exists()) {
      stamp++;
    }
    final name = 'tachibooks-auto-$stamp.json';
    final destination = _file(name);
    final pending = File('${destination.path}.pending');
    try {
      await pending.writeAsBytes(bytes, flush: true);
      final stored = await pending.readAsBytes();
      if (sha256.convert(stored) != sha256.convert(bytes)) {
        throw const FileSystemException('Không xác minh được dữ liệu sao lưu.');
      }
      backup.validate(stored);
      await pending.rename(destination.path);
    } finally {
      if (await pending.exists()) await pending.delete();
    }
    // Retention happens only after the new backup was flushed and verified.
    for (final old in (await list()).skip(keep)) {
      await _file(old.name).delete();
    }
    return StoredBackup(
      name,
      DateTime.fromMicrosecondsSinceEpoch(stamp),
      bytes.length,
    );
  });

  Future<void> delete(String name) => _serialized(() async {
    final file = _file(name);
    if (await file.exists()) await file.delete();
  });
}

class AutomaticBackupPolicy {
  const AutomaticBackupPolicy({this.hours = 0, this.keep = 3});
  final int hours, keep;
  String encode() => jsonEncode({'hours': hours, 'keep': keep});
  factory AutomaticBackupPolicy.decode(String? raw) {
    if (raw == null) return const AutomaticBackupPolicy();
    final json = jsonDecode(raw);
    if (json is! Map ||
        ![0, 6, 12, 24, 48, 72].contains(json['hours']) ||
        json['keep'] is! int ||
        (json['keep'] as int) < 1 ||
        (json['keep'] as int) > 10) {
      throw const FormatException('Thiết lập sao lưu tự động không hợp lệ.');
    }
    return AutomaticBackupPolicy(
      hours: json['hours'] as int,
      keep: json['keep'] as int,
    );
  }
}
