import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tachi_books/features/downloads/data/download_queue_repository.dart';
import 'package:tachi_books/features/downloads/presentation/download_queue_controller.dart';
import 'package:tachi_books/features/library/data/library_repository.dart';
import 'package:tachi_books/features/library/domain/library_book.dart';
import 'package:tachi_books/features/library/presentation/library_view_model.dart';
import 'package:tachi_books/features/library/application/library_update_scheduler.dart';
import 'package:tachi_books/features/library/application/library_update_report.dart';
import 'package:tachi_books/features/sources/data/source_repository.dart';
import 'package:tachi_books/features/sources/domain/catalogue.dart';
import 'package:tachi_books/features/privacy/application/app_lock_controller.dart';
import 'package:tachi_books/features/settings/settings_controller.dart';
import 'package:tachi_books/features/tasks/application/task_lifecycle.dart';
import 'package:tachi_books/features/tasks/application/task_notifications.dart';
import 'package:tachi_books/features/tasks/data/task_platform.dart';

class FakeTasks implements TaskPlatform, PausedTaskPlatform {
  final expired = StreamController<void>.broadcast(sync: true);
  bool allowed = true, granted = true, failNotify = false;
  int requests = 0, clears = 0, begins = 0, ends = 0;
  final summaries = <(String, int, int)>[];
  final stopped = <(int, int)>[];
  Completer<bool>? delayedLease;
  @override
  Stream<void> get backgroundExpired => expired.stream;
  @override
  Future<bool> requestNotificationPermission() async {
    requests++;
    return allowed;
  }

  @override
  Future<bool> notify(String kind, int completed, int failed) async {
    if (failNotify) throw StateError('Notification transport failed');
    summaries.add((kind, completed, failed));
    return true;
  }

  @override
  Future<bool> notifyPausedDownloads(int pending, int failed) async {
    if (failNotify) throw StateError('Notification transport failed');
    stopped.add((pending, failed));
    return true;
  }

  @override
  Future<void> clearNotifications() async {
    clears++;
  }

  @override
  Future<bool> beginBackground() async {
    begins++;
    return delayedLease?.future ?? granted;
  }

  @override
  Future<void> endBackground() async {
    ends++;
  }

  @override
  void dispose() {
    unawaited(expired.close());
  }
}

class FakeBackgroundTasks extends FakeTasks implements BackgroundTaskPlatform {
  final scheduled = StreamController<int>.broadcast(sync: true);
  final snapshots = <({int pending, int failed, bool notify, bool resume})>[];
  final finished = <(int, bool)>[];
  int ready = 0;
  @override
  Stream<int> get scheduledBackground => scheduled.stream;
  @override
  Future<void> backgroundReady() async {
    ready++;
  }

  @override
  Future<void> updateBackgroundSnapshot({
    required int pending,
    required int failed,
    required bool notifyOnPause,
    required bool resumeRequested,
  }) async {
    snapshots.add((
      pending: pending,
      failed: failed,
      notify: notifyOnPause,
      resume: resumeRequested,
    ));
  }

  @override
  Future<void> completeScheduledBackground(
    int token, {
    required bool success,
  }) async {
    finished.add((token, success));
  }

  @override
  Future<bool> beginBackground() async {
    expectSync(snapshots.last.pending, greaterThan(0));
    return super.beginBackground();
  }

  @override
  void dispose() {
    super.dispose();
    unawaited(scheduled.close());
  }
}

class ReadyAppLock extends AppLockController {
  ReadyAppLock({this.locked = false});
  final bool locked;
  @override
  AppLockState build() => AppLockState(initialized: true, locked: locked);
  @override
  Future<void> initialize() async {}
}

class FakeUpdateBackgroundTasks extends FakeBackgroundTasks
    implements BackgroundLibraryUpdatePlatform {
  final updates =
      <
        ({bool requested, int earliest, int remaining, int failed, bool notify})
      >[];
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
  }) async {
    snapshots.add((
      pending: pending,
      failed: failed,
      notify: notifyOnPause,
      resume: resumeRequested,
    ));
    updates.add((
      requested: updatesRequested,
      earliest: updateEarliestMillis,
      remaining: updateRemaining,
      failed: updateFailed,
      notify: notifyUpdatePause,
    ));
  }

  @override
  Future<bool> beginBackground() async {
    begins++;
    return delayedLease?.future ?? granted;
  }
}

