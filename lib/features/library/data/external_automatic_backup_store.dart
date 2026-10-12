import 'dart:io';
import 'dart:typed_data';

import 'automatic_backup_store.dart';
import 'backup_directory_platform.dart';
import 'backup_service.dart';

/// A fixed bookmark identity protects an in-flight run from destination changes.
class ExternalAutomaticBackupStore extends AutomaticBackupStore {
  ExternalAutomaticBackupStore(
    BackupService backup,
    this.platform,
    this.location,
  ) : super(Directory('.'), backup);
  final BackupDirectoryPlatform platform;
  final BackupDirectoryLocation location;
  Future<void> _tail = Future.value();
  static final _name = RegExp(r'^tachibooks-auto-(\d{16,20})\.json$');

  Future<T> _run<T>(Future<T> Function() action) {
    final next = _tail.then((_) => action());
    _tail = next.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return next;
  }

  void _checkName(String name) {
    if (_name.stringMatch(name) != name) {
      throw const FormatException('Tên bản sao lưu không hợp lệ.');
    }
  }

  StoredBackup _entry(Map<String, dynamic> value) {
    final name = value['name'], size = value['size'];
    if (name is! String ||
        size is! int ||
        size < 1 ||
        size > BackupService.maxBackupBytes) {
      throw const FormatException('Thông tin bản sao lưu không hợp lệ.');
    }
    _checkName(name);
    final stamp = int.tryParse(_name.firstMatch(name)![1]!);
    if (stamp == null) {
      throw const FormatException('Thời điểm sao lưu không hợp lệ.');
    }
    return StoredBackup(name, DateTime.fromMicrosecondsSinceEpoch(stamp), size);
  }

  @override
  Future<List<StoredBackup>> list() async =>
      (await platform.list(location.id)).map(_entry).toList()
        ..sort((a, b) => b.name.compareTo(a.name));
  @override
  Future<Uint8List> read(String name) async {
    _checkName(name);
    final bytes = await platform.read(location.id, name);
    backup.validate(bytes);
    return bytes;
  }

  @override
  Future<StoredBackup> create(
    DateTime now, {
    int keep = 3,
    void Function()? beforeCapture,
  }) => _run(() async {
    if (keep < 1 || keep > 10) {
      throw ArgumentError('Giữ từ 1 đến 10 bản sao lưu.');
    }
    final bytes = await backup.export(beforeCapture: beforeCapture);
    backup.validate(bytes);
    final stored = _entry(
      await platform.write(
        location.id,
        'tachibooks-auto-${now.microsecondsSinceEpoch}.json',
        bytes,
      ),
    );
    if (stored.size != bytes.length) {
      throw const FormatException('Dung lượng bản đã ghi không khớp dữ liệu.');
    }
    // The native write flushes, hashes and verifies before publishing the name.
    // Only the managed subfolder is pruned, never other Files-provider contents.
    for (final old in (await list()).skip(keep)) {
      await read(
        old.name,
      ); // Do not delete foreign or damaged files by name alone.
      await platform.delete(location.id, old.name);
    }
    return stored;
  });
  @override
  Future<void> delete(String name) => _run(() async {
    _checkName(name);
    await read(name);
    await platform.delete(location.id, name);
  });
}
