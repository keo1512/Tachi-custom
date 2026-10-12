import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../../sources/domain/catalogue.dart';
import '../../sources/domain/extension_backup.dart';
import '../../sources/domain/native_source_engine.dart';
import 'library_repository.dart';
import 'library_snapshot.dart';

abstract interface class ExtensionBackupStore {
  Future<T> exclusive<T>(Future<T> Function() action);
  Future<ExtensionBackup?> capture();
  Future<void> recoverPending();
  Future<void> prepare(
    ExtensionBackup incoming, {
    required String oldLibraryFingerprint,
    required String newLibraryFingerprint,
  });
  Future<void> complete();
  Future<void> discardPrepared();
}

/// Library/configuration commit stays atomic. Runtime installation is a separate
/// durable replay: a process death or unsupported package cannot lose the plan.
/// An absent bundle never means uninstall, and packages not in the plan remain.
class RepositoryExtensionBackupStore implements ExtensionBackupStore {
  RepositoryExtensionBackupStore({
    required this.runtime,
    required this.repository,
    required this.engines,
    // Public injection keeps the storage implementation field private.
    Directory? directory,
    // ignore: prefer_initializing_formals
  }) : _directory = directory;
  final NativeExtensionBackupEngine runtime;
  final LibraryRepository repository;
  final Set<SourceEngine> engines;
  Directory? _directory;
  static final _tails = <String, Future<void>>{};
  Future<Directory> _storage() async => _directory ??= Directory(
    '${(await getApplicationSupportDirectory()).path}/TachiBooks/extension-restore',
  );
  Future<File> _journal() async {
    final directory = await _storage();
    // Fixed sandbox paths only, refusing symlinks before any write/read.
    var parent = directory;
    while (true) {
      final type = await FileSystemEntity.type(parent.path, followLinks: false);
      if (type != FileSystemEntityType.notFound &&
          type != FileSystemEntityType.directory) {
        throw const FileSystemException(
          'Thư mục phục hồi extension không hợp lệ.',
        );
      }
      final next = parent.parent;
      if (next.path == parent.path) break;
      parent = next;
    }
    await directory.create(recursive: true);
    final file = File('${directory.path}/pending.json');
    final type = await FileSystemEntity.type(file.path, followLinks: false);
    if (type != FileSystemEntityType.notFound &&
        type != FileSystemEntityType.file) {
      throw const FileSystemException('File phục hồi extension không hợp lệ.');
    }
    return file;
  }

  @override
  Future<T> exclusive<T>(Future<T> Function() action) =>
      runtime is NativeExtensionBackupTransaction
      ? (runtime as NativeExtensionBackupTransaction).exclusiveExtensionBackup(
          action,
        )
      : action();

  Future<T> _exclusive<T>(Future<T> Function() action) => exclusive(() async {
    final key = (await _storage()).absolute.path;
    final previous = _tails[key] ?? Future<void>.value();
    final future = previous.then((_) => action());
    final tail = future.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    _tails[key] = tail;
    try {
      return await future;
    } finally {
      if (identical(_tails[key], tail)) _tails.remove(key);
    }
  });

  Future<Map<String, dynamic>?> _read() async {
    final file = await _journal();
    if (!await file.exists()) return null;
    if (await file.length() > LibrarySnapshot.maxBytes) {
      throw const FormatException('Kế hoạch phục hồi extension vượt 128 MiB.');
    }
    final builder = <int>[];
    await for (final chunk in file.openRead()) {
      if (builder.length + chunk.length > LibrarySnapshot.maxBytes) {
        throw const FormatException(
          'Kế hoạch phục hồi extension vượt 128 MiB.',
        );
      }
      builder.addAll(chunk);
    }
    final value = jsonDecode(utf8.decode(builder));
    if (value is! Map<String, dynamic> ||
        value.keys.any(
          (key) =>
              !{'version', 'stage', 'old', 'next', 'extensions'}.contains(key),
        ) ||
        value['version'] is! int ||
        value['version'] != 1 ||
        !['prepared', 'committed'].contains(value['stage']) ||
        ![value['old'], value['next']].every(
          (value) =>
              value is String && RegExp(r'^[a-f0-9]{64}$').hasMatch(value),
        )) {
      throw const FormatException(
        'Kế hoạch phục hồi extension bị hỏng; giữ file để phục hồi.',
      );
    }
    ExtensionBackup.fromJson(value['extensions']);
    return value;
  }

