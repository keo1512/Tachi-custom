import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tachi_books/core/diagnostics/diagnostic_log.dart';
import 'package:tachi_books/features/downloads/presentation/download_queue_controller.dart';
import 'package:tachi_books/features/library/application/automatic_backup_controller.dart';
import 'package:tachi_books/features/library/application/automatic_backup_status.dart';
import 'package:tachi_books/features/library/application/backup_service_provider.dart';
import 'package:tachi_books/features/library/data/automatic_backup_store.dart';
import 'package:tachi_books/features/library/data/backup_service.dart';
import 'package:tachi_books/features/library/data/library_repository.dart';
import 'package:tachi_books/features/library/presentation/library_view_model.dart';
import 'package:tachi_books/features/privacy/application/app_lock_controller.dart';
import 'package:tachi_books/features/settings/settings_controller.dart';
import 'package:tachi_books/features/sources/domain/catalogue.dart';
import 'package:tachi_books/features/tasks/application/task_lifecycle.dart';
import 'package:tachi_books/features/tasks/data/task_platform.dart';

import 'task_lifecycle_test.dart' as fixture;

class MaintenancePlatform extends fixture.FakeUpdateBackgroundTasks
    implements BackgroundMaintenancePlatform, ScheduledDownloadTaskPlatform {
  bool resumeDownloads = true;
  @override
  bool scheduledDownloadsRequested(int token) => resumeDownloads;
  final backups = <({bool requested, int earliest})>[];
  @override
  Future<void> updateBackgroundWorkSnapshot({
    required int pending,
    required int failed,
    required bool notifyOnPause,
    required bool resumeRequested,
    required bool updatesRequested,
    required int updateEarliestMillis,
    required int updateRemaining,
    required int updateFailed,
    required bool notifyUpdatePause,
    bool? backupsRequested,
    int? backupEarliestMillis,
  }) async {
    backups.add((
      requested: backupsRequested == true,
      earliest: backupEarliestMillis ?? 0,
    ));
    await super.updateBackgroundWorkSnapshot(
      pending: pending,
      failed: failed,
      notifyOnPause: notifyOnPause,
      resumeRequested: resumeRequested,
      updatesRequested: updatesRequested,
      updateEarliestMillis: updateEarliestMillis,
      updateRemaining: updateRemaining,
      updateFailed: updateFailed,
      notifyUpdatePause: notifyUpdatePause,
    );
  }
}

