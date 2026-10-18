import 'dart:typed_data';

import 'backup_compatibility/backup_reader.dart';
import 'coordinated_preferences.dart';
import 'backup_validation.dart';
import 'library_repository.dart';
import 'library_snapshot.dart';
import 'backup_restore_progress.dart';
import 'extension_backup_store.dart';

class BackupService {
  BackupService(
    this.repository, {
    this.configuration,
    this.onConfigurationRestored,
    this.onExtensionRestoreIncomplete,
    this.beforeExport,
    this.exportGuard,
    this.extensions,
  });
  final LibraryRepository repository;
  final AppConfigurationStore? configuration;
  final void Function()? onConfigurationRestored;
  final void Function(Object, StackTrace)? onExtensionRestoreIncomplete;
  final Future<void> Function()? beforeExport;
  final void Function()? exportGuard;
  final ExtensionBackupStore? extensions;
  static const maxBackupBytes = LibrarySnapshot.maxBytes;

  Future<T> _exclusive<T>(Future<T> Function() action) {
    Future<T> withExtensions() => extensions?.exclusive(action) ?? action();
    return configuration?.exclusive(withExtensions) ?? withExtensions();
  }

  Future<LibrarySnapshot> _current() async {
    final extensionImage = await extensions?.capture();
    final configurationImage = configuration?.capture();
    final library = await repository.snapshot();
    return LibrarySnapshot(
      library.entries,
      configuration: configurationImage,
      extensions: extensionImage,
    );
  }

  Future<void> recoverPendingExtensions() async => extensions?.recoverPending();
  Future<void> retryPendingExtensions() async => extensions?.complete();

  Future<Uint8List> export({void Function()? beforeCapture}) async {
    await beforeExport?.call();
    return _exclusive(() async {
      exportGuard?.call();
      beforeCapture?.call();
      final bytes = (await _current()).encode();
      exportGuard?.call();
      beforeCapture?.call();
      // Never emit a backup that this version cannot validate and restore.
      _validate(bytes);
      return bytes;
    });
  }

  void validate(Uint8List bytes) => _validate(bytes);

  String fingerprint(Uint8List bytes) => _validate(bytes).fingerprint;

  Future<void> replace(
    Uint8List bytes, {
    required String expectedFingerprint,
  }) async {
    final incoming = _validate(bytes);
    final restored = await _exclusive(() async {
      final current = await _current();
      _checkExpected(current, expectedFingerprint);
      return _commit(current, incoming, restoreConfiguration: true);
    });
    if (restored) onConfigurationRestored?.call();
  }

  Future<Uint8List?> exportRecovery() async {
    final bytes = await repository.recoverySnapshot();
    if (bytes != null) validate(bytes);
    return bytes;
  }

  Future<int> merge(Uint8List bytes) async {
    return mergePreview(await preview(bytes));
  }

  Future<BackupPreview> preview(Uint8List bytes) async {
    final converted = await readCompatibleBackup(bytes, repository);
    return _exclusive(() async {
      final current = await _current();
      final ids = current.entries.map((entry) => entry.book.id).toSet();
      return BackupPreview(
        format: converted.format,
        snapshot: converted.snapshot,
        warnings: List.unmodifiable([
          ...converted.warnings,
          if (converted.snapshot.configuration != null)
            '${converted.snapshot.configuration!.values.length} thiết lập ứng dụng có trong file. '
                'Bạn có thể chọn khôi phục kho extension, danh mục, giao diện, tùy chọn đọc và chính sách tự động. '
                'Tài khoản, cookie, khóa ứng dụng và hàng đợi tải không được nhập.',
          if (converted.snapshot.extensions != null)
            '${converted.snapshot.extensions!.packages.length} gói extension gốc có checksum và tùy chọn công khai trong file. '
                'Bật khôi phục thiết lập để cài lại trên engine của máy này; các gói đã cài khác được giữ. '
                'Nếu engine chưa chạy được gói, kế hoạch cài được lưu để tiếp tục; thư viện/media đã ghi không bị giả báo là chưa khôi phục.',
        ]),
        expectedFingerprint: current.fingerprint,
        additions: converted.snapshot.entries
            .where((entry) => !ids.contains(entry.book.id))
            .length,
      );
    });
  }

