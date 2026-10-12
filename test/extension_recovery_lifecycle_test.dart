import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tachi_books/features/library/application/backup_service_provider.dart';
import 'package:tachi_books/features/library/application/extension_recovery_controller.dart';
import 'package:tachi_books/features/library/data/backup_service.dart';
import 'package:tachi_books/features/library/data/library_repository.dart';
import 'package:tachi_books/features/privacy/application/app_lock_controller.dart';

class _Lock extends AppLockController {
  @override
  AppLockState build() => const AppLockState(initialized: true, locked: true);
  @override
  Future<void> initialize() async {}
  void setLocked(bool value) => state = state.copyWith(locked: value);
}

class _Recovery extends BackupService {
  _Recovery() : super(MemoryLibraryRepository());
  int startup = 0, retries = 0;
  bool fails = false;
  @override
  Future<void> recoverPendingExtensions() async {
    startup++;
    if (fails) throw StateError('Chưa cài xong extension.');
  }

  @override
  Future<void> retryPendingExtensions() async {
    retries++;
  }
}

void main() {
  test('a later committed restore failure blocks a completed startup until explicit retry', () async {
    final recovery = _Recovery();
    final container = ProviderContainer(
      overrides: [
        appLockProvider.overrideWith(_Lock.new),
        backupServiceProvider.overrideWithValue(recovery),
      ],
    );
    addTearDown(container.dispose);
    final subscription = container.listen(extensionRecoveryProvider, (_, _) {});
    addTearDown(subscription.close);
    await container.read(extensionRecoveryProvider.future);
    final lock = container.read(appLockProvider.notifier) as _Lock;
    lock.setLocked(false);
    await container.read(extensionRecoveryProvider.future);
    final controller = container.read(extensionRecoveryProvider.notifier);
    final error = StateError('Extension chưa cài xong sau commit.');
    controller.reportIncomplete(error, StackTrace.current);
    expect(container.read(extensionRecoveryProvider).hasError, true);
    await expectLater(
      container.read(extensionRecoveryProvider.future),
      throwsStateError,
    );
    lock.setLocked(true);
    await container.read(extensionRecoveryProvider.future);
    lock.setLocked(false);
    await expectLater(
      container.read(extensionRecoveryProvider.future),
      throwsStateError,
    );
    expect(recovery.startup, 1);
    await controller.retry();
    expect(recovery.retries, 1);
    expect(container.read(extensionRecoveryProvider).hasError, false);
  });
  test(
    'startup recovery waits for unlock and does not rerun on later unlocks',
    () async {
      final recovery = _Recovery();
      final container = ProviderContainer(
        overrides: [
          appLockProvider.overrideWith(_Lock.new),
          backupServiceProvider.overrideWithValue(recovery),
        ],
      );
      addTearDown(container.dispose);
      final subscription = container.listen(
        extensionRecoveryProvider,
        (_, _) {},
      );
      addTearDown(subscription.close);
      await container.read(extensionRecoveryProvider.future);
      expect(recovery.startup, 0);
      final lock = container.read(appLockProvider.notifier) as _Lock;
      lock.setLocked(false);
      await container.read(extensionRecoveryProvider.future);
      expect(recovery.startup, 1);
      lock.setLocked(true);
      await container.read(extensionRecoveryProvider.future);
      lock.setLocked(false);
      await container.read(extensionRecoveryProvider.future);
      expect(recovery.startup, 1);
    },
  );
  test(
    'failed recovery remains explicit, retry is blocked while locked',
    () async {
      final recovery = _Recovery()..fails = true;
      final container = ProviderContainer(
        overrides: [
          appLockProvider.overrideWith(_Lock.new),
          backupServiceProvider.overrideWithValue(recovery),
        ],
      );
      addTearDown(container.dispose);
      final subscription = container.listen(
        extensionRecoveryProvider,
        (_, _) {},
      );
      addTearDown(subscription.close);
      await container.read(extensionRecoveryProvider.future);
      final lock = container.read(appLockProvider.notifier) as _Lock;
      lock.setLocked(false);
      await expectLater(
        container.read(extensionRecoveryProvider.future),
        throwsStateError,
      );
      lock.setLocked(true);
      await container.read(extensionRecoveryProvider.future);
      await container.read(extensionRecoveryProvider.notifier).retry();
      expect(recovery.retries, 0);
      lock.setLocked(false);
      await expectLater(
        container.read(extensionRecoveryProvider.future),
        throwsStateError,
      );
      expect(recovery.startup, 1);
      await container.read(extensionRecoveryProvider.notifier).retry();
      expect(recovery.retries, 1);
      expect(container.read(extensionRecoveryProvider).hasError, false);
      lock.setLocked(true);
      await container.read(extensionRecoveryProvider.future);
      lock.setLocked(false);
      await container.read(extensionRecoveryProvider.future);
      expect(recovery.startup, 1);
      expect(recovery.retries, 1);
    },
  );
}
