import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tachi_books/features/library/application/automatic_backup_controller.dart';
import 'package:tachi_books/features/library/application/automatic_backup_status.dart';
import 'package:tachi_books/features/library/application/backup_service_provider.dart';
import 'package:tachi_books/features/library/application/extension_recovery_controller.dart';
import 'package:tachi_books/features/library/data/automatic_backup_store.dart';
import 'package:tachi_books/features/library/data/backup_service.dart';
import 'package:tachi_books/features/library/data/library_repository.dart';
import 'package:tachi_books/features/library/domain/library_book.dart';
import 'package:tachi_books/features/settings/settings_controller.dart';
import 'package:tachi_books/features/privacy/application/app_lock_controller.dart';

class _LockedBackup extends AppLockController {
  @override
  AppLockState build() => const AppLockState(initialized: true, locked: true);
  @override
  Future<void> initialize() async {}
  void unlockForTest() => state = state.copyWith(locked: false);
  void lockForTest() => state = state.copyWith(locked: true);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late MemoryLibraryRepository repository;
  late AutomaticBackupStore store;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('tachi-auto-backup-');
    repository = MemoryLibraryRepository();
    await repository.save(
      LibraryBook(
        id: 'b',
        title: 'Offline',
        chapters: const [
          BookChapter(id: 'c', title: 'C', index: 0, downloaded: true),
        ],
      ),
    );
    await repository.saveChapter(
      'b',
      0,
      ReaderContent(
        kind: 'novel',
        html: '<p>Full bytes on another device.</p>',
      ),
    );
    store = AutomaticBackupStore(
      Directory('${directory.path}/backups'),
      BackupService(repository),
    );
  });
  tearDown(() async {
    if (await directory.exists()) await directory.delete(recursive: true);
  });
  test('flushed backup restores content in a different library; retention touches only owned names', () async {
    await store.directory.create();
    final other = File('${store.directory.path}/other.json');
    await other.writeAsString('keep');
    for (var i = 0; i < 5; i++) {
      await store.create(DateTime(2026, 10, 10, i), keep: 3);
    }
    final backups = await store.list();
    expect(backups.length, 3);
    expect(await other.readAsString(), 'keep');
    expect(
      (await store.directory
          .list()
          .where((e) => e.path.endsWith('.pending'))
          .toList()),
      isEmpty,
    );
    final restored = MemoryLibraryRepository();
    await BackupService(restored).merge(await store.read(backups.first.name));
    expect(
      (await restored.readChapter('b', 0))!.html,
      '<p>Full bytes on another device.</p>',
    );
    expect((await restored.find('b'))!.chapters.single.downloaded, true);
    await store.delete(backups.first.name);
    expect((await store.list()).length, 2);
  });
  for (final interruptAfterPublish in [false, true]) {
    test(
      'interruption protects previous backups before rename/retention; published=$interruptAfterPublish',
      () async {
        final previous = await store.create(DateTime(2026, 1, 1));
        await expectLater(
          store.create(
            DateTime(2026, 1, 2),
            keep: 1,
            beforePublish: () {
              final files = store.directory.listSync().whereType<File>().map(
                (file) => file.uri.pathSegments.last,
              );
              final reached = interruptAfterPublish
                  ? files.any(
                      (name) => name.endsWith('.json') && name != previous.name,
                    )
                  : files.any((name) => name.endsWith('.pending'));
              if (reached) throw AutomaticBackupInterrupted();
            },
          ),
          throwsStateError,
        );
        final remaining = await store.list();
        expect(remaining.map((entry) => entry.name), contains(previous.name));
        expect(remaining, hasLength(interruptAfterPublish ? 2 : 1));
        expect(await store.read(previous.name), isNotEmpty);
        expect(
          store.directory.listSync().any(
            (file) => file.path.endsWith('.pending'),
          ),
          isFalse,
        );
      },
    );
  }
  test(
    'name traversal and corrupt backup are refused without library changes',
    () async {
      final item = await store.create(DateTime.now());
      await expectLater(store.read('../outside.json'), throwsFormatException);
      await expectLater(store.delete('../outside.json'), throwsFormatException);
      await File('${store.directory.path}/${item.name}')
          .writeAsBytes(Uint8List.fromList([123]));
      await expectLater(store.read(item.name), throwsFormatException);
      expect((await repository.find('b'))!.title, 'Offline');
    },
  );
  test('disabled automatic backup stays off; concurrent check dedups and honors interval after restart', () async {
    SharedPreferences.setMockInitialValues({});
    final p = await SharedPreferences.getInstance();
    ProviderContainer open() => ProviderContainer(
      overrides: [
        preferencesProvider.overrideWithValue(p),
        automaticBackupStoreProvider.overrideWith((ref) async => store),
        backupServiceProvider.overrideWithValue(store.backup),
      ],
    );
    final container = open();
    addTearDown(container.dispose);
    final scheduler = container.read(automaticBackupSchedulerProvider);
    final now = DateTime(2026, 10, 10);
    expect(await scheduler.check(now), isNull);
    expect(await store.list(), isEmpty);
    await container
        .read(automaticBackupPolicyProvider.notifier)
        .update(hours: 6, keep: 5);
    await Future.wait([scheduler.check(now), scheduler.check(now)]);
    expect((await store.list()).length, 1);
    final status = container.read(automaticBackupStatusProvider);
    expect(status.stage, AutomaticBackupRunStage.succeeded);
    expect(status.fileName, (await store.list()).single.name);
    expect(status.bytes, greaterThan(0));
    final restarted = open();
    addTearDown(restarted.dispose);
    expect(
      await restarted
          .read(automaticBackupSchedulerProvider)
          .check(now.add(const Duration(hours: 5))),
      isNull,
    );
    await restarted
        .read(automaticBackupSchedulerProvider)
        .check(now.add(const Duration(hours: 6)));
    expect((await store.list()).length, 2);
  });
  test('failed destination does not delete old backups or record successful timestamp', () async {
    final item = await store.create(DateTime.now());
    final collision = File('${directory.path}/collision');
    await collision.writeAsString('untouched');
    final broken = AutomaticBackupStore(
      Directory(collision.path),
      BackupService(repository),
    );
    SharedPreferences.setMockInitialValues({
      'automaticBackupPolicyV1': const AutomaticBackupPolicy(hours: 6).encode(),
    });
    final p = await SharedPreferences.getInstance();
    final c = ProviderContainer(
      overrides: [
        preferencesProvider.overrideWithValue(p),
        automaticBackupStoreProvider.overrideWith((ref) async => broken),
        backupServiceProvider.overrideWithValue(broken.backup),
      ],
    );
    addTearDown(c.dispose);
    await expectLater(
      c.read(automaticBackupSchedulerProvider).check(DateTime.now()),
      throwsA(isA<FileSystemException>()),
    );
    expect(p.containsKey('lastAutomaticBackup'), false);
    final status = c.read(automaticBackupStatusProvider);
    expect(status.stage, AutomaticBackupRunStage.failed);
    expect(status.failure, contains('Kiểm tra dung lượng'));
    expect(status.encode(), isNot(contains(collision.path)));
    final restarted = ProviderContainer(
      overrides: [preferencesProvider.overrideWithValue(p)],
    );
    addTearDown(restarted.dispose);
    expect(
      restarted.read(automaticBackupStatusProvider).failure,
      status.failure,
    );
    expect((await store.list()).single.name, item.name);
    expect(await collision.readAsString(), 'untouched');
  });
  test('previous running record is shown interrupted after restart', () {
    final raw = AutomaticBackupRunStatus(
      stage: AutomaticBackupRunStage.running,
      startedAt: DateTime(2026, 10, 12),
    ).encode();
    expect(
      AutomaticBackupRunStatus.decode(raw, afterRestart: true).stage,
      AutomaticBackupRunStage.interrupted,
    );
    expect(
      AutomaticBackupRunStatus.decode(raw).stage,
      AutomaticBackupRunStage.running,
    );
  });
  test(
    'automatic capture cannot initialize extensions while the app is locked',
    () async {
      SharedPreferences.setMockInitialValues({
        'automaticBackupPolicyV1': const AutomaticBackupPolicy(hours: 6)
            .encode(),
      });
      final preferences = await SharedPreferences.getInstance();
      final container = ProviderContainer(
        overrides: [
          preferencesProvider.overrideWithValue(preferences),
          appLockProvider.overrideWith(_LockedBackup.new),
          automaticBackupStoreProvider.overrideWith((ref) async => store),
          backupServiceProvider.overrideWithValue(store.backup),
        ],
      );
      addTearDown(container.dispose);
      final scheduler = container.read(automaticBackupSchedulerProvider);
      final now = DateTime(2026, 10, 12);
      expect(await scheduler.check(now), isNull);
      expect(await scheduler.check(now, force: true), isNull);
      expect(await store.list(), isEmpty);
      expect(preferences.getInt('lastAutomaticBackup'), isNull);
      (container.read(appLockProvider.notifier) as _LockedBackup)
          .unlockForTest();
      expect(await scheduler.check(now), isNotNull);
      expect((await store.list()).length, 1);
    },
  );
  test(
    'locking during destination lookup prevents capture and publication',
    () async {
      SharedPreferences.setMockInitialValues({
        'automaticBackupPolicyV1': const AutomaticBackupPolicy(hours: 6)
            .encode(),
      });
      final preferences = await SharedPreferences.getInstance();
      final reachedDestination = Completer<void>();
      final destination = Completer<AutomaticBackupStore>();
      final container = ProviderContainer(
        overrides: [
          preferencesProvider.overrideWithValue(preferences),
          appLockProvider.overrideWith(_LockedBackup.new),
          backupServiceProvider.overrideWithValue(store.backup),
          automaticBackupStoreProvider.overrideWith((ref) async {
            reachedDestination.complete();
            return destination.future;
          }),
        ],
      );
      addTearDown(container.dispose);
      final lock = container.read(appLockProvider.notifier) as _LockedBackup;
      lock.unlockForTest();
      final operation = container
          .read(automaticBackupSchedulerProvider)
          .check(DateTime(2026, 10, 12));
      await reachedDestination.future;
      lock.lockForTest();
      destination.complete(store);
      await expectLater(operation, throwsStateError);
      expect(await store.list(), isEmpty);
      expect(preferences.getInt('lastAutomaticBackup'), isNull);
      expect(
        container.read(automaticBackupStatusProvider).stage,
        AutomaticBackupRunStage.failed,
      );
    },
  );
  test(
    'a later restore failure blocks a queued automatic snapshot before capture',
    () async {
      SharedPreferences.setMockInitialValues({
        'automaticBackupPolicyV1': const AutomaticBackupPolicy(hours: 6)
            .encode(),
      });
      final preferences = await SharedPreferences.getInstance();
      final reachedDestination = Completer<void>();
      final destination = Completer<AutomaticBackupStore>();
      final container = ProviderContainer(
        overrides: [
          preferencesProvider.overrideWithValue(preferences),
          appLockProvider.overrideWith(_LockedBackup.new),
          backupServiceProvider.overrideWithValue(store.backup),
          automaticBackupStoreProvider.overrideWith((ref) async {
            reachedDestination.complete();
            return destination.future;
          }),
        ],
      );
      addTearDown(container.dispose);
      (container.read(appLockProvider.notifier) as _LockedBackup)
          .unlockForTest();
      final operation = container
          .read(automaticBackupSchedulerProvider)
          .check(DateTime(2026, 10, 12));
      await reachedDestination.future;
      container
          .read(extensionRecoveryProvider.notifier)
          .reportIncomplete(StateError('Chưa cài xong.'), StackTrace.current);
      destination.complete(store);
      await expectLater(operation, throwsStateError);
      expect(await store.list(), isEmpty);
      expect(preferences.getInt('lastAutomaticBackup'), isNull);
    },
  );
}