  Future<int> mergePreview(
    BackupPreview preview, {
    bool restoreConfiguration = false,
    void Function(BackupRestoreProgress)? onProgress,
    BackupRestoreCancellation? cancellation,
  }) async {
    void progress(BackupRestoreStage stage, {int done = 0, int total = 0}) {
      // A detached UI must not turn a successful atomic commit into a failure.
      try {
        onProgress?.call(
          BackupRestoreProgress(stage, completedBooks: done, totalBooks: total),
        );
      } catch (_) {}
    }

    progress(BackupRestoreStage.validating);
    cancellation?.check();
    await BackupValidator(repository)
        .validateForRestore(preview.snapshot, check: cancellation?.check);
    cancellation?.check();
    var restored = false;
    final count = await _exclusive(() async {
      progress(BackupRestoreStage.readingCurrent);
      cancellation?.check();
      final current = await _current();
      _checkExpected(current, preview.expectedFingerprint);
      cancellation?.check();
      final ids = current.entries.map((entry) => entry.book.id).toSet();
      final additions = preview.snapshot.entries
          .where((entry) => !ids.contains(entry.book.id))
          .toList();
      if (additions.isEmpty &&
          !(restoreConfiguration &&
              (preview.snapshot.configuration != null ||
                  preview.snapshot.extensions != null))) {
        return 0;
      }
      progress(BackupRestoreStage.preparing, total: additions.length);
      for (var index = 0; index < additions.length; index++) {
        cancellation?.check();
        // Every entry was validated above. Preparation remains cancellable and
        // keeps the progress UI responsive until the single atomic commit.
        progress(
          BackupRestoreStage.preparing,
          done: index + 1,
          total: additions.length,
        );
        await Future<void>.delayed(Duration.zero);
      }
      cancellation?.check();
      final combined = LibrarySnapshot(
        [...current.entries, ...additions],
        configuration: preview.snapshot.configuration,
        extensions: preview.snapshot.extensions,
      );
      combined.checkEncodedSize();
      cancellation?.check();
      progress(
        BackupRestoreStage.committing,
        done: additions.length,
        total: additions.length,
      );
      restored = await _commit(
        current,
        combined,
        restoreConfiguration: restoreConfiguration,
      );
      return additions.length;
    });
    if (restored) onConfigurationRestored?.call();
    progress(BackupRestoreStage.completed, done: count, total: count);
    return count;
  }

  void _checkExpected(LibrarySnapshot current, String expected) {
    if (current.fingerprint != expected) {
      throw StateError(
        'Thư viện hoặc thiết lập đã thay đổi sau khi xem trước. Hãy chọn lại bản sao lưu.',
      );
    }
  }