class UpdateSource extends SourceRepository {
  UpdateSource(this.respond) : super(tachimangaUrl: '', vbookUrl: '');
  final Future<List<CatalogueChapter>> Function() respond;
  int calls = 0;
  @override
  Future<List<CatalogueChapter>> chapters(CatalogueBook book) {
    calls++;
    return respond();
  }
}

Future<void> until(bool Function() condition) async {
  for (var i = 0; i < 100; i++) {
    if (condition()) return;
    await Future<void>.delayed(Duration.zero);
  }
  fail('Task did not reach the expected state');
}

LibraryBook book() => LibraryBook(
  id: 'b',
  title: 'Private fixture title',
  engine: 'tachimanga',
  sourceId: '1',
  chapters: [
    BookChapter(id: 'a', title: 'a', index: 0),
    BookChapter(id: 'b', title: 'b', index: 1),
  ],
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('notifications default off; only explicit toggle asks; permission denial keeps off', () async {
    final prefs = await SharedPreferences.getInstance(), platform = FakeTasks();
    final container = ProviderContainer(
      overrides: [
        preferencesProvider.overrideWithValue(prefs),
        taskPlatformProvider.overrideWithValue(platform),
      ],
    );
    addTearDown(container.dispose);
    addTearDown(platform.dispose);
    final notices = container.read(taskNotificationsProvider.notifier);
    expect(container.read(taskNotificationsProvider), false);
    await notices.summary('downloads', 3, 0);
    await notices.pausedDownloads(3, 0);
    expect(platform.requests, 0);
    expect(platform.summaries, isEmpty);
    expect(platform.stopped, isEmpty);
    platform.allowed = false;
    await expectLater(notices.setEnabled(true), throwsStateError);
    expect(container.read(taskNotificationsProvider), false);
    expect(prefs.getBool(TaskNotifications.preferenceKey), isNull);
    platform.allowed = true;
    await notices.setEnabled(true);
    await notices.summary('updates', 4, 1);
    await notices.pausedDownloads(3, 1);
    expect(platform.stopped, [(3, 1)]);
    expect(platform.summaries, [('updates', 4, 1)]);
    await notices.setEnabled(false);
    expect(platform.clears, 1);
    expect(platform.requests, 2);
  });

  test('restored opt-in never requests permission; private sessions and intervening incognito suppress summaries', () async {
    SharedPreferences.setMockInitialValues({
      TaskNotifications.preferenceKey: true,
    });
    final prefs = await SharedPreferences.getInstance(), platform = FakeTasks();
    final container = ProviderContainer(
      overrides: [
        preferencesProvider.overrideWithValue(prefs),
        taskPlatformProvider.overrideWithValue(platform),
      ],
    );
    addTearDown(container.dispose);
    addTearDown(platform.dispose);
    final notices = container.read(taskNotificationsProvider.notifier);
    await notices.summary('downloads', 4, 0, privateSession: true);
    await notices.pausedDownloads(4, 0, privateSession: true);
    final before = notices.privacyGeneration;
    await container.read(settingsProvider.notifier).update(incognitoMode: true);
    await notices.summary('updates', 5, 0);
    await notices.pausedDownloads(4, 0);
    await container
        .read(settingsProvider.notifier)
        .update(incognitoMode: false);
    await notices.summary('updates', 5, 0, expectedPrivacyGeneration: before);
    await notices.pausedDownloads(4, 0, expectedPrivacyGeneration: before);
    expect(platform.summaries, isEmpty);
    expect(platform.stopped, isEmpty);
    expect(platform.requests, 0);
    platform.failNotify = true;
    await notices.summary('updates', 5, 0); // Cannot invalidate completed work.
  });

  test('queue sends one terminal numeric summary and suppresses a session that became private', () async {
    SharedPreferences.setMockInitialValues({
      TaskNotifications.preferenceKey: true,
    });
    final prefs = await SharedPreferences.getInstance(), platform = FakeTasks();
    final repo = MemoryLibraryRepository();
    await repo.save(book());
    Completer<void>? gate;
    final container = ProviderContainer(
      overrides: [
        preferencesProvider.overrideWithValue(prefs),
        taskPlatformProvider.overrideWithValue(platform),
        libraryRepositoryProvider.overrideWithValue(repo),
        downloadJobExecutorProvider.overrideWithValue((_, index) async {
          if (gate != null) await gate.future;
          if (index == 1) throw StateError('private source error');
        }),
      ],
    );
    addTearDown(container.dispose);
    addTearDown(platform.dispose);
    final queue = container.read(downloadQueueProvider.notifier);
    await queue.enqueue('b', ['a', 'b']);
    await queue.start();
    await until(() => platform.summaries.isNotEmpty);
    expect(platform.summaries, [('downloads', 1, 1)]);
    expect(platform.requests, 0);
    gate = Completer<void>();
    await queue.enqueue('b', ['a']);
    await queue.start();
    await until(
      () => container
          .read(downloadQueueProvider)
          .tasks
          .any((job) => job.status == DownloadJobStatus.active),
    );
    await container.read(settingsProvider.notifier).update(incognitoMode: true);
    await container
        .read(settingsProvider.notifier)
        .update(incognitoMode: false);
    gate.complete();
    await until(() => !container.read(downloadQueueProvider).running);
    expect(platform.summaries, [('downloads', 1, 1)]);
  });

  for (final granted in [true, false]) {
    testWidgets(
      'finite background lease granted=$granted preserves queued work and stops active execution',
      (tester) async {
        SharedPreferences.setMockInitialValues({
          TaskNotifications.preferenceKey: true,
        });
        final prefs = await SharedPreferences.getInstance(),
            platform = FakeTasks()..granted = granted;
        final repo = MemoryLibraryRepository();
        await repo.save(book());
        final gate = Completer<void>();
        DownloadExecution? execution;
        final container = ProviderContainer(
          overrides: [
            preferencesProvider.overrideWithValue(prefs),
            taskPlatformProvider.overrideWithValue(platform),
            libraryRepositoryProvider.overrideWithValue(repo),
            guardedDownloadJobExecutorProvider.overrideWithValue((
              _,
              _,
              active,
            ) {
              execution = active;
              return gate.future;
            }),
          ],
        );
        addTearDown(container.dispose);
        addTearDown(platform.dispose);
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: const TaskLifecycle(child: SizedBox()),
          ),
        );
        final queue = container.read(downloadQueueProvider.notifier);
        await queue.enqueue('b', ['a', 'b']);
        await queue.start();
        for (var i = 0; i < 10 && execution == null; i++) {
          await tester.pump();
        }
        expect(execution, isNotNull);
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        for (var i = 0; i < 5; i++) {
          await tester.pump();
        }
        expect(platform.begins, 1);
        if (granted) platform.expired.add(null);
        for (var i = 0; i < 5; i++) {
          await tester.pump();
        }
        expect(execution!.isCancelled, true);
        final paused = container.read(downloadQueueProvider);
        expect(paused.running, false);
        expect(
          paused.tasks.map((job) => job.status),
          everyElement(DownloadJobStatus.pending),
        );
        expect(paused.pauseReason, contains('iOS'));
        expect(platform.stopped, [(2, 0)]);
        if (granted) platform.expired.add(null); // No duplicate summary.
        await tester.pump();
        expect(platform.stopped, [(2, 0)]);
        gate.complete();
        for (var i = 0; i < 5; i++) {
          await tester.pump();
        }
        expect(container.read(downloadQueueProvider).tasks.length, 2);
        expect(DownloadQueueRepository(prefs).load().length, 2);
        expect((await repo.find('b'))!.title, 'Private fixture title');
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pump();
        await tester.pumpWidget(const SizedBox());
        expect(platform.begins, 1);
      },
    );
  }

  testWidgets(
    'lease expiration cannot disclose a session that became private and returned',
    (tester) async {
      SharedPreferences.setMockInitialValues({
        TaskNotifications.preferenceKey: true,
      });
      final prefs = await SharedPreferences.getInstance(),
          platform = FakeTasks();
      final repo = MemoryLibraryRepository();
      await repo.save(book());
      final gate = Completer<void>();
      final container = ProviderContainer(
        overrides: [
          preferencesProvider.overrideWithValue(prefs),
          taskPlatformProvider.overrideWithValue(platform),
          libraryRepositoryProvider.overrideWithValue(repo),
          downloadJobExecutorProvider.overrideWithValue((_, _) => gate.future),
        ],
      );
      addTearDown(container.dispose);
      addTearDown(platform.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const TaskLifecycle(child: SizedBox()),
        ),
      );
      final queue = container.read(downloadQueueProvider.notifier);
      await queue.enqueue('b', ['a', 'b']);
      await queue.start();
      await tester.pump();
      await container
          .read(settingsProvider.notifier)
          .update(incognitoMode: true);
      await container
          .read(settingsProvider.notifier)
          .update(incognitoMode: false);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      platform.expired.add(null);
      for (var i = 0; i < 5; i++) {
        await tester.pump();
      }
      expect(platform.stopped, isEmpty);
      expect(container.read(downloadQueueProvider).tasks, hasLength(2));
      expect(container.read(downloadQueueProvider).running, false);
      gate.complete();
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('a background lease granted after foreground resume is ended', (
    tester,
  ) async {
    final prefs = await SharedPreferences.getInstance(),
        platform = FakeTasks()..delayedLease = Completer<bool>();
    final repo = MemoryLibraryRepository();
    await repo.save(book());
    final gate = Completer<void>();
    final container = ProviderContainer(
      overrides: [
        preferencesProvider.overrideWithValue(prefs),
        taskPlatformProvider.overrideWithValue(platform),
        libraryRepositoryProvider.overrideWithValue(repo),
        downloadJobExecutorProvider.overrideWithValue((_, _) => gate.future),
      ],
    );
    addTearDown(container.dispose);
    addTearDown(platform.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const TaskLifecycle(child: SizedBox()),
      ),
    );
    final queue = container.read(downloadQueueProvider.notifier);
    await queue.enqueue('b', ['a']);
    await queue.start();
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    platform.delayedLease!.complete(true);
    await tester.pump();
    await tester.pump();
    expect(platform.ends, 1);
    platform.expired.add(null);
    await tester.pump();
    expect(container.read(downloadQueueProvider).running, true);
    expect(platform.stopped, isEmpty);
    queue.pause();
    gate.complete();
    await tester.pump();
    await tester.pump();
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'native expiry uses the pre-lease numeric snapshot and suppresses a later private session',
    (tester) async {
      SharedPreferences.setMockInitialValues({
        TaskNotifications.preferenceKey: true,
      });
      final prefs = await SharedPreferences.getInstance(),
          platform = FakeBackgroundTasks();
      final repo = MemoryLibraryRepository();
      await repo.save(book());
      final gate = Completer<void>();
      final container = ProviderContainer(
        overrides: [
          preferencesProvider.overrideWithValue(prefs),
          taskPlatformProvider.overrideWithValue(platform),
          libraryRepositoryProvider.overrideWithValue(repo),
          downloadJobExecutorProvider.overrideWithValue((_, _) => gate.future),
        ],
      );
      addTearDown(container.dispose);
      addTearDown(platform.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const TaskLifecycle(child: SizedBox()),
        ),
      );
      final queue = container.read(downloadQueueProvider.notifier);
      await queue.enqueue('b', ['a', 'b']);
      await queue.start();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      for (var i = 0; i < 10; i++) {
        await tester.pump();
      }
      expect(platform.ready, 1);
      expect(platform.begins, 1);
      expect(platform.snapshots.last, (
        pending: 2,
        failed: 0,
        notify: true,
        resume: true,
      ));
      await container
          .read(settingsProvider.notifier)
          .update(incognitoMode: true);
      await container
          .read(settingsProvider.notifier)
          .update(incognitoMode: false);
      for (var i = 0; i < 5; i++) {
        await tester.pump();
      }
      expect(platform.snapshots.last.notify, false);
      expect(platform.snapshots.last.resume, false);
      platform.expired.add(null);
      for (var i = 0; i < 5; i++) {
        await tester.pump();
      }
      expect(container.read(downloadQueueProvider).running, false);
      expect(platform.stopped, isEmpty); // Native owns the one-shot notice.
      expect(DownloadQueueRepository(prefs).load(), hasLength(2));
      gate.complete();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'a scheduled native window resumes the guarded durable queue and stops on expiry',
    (tester) async {
      final prefs = await SharedPreferences.getInstance(),
          platform = FakeBackgroundTasks();
      final repo = MemoryLibraryRepository();
      await repo.save(book());
      final gate = Completer<void>();
      DownloadExecution? execution;
      final container = ProviderContainer(
        overrides: [
          preferencesProvider.overrideWithValue(prefs),
          taskPlatformProvider.overrideWithValue(platform),
          libraryRepositoryProvider.overrideWithValue(repo),
          appLockProvider.overrideWith(ReadyAppLock.new),
          guardedDownloadJobExecutorProvider.overrideWithValue((_, _, value) {
            execution = value;
            return gate.future;
          }),
        ],
      );
      addTearDown(container.dispose);
      addTearDown(platform.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const TaskLifecycle(child: SizedBox()),
        ),
      );
      final queue = container.read(downloadQueueProvider.notifier);
      await queue.enqueue('b', ['a', 'b']);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      platform.scheduled.add(11);
      for (var i = 0; i < 15; i++) {
        await tester.pump();
      }
      expect(execution, isNotNull);
      expect(container.read(downloadQueueProvider).running, true);
      expect(platform.begins, 0); // BGProcessingTask already owns the grant.
      platform.expired.add(null);
      for (var i = 0; i < 10; i++) {
        await tester.pump();
      }
      expect(execution!.isCancelled, true);
      expect(container.read(downloadQueueProvider).running, false);
      expect(platform.finished, [(11, false)]);
      expect(
        platform.snapshots.last.resume,
        true,
      ); // Keep the bounded next request eligible.
      expect(DownloadQueueRepository(prefs).load(), hasLength(2));
      gate.complete();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'scheduled callback in foreground cannot start downloads or acquire a lease',
    (tester) async {
      final prefs = await SharedPreferences.getInstance(),
          platform = FakeBackgroundTasks();
      final repo = MemoryLibraryRepository();
      await repo.save(book());
      var executions = 0;
      final container = ProviderContainer(
        overrides: [
          preferencesProvider.overrideWithValue(prefs),
          taskPlatformProvider.overrideWithValue(platform),
          libraryRepositoryProvider.overrideWithValue(repo),
          downloadJobExecutorProvider.overrideWithValue((_, _) async {
            executions++;
          }),
        ],
      );
      addTearDown(container.dispose);
      addTearDown(platform.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const TaskLifecycle(child: SizedBox()),
        ),
      );
      await container.read(downloadQueueProvider.notifier).enqueue('b', ['a']);
      platform.scheduled.add(12);
      for (var i = 0; i < 5; i++) {
        await tester.pump();
      }
      expect(platform.finished, [(12, false)]);
      expect(executions, 0);
      expect(platform.begins, 0);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'scheduled background cannot run source work behind an app lock',
    (tester) async {
      final prefs = await SharedPreferences.getInstance(),
          platform = FakeBackgroundTasks();
      var executions = 0;
      final container = ProviderContainer(
        overrides: [
          preferencesProvider.overrideWithValue(prefs),
          taskPlatformProvider.overrideWithValue(platform),
          appLockProvider.overrideWith(() => ReadyAppLock(locked: true)),
          downloadJobExecutorProvider.overrideWithValue((_, _) async {
            executions++;
          }),
        ],
      );
      addTearDown(container.dispose);
      addTearDown(platform.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const TaskLifecycle(child: SizedBox()),
        ),
      );
      await container.read(downloadQueueProvider.notifier).enqueue('b', ['a']);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      platform.scheduled.add(13);
      for (var i = 0; i < 5; i++) {
        await tester.pump();
      }
      expect(platform.finished, [(13, false)]);
      expect(executions, 0);
      expect(container.exists(libraryRepositoryProvider), false);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'an update-only native window uses policy without a download queue',
    (tester) async {
      SharedPreferences.setMockInitialValues({
        'libraryUpdatePolicyV1': jsonEncode({'hours': 6}),
      });
      final prefs = await SharedPreferences.getInstance(),
          platform = FakeUpdateBackgroundTasks();
      final repo = MemoryLibraryRepository();
      await repo.save(book().copyWith(sourceRef: '/book'));
      final source = UpdateSource(
        () async => const [
          CatalogueChapter(ref: 'a', title: 'a', index: 0),
          CatalogueChapter(ref: 'b', title: 'b', index: 1),
          CatalogueChapter(ref: 'c', title: 'c', index: 2),
        ],
      );
      final container = ProviderContainer(
        overrides: [
          preferencesProvider.overrideWithValue(prefs),
          taskPlatformProvider.overrideWithValue(platform),
          libraryRepositoryProvider.overrideWithValue(repo),
          sourceRepositoryProvider.overrideWithValue(source),
          appLockProvider.overrideWith(ReadyAppLock.new),
        ],
      );
      addTearDown(container.dispose);
      addTearDown(platform.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const TaskLifecycle(child: SizedBox()),
        ),
      );
      for (var i = 0; i < 5; i++) {
        await tester.pump();
      }
      expect(platform.updates.last.requested, true);
      expect(container.read(downloadQueueProvider).tasks, isEmpty);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      platform.scheduled.add(17);
      for (var i = 0; i < 30; i++) {
        await tester.pump();
      }
      expect(source.calls, 1);
      expect((await repo.find('b'))!.chapters.length, 3);
      expect(prefs.containsKey('libraryLastAutomaticUpdate'), true);
      expect(platform.finished, [(17, true)]);
      expect(platform.begins, 0);
      expect(
        platform.updates.last.earliest,
        greaterThan(DateTime.now().millisecondsSinceEpoch),
      );
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'an active update acquires a finite lease and cannot finish after expiry/resume',
    (tester) async {
      SharedPreferences.setMockInitialValues({
        'libraryUpdatePolicyV1': jsonEncode({'hours': 6}),
        TaskNotifications.preferenceKey: true,
      });
      final prefs = await SharedPreferences.getInstance(),
          platform = FakeUpdateBackgroundTasks();
      final repo = MemoryLibraryRepository();
      await repo.save(book().copyWith(sourceRef: '/book'));
      final response = Completer<List<CatalogueChapter>>();
      final source = UpdateSource(() => response.future);
      final container = ProviderContainer(
        overrides: [
          preferencesProvider.overrideWithValue(prefs),
          taskPlatformProvider.overrideWithValue(platform),
          libraryRepositoryProvider.overrideWithValue(repo),
          sourceRepositoryProvider.overrideWithValue(source),
          appLockProvider.overrideWith(ReadyAppLock.new),
        ],
      );
      addTearDown(container.dispose);
      addTearDown(platform.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const TaskLifecycle(child: SizedBox()),
        ),
      );
      final work = container
          .read(libraryUpdateSchedulerProvider)
          .check(DateTime.now());
      final outcome = expectLater(work, throwsA(isA<LibraryUpdateCancelled>()));
      for (var i = 0; i < 20 && source.calls == 0; i++) {
        await tester.pump();
      }
      expect(source.calls, 1);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      for (var i = 0; i < 10; i++) {
        await tester.pump();
      }
      expect(platform.begins, 1);
      expect(platform.updates.last.remaining, 1);
      expect(platform.updates.last.notify, true);
      platform.expired.add(null);
      for (var i = 0; i < 5; i++) {
        await tester.pump();
      }
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      response.complete(const [
        CatalogueChapter(ref: 'a', title: 'a', index: 0),
        CatalogueChapter(ref: 'b', title: 'b', index: 1),
        CatalogueChapter(ref: 'c', title: 'c', index: 2),
      ]);
      for (var i = 0; i < 10; i++) {
        await tester.pump();
      }
      await outcome;
      expect((await repo.find('b'))!.chapters.length, 2);
      expect(prefs.containsKey('libraryLastAutomaticUpdate'), false);
      expect(platform.stopped, isEmpty);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