  Future<void> _write(Map<String, dynamic> value) async {
    final file = await _journal(), bytes = utf8.encode(jsonEncode(value));
    if (bytes.length > LibrarySnapshot.maxBytes) {
      throw const FormatException('Kế hoạch phục hồi extension vượt 128 MiB.');
    }
    final folder = await file.parent.createTemp('.pending-');
    try {
      final pending = File('${folder.path}/plan');
      await pending.writeAsBytes(bytes, flush: true);
      await _journal();
      await pending.rename(file.path);
    } finally {
      if (await folder.exists()) await folder.delete(recursive: true);
    }
  }

  void _checkEngines(ExtensionBackup value) {
    if (value.packages.any((package) => !engines.contains(package.engine))) {
      throw UnsupportedError(
        'Máy này chưa có engine phục hồi các extension trong file. Thư viện chưa bị thay.',
      );
    }
  }

  Future<void> _replay(Map<String, dynamic> journal) async {
    final backup = ExtensionBackup.fromJson(journal['extensions']);
    _checkEngines(backup);
    try {
      await runtime.restoreExtensionBackup(backup);
    } catch (_) {
      // Original bytes remain durable. The next startup/backup attempt retries;
      // never report that a committed library was rolled back when it was not.
      throw StateError(
        'Thư viện đã được khôi phục nhưng một extension chưa cài xong. Gói gốc được giữ trên máy; mở lại app hoặc thử khôi phục để tiếp tục.',
      );
    }
    await (await _journal()).delete();
  }

  @override
  Future<void> recoverPending() => _exclusive(() async {
    final journal = await _read();
    if (journal == null) return;
    if (journal['stage'] == 'prepared') {
      final fingerprint = (await repository.snapshot()).fingerprint;
      if (fingerprint == journal['old'] && fingerprint != journal['next']) {
        await (await _journal()).delete();
        return;
      }
      if (journal['old'] == journal['next']) {
        throw StateError(
          'Lượt phục hồi extension bị gián đoạn ở bước xác nhận. Không thể xác minh commit chỉ từ thư viện không đổi; giữ kế hoạch để phục hồi có xác nhận.',
        );
      }
      if (fingerprint != journal['next']) {
        throw StateError(
          'Thư viện đã thay đổi khi phục hồi extension bị gián đoạn. Kế hoạch được giữ; cần khôi phục lại từ file gốc.',
        );
      }
      journal['stage'] = 'committed';
      await _write(journal);
    }
    await _replay(journal);
  });
  @override
  Future<ExtensionBackup?> capture() async {
    return runtime.captureExtensionBackup();
  }

  @override
  Future<void> prepare(
    ExtensionBackup incoming, {
    required String oldLibraryFingerprint,
    required String newLibraryFingerprint,
  }) => _exclusive(() async {
    if (![
      oldLibraryFingerprint,
      newLibraryFingerprint,
    ].every((value) => RegExp(r'^[a-f0-9]{64}$').hasMatch(value))) {
      throw const FormatException('Dấu kiểm thư viện extension không hợp lệ.');
    }
    _checkEngines(incoming);
    await runtime.validateExtensionBackup(incoming);
    if (await _read() != null) {
      throw StateError('Còn kế hoạch phục hồi extension chưa hoàn tất.');
    }
    await _write({
      'version': 1,
      'stage': 'prepared',
      'old': oldLibraryFingerprint,
      'next': newLibraryFingerprint,
      'extensions': incoming.toJson(),
    });
  });
  @override
  Future<void> complete() => _exclusive(() async {
    final journal = await _read();
    if (journal == null) return;
    if (journal['stage'] == 'prepared' &&
        (await repository.snapshot()).fingerprint != journal['next']) {
      throw StateError(
        'Thư viện hiện tại không khớp kế hoạch extension; không tự cài gói từ lượt phục hồi cũ.',
      );
    }
    journal['stage'] = 'committed';
    await _write(journal);
    await _replay(journal);
  });
  @override
  Future<void> discardPrepared() => _exclusive(() async {
    final journal = await _read();
    if (journal != null && journal['stage'] == 'prepared') {
      await (await _journal()).delete();
    }
  });
}