  Future<bool> _commit(
    LibrarySnapshot current,
    LibrarySnapshot incoming, {
    required bool restoreConfiguration,
  }) async {
    final oldLibrary = LibrarySnapshot(current.entries),
        nextLibrary = LibrarySnapshot(incoming.entries);
    final store = configuration;
    final importedConfiguration = restoreConfiguration
        ? incoming.configuration
        : null;
    final importedExtensions = restoreConfiguration
        ? incoming.extensions
        : null;
    if (importedExtensions != null &&
        importedExtensions.packages.isNotEmpty &&
        extensions == null) {
      throw UnsupportedError(
        'Máy này chưa có engine phục hồi extension. Hãy tắt khôi phục thiết lập để nhập riêng thư viện.',
      );
    }
    final pendingExtensions =
        importedExtensions != null && importedExtensions.packages.isNotEmpty;
    if (importedConfiguration != null && store == null) {
      throw UnsupportedError(
        'Cần bộ nhớ thiết lập đã khởi tạo để khôi phục cấu hình.',
      );
    }
    if (pendingExtensions) {
      await extensions!.prepare(
        importedExtensions,
        oldLibraryFingerprint: oldLibrary.fingerprint,
        newLibraryFingerprint: nextLibrary.fingerprint,
      );
    }
    var committed = false;
    Future<void> checkExtensions() async {
      if (extensions != null &&
          (await extensions!.capture())?.fingerprint !=
              current.extensions?.fingerprint) {
        throw StateError(
          'Extension đã thay đổi sau khi xem trước. Hãy chọn lại bản sao lưu.',
        );
      }
    }

    try {
      if (store == null) {
        if (pendingExtensions) {
          await repository.replaceSnapshotWithConfiguration(
            nextLibrary,
            expectedFingerprint: oldLibrary.fingerprint,
            recovery: current.encode(),
            beforeCommit: checkExtensions,
          );
        } else {
          await repository.replaceSnapshot(
            nextLibrary,
            expectedFingerprint: oldLibrary.fingerprint,
          );
        }
        committed = true;
        if (pendingExtensions) await extensions!.complete();
        return pendingExtensions;
      }
      final recovery = current.encode();
      if (importedConfiguration == null) {
        await repository.replaceSnapshotWithConfiguration(
          nextLibrary,
          expectedFingerprint: oldLibrary.fingerprint,
          recovery: recovery,
          beforeCommit: () async {
            await checkExtensions();
            if (store.capture().fingerprint !=
                current.configuration!.fingerprint) {
              throw StateError('Thiết lập đã thay đổi trong khi khôi phục.');
            }
          },
        );
        committed = true;
        if (pendingExtensions) await extensions!.complete();
        return pendingExtensions;
      }
      await store.preferences.restoreLocked(
        incoming: importedConfiguration,
        expectedFingerprint: current.configuration!.fingerprint,
        oldLibraryFingerprint: oldLibrary.fingerprint,
        newLibraryFingerprint: nextLibrary.fingerprint,
        commit: (beforeCommit) async {
          await repository.replaceSnapshotWithConfiguration(
            nextLibrary,
            expectedFingerprint: oldLibrary.fingerprint,
            recovery: recovery,
            beforeCommit: () async {
              await checkExtensions();
              await beforeCommit();
            },
          );
          // Configuration journal publication/cleanup can fail after the atomic
          // library commit. Its extension plan must remain durable in that case.
          committed = true;
        },
      );
      committed = true;
      if (pendingExtensions) await extensions!.complete();
      return true;
    } catch (error, stack) {
      // Only a plan whose library never committed can be discarded. A runtime
      // failure after commit leaves committed journal bytes for restart/retry.
      if (committed && pendingExtensions) {
        onExtensionRestoreIncomplete?.call(error, stack);
      }
      if (committed && importedConfiguration != null) {
        onConfigurationRestored?.call();
      }
      if (pendingExtensions && !committed) {
        await extensions!.discardPrepared();
      }
      rethrow;
    }
  }

  LibrarySnapshot _validate(Uint8List bytes) =>
      BackupValidator(repository).validateSnapshot(bytes);
}

class BackupPreview {
  const BackupPreview({
    required this.format,
    required this.snapshot,
    required this.warnings,
    required this.expectedFingerprint,
    required this.additions,
  });
  final String format, expectedFingerprint;
  final LibrarySnapshot snapshot;
  final List<String> warnings;
  final int additions;
  int get configurationCount => snapshot.configuration?.values.length ?? 0;
  bool get hasConfiguration =>
      snapshot.configuration != null || snapshot.extensions != null;
  int get books => snapshot.entries.length;
  int get cachedChapters => snapshot.entries.fold<int>(
    0,
    (total, entry) => total + entry.contents.length,
  );
}