Future<void> waitUntil(bool Function() ready) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!ready() && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(
    ready(),
    isTrue,
    reason: 'Bounded asynchronous file work did not finish',
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'scheduled maintenance leaves manually paused downloads untouched',
    () async {
      SharedPreferences.setMockInitialValues({
        'libraryUpdatePolicyV1': jsonEncode({'hours': 1, 'checkAll': true}),
      });
      final preferences = await SharedPreferences.getInstance();
      final repository = MemoryLibraryRepository();
      await repository.save(fixture.book());
      final platform = MaintenancePlatform()..resumeDownloads = false;
      var downloads = 0;
      final source = fixture.UpdateSource(
        () async => const [
          CatalogueChapter(ref: 'a', title: 'A', index: 0),
          CatalogueChapter(ref: 'b', title: 'B', index: 1),
        ],
      );
      final container = ProviderContainer(
        overrides: [
          preferencesProvider.overrideWithValue(preferences),
          libraryRepositoryProvider.overrideWithValue(repository),
          sourceRepositoryProvider.overrideWithValue(source),
          taskPlatformProvider.overrideWithValue(platform),
          applicationStartsInBackgroundProvider.overrideWithValue(true),
          appLockProvider.overrideWith(fixture.ReadyAppLock.new),
          guardedDownloadJobExecutorProvider.overrideWithValue((_, _, _) async {
            downloads++;
          }),
        ],
      );
      addTearDown(container.dispose);
      addTearDown(platform.dispose);
      final lifetime = retainApplicationTasks(container);
      addTearDown(lifetime.close);
      await container.read(downloadQueueProvider.notifier).enqueue('b', ['a']);
      platform.scheduled.add(20);
      await fixture.until(() => platform.finished.isNotEmpty);
      expect(source.calls, 1);
      expect(downloads, 0);
      expect(container.read(downloadQueueProvider).running, isFalse);
      expect(container.read(downloadQueueProvider).tasks.single.chapterId, 'a');
      expect(platform.finished, [(20, true)]);
    },
  );
  test(
    'headless failures reach the same safe diagnostic sink as foreground work',
    () async {
      SharedPreferences.setMockInitialValues({
        'libraryUpdatePolicyV1': jsonEncode({'hours': 1, 'checkAll': true}),
      });
      final preferences = await SharedPreferences.getInstance();
      final repository = MemoryLibraryRepository();
      await repository.save(fixture.book());
      final platform = MaintenancePlatform();
      final source = fixture.UpdateSource(() async {
        throw const ApiException(
          'private fixture https://secret.example?token=secret',
        );
      });
      final container = ProviderContainer(
        overrides: [
          preferencesProvider.overrideWithValue(preferences),
          libraryRepositoryProvider.overrideWithValue(repository),
          sourceRepositoryProvider.overrideWithValue(source),
          taskPlatformProvider.overrideWithValue(platform),
          applicationStartsInBackgroundProvider.overrideWithValue(true),
          appLockProvider.overrideWith(fixture.ReadyAppLock.new),
        ],
      );
      addTearDown(container.dispose);
      addTearDown(platform.dispose);
      final root = WidgetsBinding.instance.rootElement;
      final lifetime = retainApplicationTasks(container);
      addTearDown(lifetime.close);
      platform.scheduled.add(19);
      await fixture.until(() => platform.finished.isNotEmpty);
      final log = container.read(diagnosticLogProvider);
      await fixture.until(
        () => log.read().any((entry) => entry.category == 'source'),
      );
      final output = utf8.decode(log.export());
      expect(output, isNot(contains('secret')));
      expect(output, isNot(contains('private fixture')));
      expect(WidgetsBinding.instance.rootElement, same(root));
      await container
          .read(settingsProvider.notifier)
          .update(incognitoMode: true);
      await fixture.until(() => container.read(settingsProvider).incognitoMode);
      final before = log.read().length;
      DiagnosticLogs.error('source', StateError('another secret'));
      await Future<void>.delayed(Duration.zero);
      expect(log.read(), hasLength(before));
    },
  );
  test(
    'headless queue completion closes its native window without a frame',
    () async {
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      final repository = MemoryLibraryRepository();
      await repository.save(fixture.book());
      final platform = MaintenancePlatform();
      final entered = Completer<void>(), release = Completer<void>();
      final container = ProviderContainer(
        overrides: [
          preferencesProvider.overrideWithValue(preferences),
          libraryRepositoryProvider.overrideWithValue(repository),
          taskPlatformProvider.overrideWithValue(platform),
          applicationStartsInBackgroundProvider.overrideWithValue(true),
          appLockProvider.overrideWith(fixture.ReadyAppLock.new),
          guardedDownloadJobExecutorProvider.overrideWithValue((_, _, _) async {
            entered.complete();
            await release.future;
          }),
        ],
      );
      addTearDown(container.dispose);
      addTearDown(platform.dispose);
      final root = WidgetsBinding.instance.rootElement;
      final lifetime = retainApplicationTasks(container);
      addTearDown(lifetime.close);
      await container.read(downloadQueueProvider.notifier).enqueue('b', ['a']);
      platform.scheduled.add(18);
      await entered.future;
      expect(platform.finished, isEmpty);
      release.complete();
      await fixture.until(() => platform.finished.isNotEmpty);
      expect(platform.finished, [(18, true)]);
      expect(container.read(downloadQueueProvider).tasks, isEmpty);
      expect(WidgetsBinding.instance.rootElement, same(root));
      expect(platform.begins, 0);
    },
  );
  test(
    'leaving incognito rearms future maintenance without starting work',
    () async {
      SharedPreferences.setMockInitialValues({
        'automaticBackupPolicyV1': const AutomaticBackupPolicy(hours: 1)
            .encode(),
        'libraryUpdatePolicyV1': jsonEncode({'hours': 3}),
      });
      final preferences = await SharedPreferences.getInstance();
      final platform = MaintenancePlatform();
      final container = ProviderContainer(
        overrides: [
          preferencesProvider.overrideWithValue(preferences),
          libraryRepositoryProvider.overrideWithValue(
            MemoryLibraryRepository(),
          ),
          taskPlatformProvider.overrideWithValue(platform),
          appLockProvider.overrideWith(fixture.ReadyAppLock.new),
        ],
      );
      addTearDown(container.dispose);
      addTearDown(platform.dispose);
      final lifetime = retainApplicationTasks(container);
      addTearDown(lifetime.close);
      final owner = container.read(taskCoordinatorProvider);
      owner.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await owner.pending;
      expect(platform.backups.last.requested, isTrue);
      expect(platform.updates.last.requested, isTrue);
      await container
          .read(settingsProvider.notifier)
          .update(incognitoMode: true);
      await fixture.until(() => !platform.backups.last.requested);
      await owner.pending;
      expect(platform.backups.last.requested, isFalse);
      expect(platform.updates.last.requested, isFalse);
      await container
          .read(settingsProvider.notifier)
          .update(incognitoMode: false);
      await fixture.until(
        () => !container.read(settingsProvider).incognitoMode,
      );
      await Future<void>.delayed(Duration.zero);
      await owner.pending;
      expect(platform.backups.last.requested, isTrue);
      expect(platform.updates.last.requested, isTrue);
      expect(platform.begins, 0);
      expect(platform.finished, isEmpty);
      expect(preferences.getInt('lastAutomaticBackup'), isNull);
      expect(preferences.getInt('libraryLastAutomaticUpdate'), isNull);
    },
  );
  testWidgets(
    'attaching foreground UI adopts the scheduled owner without a second subscription or source call',
    (tester) async {
      SharedPreferences.setMockInitialValues({
        'libraryUpdatePolicyV1': jsonEncode({'hours': 3, 'checkAll': true}),
      });
      final preferences = await SharedPreferences.getInstance();
      final repository = MemoryLibraryRepository();
      await repository.save(fixture.book().copyWith(sourceRef: '/book'));
      final response = Completer<List<CatalogueChapter>>();
      final source = fixture.UpdateSource(() => response.future);
      final platform = MaintenancePlatform();
      final container = ProviderContainer(
        overrides: [
          preferencesProvider.overrideWithValue(preferences),
          libraryRepositoryProvider.overrideWithValue(repository),
          taskPlatformProvider.overrideWithValue(platform),
          sourceRepositoryProvider.overrideWithValue(source),
          applicationStartsInBackgroundProvider.overrideWithValue(true),
          appLockProvider.overrideWith(fixture.ReadyAppLock.new),
        ],
      );
      addTearDown(container.dispose);
      addTearDown(platform.dispose);
      final owner = container.read(taskCoordinatorProvider);
      platform.scheduled.add(17);
      for (var i = 0; i < 30; i++) {
        await tester.pump();
      }
      expect(source.calls, 1);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const Directionality(
            textDirection: TextDirection.ltr,
            child: TaskLifecycle(child: SizedBox()),
          ),
        ),
      );
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(container.read(taskCoordinatorProvider), same(owner));
      expect(platform.ready, 1);
      response.complete(const [
        CatalogueChapter(ref: 'c', title: 'C', index: 0),
      ]);
      for (var i = 0; i < 30; i++) {
        await tester.pump();
      }
      expect(source.calls, 1);
      expect(platform.finished, [(17, false)]);
      expect((await repository.find('b'))!.chapters.single.id, 'c');
      await tester.pumpWidget(const SizedBox());
    },
  );
  for (final failure in [false, true]) {
    test(
      'headless scheduled owner runs backup and update without UI; backup failure=$failure',
      () async {
        final originalRoot = WidgetsBinding.instance.rootElement;
        final directory = await Directory.systemTemp.createTemp(
          'tachi-headless-',
        );
        addTearDown(() async {
          if (await directory.exists()) await directory.delete(recursive: true);
        });
        SharedPreferences.setMockInitialValues({
          'automaticBackupPolicyV1': const AutomaticBackupPolicy(hours: 1)
              .encode(),
          'libraryUpdatePolicyV1': jsonEncode({'hours': 1, 'checkAll': true}),
        });
        final preferences = await SharedPreferences.getInstance();
        final repository = MemoryLibraryRepository();
        await repository.save(fixture.book().copyWith(sourceRef: '/book'));
        final platform = MaintenancePlatform();
        final source = fixture.UpdateSource(
          () async => const [
            CatalogueChapter(ref: 'a', title: 'A', index: 0),
            CatalogueChapter(ref: 'b', title: 'B', index: 1),
            CatalogueChapter(ref: 'c', title: 'C', index: 2),
          ],
        );
        final backup = BackupService(repository);
        final destination = failure
            ? Directory('${directory.path}/collision')
            : directory;
        if (failure) {
          await File(destination.path).writeAsString('keep original');
        }
        final store = AutomaticBackupStore(destination, backup);
        final container = ProviderContainer(
          overrides: [
            preferencesProvider.overrideWithValue(preferences),
            libraryRepositoryProvider.overrideWithValue(repository),
            sourceRepositoryProvider.overrideWithValue(source),
            taskPlatformProvider.overrideWithValue(platform),
            applicationStartsInBackgroundProvider.overrideWithValue(true),
            appLockProvider.overrideWith(fixture.ReadyAppLock.new),
            backupServiceProvider.overrideWithValue(backup),
            automaticBackupStoreProvider.overrideWith((_) async => store),
          ],
        );
        addTearDown(container.dispose);
        addTearDown(platform.dispose);
        final lifetime = retainApplicationTasks(container);
        addTearDown(lifetime.close);
        final coordinator = container.read(taskCoordinatorProvider);
        expect(platform.ready, 1);
        platform.scheduled.add(71);
        await waitUntil(() => platform.finished.isNotEmpty);
        expect(source.calls, 1);
        expect((await repository.find('b'))!.chapters, hasLength(3));
        expect(preferences.getInt('libraryLastAutomaticUpdate'), isNotNull);
        expect(platform.begins, 0);
        expect(platform.finished, [(71, !failure)]);
        expect(WidgetsBinding.instance.rootElement, same(originalRoot));
        if (!failure) {
          expect(await store.list(), hasLength(1));
          expect(preferences.getInt('lastAutomaticBackup'), isNotNull);
          expect(platform.backups.last.requested, isTrue);
          expect(
            platform.backups.last.earliest,
            greaterThan(DateTime.now().millisecondsSinceEpoch),
          );
          platform.scheduled.add(72);
          await waitUntil(() => platform.finished.length == 2);
          expect(await store.list(), hasLength(1));
          expect(source.calls, 1);
        } else {
          expect(preferences.getInt('lastAutomaticBackup'), isNull);
          expect(await File(destination.path).readAsString(), 'keep original');
        }
        coordinator.didChangeAppLifecycleState(AppLifecycleState.resumed);
        expect(container.read(taskCoordinatorProvider), same(coordinator));
      },
    );
  }

  test('expiry then foreground resume cannot publish an old backup or prune prior files', () async {
    final directory = await Directory.systemTemp.createTemp(
      'tachi-headless-expiry-',
    );
    addTearDown(() async {
      if (await directory.exists()) await directory.delete(recursive: true);
    });
    final repository = MemoryLibraryRepository();
    await repository.save(fixture.book());
    final originalStore = AutomaticBackupStore(
      directory,
      BackupService(repository),
    );
    final previous = await originalStore.create(DateTime(2026, 1, 1));
    SharedPreferences.setMockInitialValues({
      'automaticBackupPolicyV1': const AutomaticBackupPolicy(
        hours: 1,
        keep: 1,
      ).encode(),
    });
    final preferences = await SharedPreferences.getInstance();
    final entered = Completer<void>(), release = Completer<void>();
    final backup = BackupService(
      repository,
      beforeExport: () async {
        entered.complete();
        await release.future;
      },
    );
    final platform = MaintenancePlatform();
    final store = AutomaticBackupStore(directory, backup);
    final container = ProviderContainer(
      overrides: [
        preferencesProvider.overrideWithValue(preferences),
        libraryRepositoryProvider.overrideWithValue(repository),
        taskPlatformProvider.overrideWithValue(platform),
        applicationStartsInBackgroundProvider.overrideWithValue(true),
        appLockProvider.overrideWith(fixture.ReadyAppLock.new),
        backupServiceProvider.overrideWithValue(backup),
        automaticBackupStoreProvider.overrideWith((_) async => store),
      ],
    );
    addTearDown(container.dispose);
    addTearDown(platform.dispose);
    final lifetime = retainApplicationTasks(container);
    addTearDown(lifetime.close);
    final coordinator = container.read(taskCoordinatorProvider);
    platform.scheduled.add(42);
    await entered.future;
    platform.expired.add(null);
    await waitUntil(() => platform.finished.isNotEmpty);
    coordinator.didChangeAppLifecycleState(AppLifecycleState.resumed);
    release.complete();
    await waitUntil(
      () =>
          container.read(automaticBackupStatusProvider).stage ==
          AutomaticBackupRunStage.interrupted,
    );
    expect(platform.finished, [(42, false)]);
    expect((await originalStore.list()).map((entry) => entry.name), [
      previous.name,
    ]);
    expect(preferences.getInt('lastAutomaticBackup'), isNull);
    expect(
      (await directory
          .list()
          .where((entry) => entry.path.endsWith('.pending'))
          .toList()),
      isEmpty,
    );
  });
}
