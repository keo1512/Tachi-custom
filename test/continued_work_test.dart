import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tachi_books/features/downloads/presentation/download_queue_controller.dart';
import 'package:tachi_books/features/library/application/automatic_backup_status.dart';
import 'package:tachi_books/features/library/application/automatic_backup_controller.dart';
import 'package:tachi_books/features/library/application/library_update_report.dart';
import 'package:tachi_books/features/library/data/backup_configuration.dart';
import 'package:tachi_books/features/library/data/coordinated_preferences.dart';
import 'package:tachi_books/features/library/data/library_repository.dart';
import 'package:tachi_books/features/library/domain/library_update_result.dart';
import 'package:tachi_books/features/library/domain/library_book.dart';
import 'package:tachi_books/features/library/presentation/library_view_model.dart';
import 'package:tachi_books/features/privacy/application/app_lock_controller.dart';
import 'package:tachi_books/features/settings/settings_controller.dart';
import 'package:tachi_books/features/tasks/application/continued_work_coordinator.dart';
import 'package:tachi_books/features/tasks/application/task_lifecycle.dart';
import 'package:tachi_books/features/tasks/data/task_platform.dart';
import 'package:tachi_books/features/tasks/domain/continued_work.dart';

class _Platform implements TaskPlatform, ContinuedWorkPlatform {
  final expiry = StreamController<ContinuedWorkExpiry>.broadcast(sync: true);
  @override
  Stream<ContinuedWorkExpiry> get continuedWorkExpired => expiry.stream;
  final windows = StreamController<bool>.broadcast(sync: true);
  @override
  Stream<bool> get continuedWorkWindowChanged => windows.stream;
  final finiteExpiry = StreamController<void>.broadcast(sync: true);
  int begins = 0;
  Completer<bool>? delayedBegin;
  final updates = <ContinuedWork>[];
  final ends = <({int sequence, bool immediate})>[];
  Completer<ContinuedWorkResult>? block;
  bool fail = false, defer = false;
  int permissions = 0;
  @override
  Future<ContinuedWorkResult> updateContinuedWork(ContinuedWork value) async {
    updates.add(value);
    if (fail) throw StateError('transport unavailable');
    if (block != null) return block!.future;
    return ContinuedWorkResult(
      supported: true,
      enabled: true,
      visible: !defer,
      deferred: defer,
    );
  }

  @override
  Future<ContinuedWorkResult> endContinuedWork({
    required int sequence,
    required bool immediate,
  }) async {
    ends.add((sequence: sequence, immediate: immediate));
    return const ContinuedWorkResult(supported: true, enabled: true);
  }

  @override
  Stream<void> get backgroundExpired => finiteExpiry.stream;
  @override
  Future<bool> requestNotificationPermission() async {
    permissions++;
    return true;
  }

  @override
  Future<bool> notify(String kind, int completed, int failed) async => true;
  @override
  Future<void> clearNotifications() async {}
  @override
  Future<bool> beginBackground() async {
    begins++;
    return delayedBegin?.future ?? true;
  }

  @override
  Future<void> endBackground() async {}
  @override
  void dispose() {}
}

class _Queue extends DownloadQueueController {
  int completed = 0;
  bool userInitiated = true;
  int stops = 0;
  @override
  bool get continuedWorkUserInitiated => userInitiated;
  @override
  int get completedChaptersInRun => completed;
  @override
  DownloadQueueState build() => DownloadQueueState();
  void emit(DownloadQueueState value, {int done = 0}) {
    completed = done;
    state = value;
  }

  @override
  Future<void> suspendForBackground({String? reason}) async {
    stops++;
    state = DownloadQueueState(tasks: state.tasks, pauseReason: reason);
  }
}

class _Lock extends AppLockController {
  @override
  AppLockState build() => const AppLockState(initialized: true);
  void emit(AppLockState value) => state = value;
}

class _Settings extends SettingsController {
  @override
  AppSettings build() => const AppSettings();
  void private(bool value) => state = AppSettings(incognitoMode: value);
}

Future<void> _flush() async {
  for (var n = 0; n < 6; n++) {
    await Future<void>.delayed(Duration.zero);
  }
}

ContinuedWorkProgress _progress(
  int completed, {
  ContinuedWorkState state = ContinuedWorkState.running,
  String id = 'opaque',
}) => ContinuedWorkProgress(
  ContinuedWorkOperation.downloads,
  state,
  completed,
  8,
  0,
  id,
);

class _Fixture {
  _Fixture(
    this.container,
    this.platform,
    this.preferences,
    this.repository,
    this.subscription,
  );
  final ProviderContainer container;
  final _Platform platform;
  final CoordinatedPreferences preferences;
  final MemoryLibraryRepository repository;
  final ProviderSubscription<ContinuedWorkCoordinator> subscription;
  _Queue get queue => container.read(downloadQueueProvider.notifier) as _Queue;
  Future<void> close() async {
    subscription.close();
    container.dispose();
    await _flush();
  }
}

Future<_Fixture> _fixture() async {
  SharedPreferences.setMockInitialValues({});
  final repository = MemoryLibraryRepository();
  final preferences = await CoordinatedPreferences.open(
    await SharedPreferences.getInstance(),
    repository,
  );
  final platform = _Platform();
  final container = ProviderContainer(
    overrides: [
      preferencesProvider.overrideWithValue(preferences),
      libraryRepositoryProvider.overrideWithValue(repository),
      taskPlatformProvider.overrideWithValue(platform),
      downloadQueueProvider.overrideWith(_Queue.new),
      appLockProvider.overrideWith(_Lock.new),
      settingsProvider.overrideWith(_Settings.new),
    ],
  );
  final subscription = container.listen(
    continuedWorkCoordinatorProvider,
    (_, _) {},
  );
  await _flush();
  final fixture = _Fixture(
    container,
    platform,
    preferences,
    repository,
    subscription,
  );
  addTearDown(fixture.close);
  return fixture;
}

const _jobA = DownloadJob(
  bookId: 'private title A',
  chapterId: 'secret chapter',
);
const _jobB = DownloadJob(
  bookId: 'private title B',
  chapterId: 'secret chapter',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final operation in [
    ContinuedWorkOperation.updates,
    ContinuedWorkOperation.backup,
  ]) {
    test(
      '$operation process grant preserves executor past finite expiry and revocation reacquires finite window',
      () async {
        final fixture = await _fixture();
        final retained = fixture.container.listen(
          taskCoordinatorProvider,
          (_, _) {},
        );
        final owner = fixture.container.read(taskCoordinatorProvider);
        final updateGate = fixture.container.read(
          libraryUpdateExecutionProvider,
        );
        final backupGate = fixture.container.read(
          automaticBackupExecutionProvider,
        );
        final updateToken = updateGate.begin(),
            backupToken = backupGate.begin();
        if (operation == ContinuedWorkOperation.updates) {
          final progress = fixture.container.read(
            libraryUpdateProgressProvider.notifier,
          );
          progress.report(
            progress.begin(),
            const LibraryUpdateProgress(
              requestedBooks: 190,
              processedBooks: 8,
              checkedBooks: 8,
              addedChapters: 0,
              skippedBooks: 0,
              failedBooks: 0,
            ),
          );
        } else {
          await fixture.container
              .read(automaticBackupStatusProvider.notifier)
              .record(
                const AutomaticBackupRunStatus(
                  stage: AutomaticBackupRunStage.running,
                  userInitiated: true,
                ),
              );
        }
        fixture.platform.windows.add(true);
        owner.didChangeAppLifecycleState(AppLifecycleState.paused);
        await _flush();
        expect(fixture.platform.updates.last.operation, operation);
        expect(fixture.platform.begins, 0);
        fixture.platform.finiteExpiry.add(null);
        await _flush();
        expect(updateToken.check, returnsNormally);
        expect(() => backupGate.check(backupToken), returnsNormally);
        fixture.platform.windows.add(false);
        await _flush();
        expect(fixture.platform.begins, 1);
        expect(owner.leased, true);
        fixture.platform.finiteExpiry.add(null);
        await _flush();
        expect(updateToken.check, throwsA(isA<LibraryUpdateCancelled>()));
        expect(
          () => backupGate.check(backupToken),
          throwsA(isA<AutomaticBackupInterrupted>()),
        );
        retained.close();
      },
    );
  }

  test('continued process window ignores old finite expiry then acquires bounded fallback', () async {
    final fixture = await _fixture();
    final retained = fixture.container.listen(
      taskCoordinatorProvider,
      (_, _) {},
    );
    final owner = fixture.container.read(taskCoordinatorProvider);
    fixture.queue.emit(DownloadQueueState(tasks: [_jobA], running: true));
    owner.didChangeAppLifecycleState(AppLifecycleState.paused);
    fixture.platform.windows.add(true);
    await _flush();
    expect(owner.continuedWindow, true);
    expect(fixture.platform.begins, 0);
    expect(owner.leased, false);
    final gate = fixture.container.read(libraryUpdateExecutionProvider);
    final execution = gate.begin();
    fixture.platform.finiteExpiry.add(null);
    await _flush();
    expect(fixture.queue.stops, 0);
    expect(execution.check, returnsNormally);
    fixture.platform.windows.add(false);
    await _flush();
    expect(owner.continuedWindow, false);
    expect(fixture.platform.begins, 1);
    expect(owner.leased, true);
    fixture.platform.finiteExpiry.add(null);
    await _flush();
    expect(fixture.queue.stops, 1);
    expect(execution.check, throwsA(isA<LibraryUpdateCancelled>()));
    retained.close();
  });

  test(
    'late finite grant cannot overwrite a newer continued process window',
    () async {
      final fixture = await _fixture();
      final retained = fixture.container.listen(
        taskCoordinatorProvider,
        (_, _) {},
      );
      final owner = fixture.container.read(taskCoordinatorProvider);
      fixture.platform.delayedBegin = Completer<bool>();
      fixture.queue.emit(DownloadQueueState(tasks: [_jobA], running: true));
      owner.didChangeAppLifecycleState(AppLifecycleState.paused);
      await _flush();
      expect(fixture.platform.begins, 1);
      fixture.platform.windows.add(true);
      fixture.platform.delayedBegin!.complete(true);
      fixture.platform.delayedBegin = null;
      await _flush();
      expect(owner.continuedWindow, true);
      expect(owner.leased, false);
      fixture.platform.windows.add(false);
      await _flush();
      expect(fixture.platform.begins, 2);
      expect(owner.leased, true);
      retained.close();
    },
  );

  test(
    'system callback accepts only a bounded operation and opaque session pair',
    () {
      final valid = ContinuedWorkExpiry.decode({
        'operation': 'updates',
        'sessionId': 'opaque_123',
      });
      expect(valid?.operation, ContinuedWorkOperation.updates);
      expect(valid?.sessionId, 'opaque_123');
      for (final invalid in [
        null,
        {},
        {'operation': 'updates', 'sessionId': 'private title'},
        {'operation': 'arbitrary', 'sessionId': 'opaque'},
        {'operation': 'updates', 'sessionId': 'opaque', 'bookId': 'private'},
        {'operation': 'updates', 'sessionId': 'a' * 129},
      ]) {
        expect(ContinuedWorkExpiry.decode(invalid), null);
      }
    },
  );

  test(
    'automatic download/update/backup remain on ordinary background scheduler',
    () async {
      final fixture = await _fixture();
      fixture.queue.userInitiated = false;
      fixture.queue.emit(DownloadQueueState(tasks: [_jobA], running: true));
      final updates = fixture.container.read(
        libraryUpdateProgressProvider.notifier,
      );
      final generation = updates.begin();
      updates.report(
        generation,
        const LibraryUpdateProgress(
          requestedBooks: 1,
          processedBooks: 0,
          checkedBooks: 0,
          addedChapters: 0,
          skippedBooks: 0,
          failedBooks: 0,
          userInitiated: false,
        ),
      );
      await fixture.container
          .read(automaticBackupStatusProvider.notifier)
          .record(
            const AutomaticBackupRunStatus(
              stage: AutomaticBackupRunStage.running,
            ),
          );
      await _flush();
      expect(fixture.platform.updates, isEmpty);
      expect(fixture.platform.permissions, 0);
    },
  );

  test(
    'system Stop targets matching download session and rejects old callbacks',
    () async {
      final fixture = await _fixture();
      fixture.queue.emit(DownloadQueueState(tasks: [_jobA], running: true));
      await _flush();
      final initial = fixture.platform.updates.last;
      fixture.platform.expiry.add(
        const ContinuedWorkExpiry(ContinuedWorkOperation.downloads, 'obsolete'),
      );
      expect(fixture.queue.stops, 0);
      fixture.platform.expiry.add(
        ContinuedWorkExpiry(initial.operation, initial.sessionId),
      );
      expect(fixture.queue.stops, 1);
      expect(fixture.platform.ends.last.immediate, true);
      fixture.queue.emit(DownloadQueueState(tasks: [_jobA], running: true));
      await _flush();
      final next = fixture.platform.updates.last;
      expect(next.sessionId, isNot(initial.sessionId));
      fixture.platform.expiry.add(
        ContinuedWorkExpiry(initial.operation, initial.sessionId),
      );
      expect(fixture.queue.stops, 1);
      fixture.platform.expiry.add(
        ContinuedWorkExpiry(next.operation, next.sessionId),
      );
      expect(fixture.queue.stops, 2);
    },
  );

  test('system Stop invalidates update token while new foreground execution is allowed', () async {
    final fixture = await _fixture();
    final gate = fixture.container.read(libraryUpdateExecutionProvider);
    final old = gate.begin();
    final updates = fixture.container.read(
      libraryUpdateProgressProvider.notifier,
    );
    final generation = updates.begin();
    updates.report(
      generation,
      const LibraryUpdateProgress(
        requestedBooks: 4,
        processedBooks: 1,
        checkedBooks: 1,
        addedChapters: 0,
        skippedBooks: 0,
        failedBooks: 0,
      ),
    );
    await _flush();
    final shown = fixture.platform.updates.last;
    fixture.platform.expiry.add(
      ContinuedWorkExpiry(shown.operation, shown.sessionId),
    );
    expect(old.check, throwsA(isA<LibraryUpdateCancelled>()));
    expect(gate.begin().check, throwsA(isA<LibraryUpdateCancelled>()));
    final retry = gate.begin(userInitiated: true);
    expect(retry.check, returnsNormally);
    await gate.wait(retry);
    final count = fixture.platform.updates.length;
    updates.report(
      generation,
      const LibraryUpdateProgress(
        requestedBooks: 4,
        processedBooks: 2,
        checkedBooks: 2,
        addedChapters: 0,
        skippedBooks: 0,
        failedBooks: 0,
      ),
    );
    await _flush();
    expect(fixture.platform.updates.length, count);
    updates.finish(generation);
    final newGeneration = updates.begin();
    updates.report(
      newGeneration,
      const LibraryUpdateProgress(
        requestedBooks: 4,
        processedBooks: 0,
        checkedBooks: 0,
        addedChapters: 0,
        skippedBooks: 0,
        failedBooks: 0,
      ),
    );
    await _flush();
    expect(fixture.platform.updates.last.sessionId, isNot(shown.sessionId));
    gate.finish(old);
    gate.finish(retry);
  });

  test('system Stop invalidates backup generation and foreground manual retry is allowed', () async {
    final fixture = await _fixture();
    final gate = fixture.container.read(automaticBackupExecutionProvider);
    final old = gate.begin();
    final status = fixture.container.read(
      automaticBackupStatusProvider.notifier,
    );
    await status.record(
      const AutomaticBackupRunStatus(
        stage: AutomaticBackupRunStage.running,
        userInitiated: true,
      ),
    );
    await _flush();
    final shown = fixture.platform.updates.last;
    fixture.platform.expiry.add(
      ContinuedWorkExpiry(shown.operation, shown.sessionId),
    );
    expect(() => gate.check(old), throwsA(isA<AutomaticBackupInterrupted>()));
    expect(() => gate.begin(), throwsA(isA<AutomaticBackupInterrupted>()));
    final retry = gate.begin(userInitiated: true);
    expect(() => gate.check(retry), returnsNormally);
    await status.record(
      const AutomaticBackupRunStatus(
        stage: AutomaticBackupRunStage.interrupted,
      ),
    );
    await status.record(
      const AutomaticBackupRunStatus(
        stage: AutomaticBackupRunStage.running,
        userInitiated: true,
      ),
    );
    await _flush();
    expect(fixture.platform.updates.last.sessionId, isNot(shown.sessionId));
  });

  test('system Stop in background does not reopen execution gates', () async {
    final fixture = await _fixture();
    final owner = fixture.container.read(continuedWorkCoordinatorProvider);
    final gate = fixture.container.read(libraryUpdateExecutionProvider);
    final old = gate.begin();
    final updates = fixture.container.read(
      libraryUpdateProgressProvider.notifier,
    );
    final generation = updates.begin();
    updates.report(
      generation,
      const LibraryUpdateProgress(
        requestedBooks: 4,
        processedBooks: 0,
        checkedBooks: 0,
        addedChapters: 0,
        skippedBooks: 0,
        failedBooks: 0,
      ),
    );
    await _flush();
    owner.didChangeAppLifecycleState(AppLifecycleState.paused);
    WidgetsBinding.instance.handleAppLifecycleStateChanged(
      AppLifecycleState.paused,
    );
    addTearDown(
      () => WidgetsBinding.instance.handleAppLifecycleStateChanged(
        AppLifecycleState.resumed,
      ),
    );
    final shown = fixture.platform.updates.last;
    fixture.platform.expiry.add(
      ContinuedWorkExpiry(shown.operation, shown.sessionId),
    );
    expect(old.check, throwsA(isA<LibraryUpdateCancelled>()));
    expect(gate.begin().check, throwsA(isA<LibraryUpdateCancelled>()));
    expect(
      gate.begin(userInitiated: true).check,
      throwsA(isA<LibraryUpdateCancelled>()),
    );
  });

  test('real queue failed retry starts a fresh activity and counts once per chapter', () async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    final repository = MemoryLibraryRepository();
    await repository.save(
      LibraryBook(
        id: 'book',
        title: 'private title',
        engine: 'vbook',
        sourceId: 'source',
        sourceRef: 'source-ref',
        chapters: const [
          BookChapter(id: 'chapter', title: 'chapter', index: 0),
        ],
      ),
    );
    final platform = _Platform();
    var attempts = 0;
    final container = ProviderContainer(
      overrides: [
        preferencesProvider.overrideWithValue(preferences),
        libraryRepositoryProvider.overrideWithValue(repository),
        taskPlatformProvider.overrideWithValue(platform),
        appLockProvider.overrideWith(_Lock.new),
        downloadJobExecutorProvider.overrideWithValue((_, _) async {
          if (++attempts <= 3) throw StateError('private raw error');
        }),
      ],
    );
    final retained = container.listen(
      continuedWorkCoordinatorProvider,
      (_, _) {},
    );
    final queue = container.read(downloadQueueProvider.notifier);
    await queue.enqueue('book', ['chapter']);
    await queue.start();
    for (
      var n = 0;
      n < 50 && container.read(downloadQueueProvider).running;
      n++
    ) {
      await _flush();
    }
    final failed = platform.updates.last;
    expect(
      (failed.state, failed.completed, failed.total, failed.failed),
      (ContinuedWorkState.failed, 1, 1, 1),
    );
    expect(attempts, 3);
    await queue.retry();
    for (
      var n = 0;
      n < 50 && container.read(downloadQueueProvider).running;
      n++
    ) {
      await _flush();
    }
    final completed = platform.updates.last;
    expect(
      (completed.state, completed.completed, completed.total, completed.failed),
      (ContinuedWorkState.completed, 1, 1, 0),
    );
    expect(completed.sessionId, isNot(failed.sessionId));
    expect(attempts, 4);
    retained.close();
    container.dispose();
  });

  test(
    'terminal transport failure still attempts to end old running activity',
    () async {
      final platform = _Platform()..fail = true;
      final driver = ContinuedWorkDriver(platform);
      driver.show(_progress(8, state: ContinuedWorkState.completed));
      await _flush();
      expect(platform.ends.single.immediate, false);
      expect(
        platform.ends.single.sequence,
        greaterThan(platform.updates.single.sequence),
      );
      driver.dispose();
    },
  );

  test(
    'payload is numeric and generic; validates subset and bounded identity',
    () {
      final value = _progress(2).sequence(1);
      expect(value.toMap().keys, [
        'operation',
        'state',
        'completed',
        'total',
        'failed',
        'sequence',
        'sessionId',
      ]);
      expect(
        () => ContinuedWork(
          operation: ContinuedWorkOperation.downloads,
          state: ContinuedWorkState.running,
          completed: 1,
          total: 2,
          failed: 2,
          sequence: 1,
          sessionId: 'opaque',
        ),
        throwsArgumentError,
      );
      expect(() => _progress(9).sequence(1), throwsArgumentError);
      expect(
        () => _progress(1, id: 'private title').sequence(1),
        throwsArgumentError,
      );
      expect(() => _progress(1).sequence(1000001), throwsArgumentError);
    },
  );

  test('native channel returns background deferred without notification permission', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    const channel = MethodChannel('dev.tachibooks/tasks');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return {
        'supported': true,
        'enabled': true,
        'visible': false,
        'deferred': true,
      };
    });
    final native = NativeTaskPlatform();
    final result = await native.updateContinuedWork(_progress(2).sequence(7));
    expect(result.deferred, true);
    expect(result.visible, false);
    expect(calls.single.method, 'updateContinuedWork');
    expect(calls.single.arguments, _progress(2).sequence(7).toMap());
    await native.endContinuedWork(sequence: 8, immediate: true);
    expect(calls.last.arguments, {'sequence': 8, 'immediate': true});
    await expectLater(
      native.endContinuedWork(sequence: -1, immediate: true),
      throwsArgumentError,
    );
    native.dispose();
    await native.endContinuedWork(sequence: 9, immediate: true);
    expect(calls.last.method, 'endContinuedWork');
    expect(calls.last.arguments, {'sequence': 9, 'immediate': true});
    final beforeDisposedUpdate = calls.length;
    await native.updateContinuedWork(_progress(3).sequence(10));
    expect(calls.length, beforeDisposedUpdate);
    await _flush();
    messenger.setMockMethodCallHandler(channel, null);
  });

  test(
    'driver serializes/coalesces counts, preserves terminal then ends',
    () async {
      final platform = _Platform()..block = Completer<ContinuedWorkResult>();
      final driver = ContinuedWorkDriver(platform);
      driver.show(_progress(0));
      driver.show(_progress(1));
      driver.show(_progress(2));
      driver.show(_progress(8, state: ContinuedWorkState.completed));
      expect(platform.updates.length, 1);
      platform.block!.complete(const ContinuedWorkResult(supported: true));
      platform.block = null;
      await _flush();
      expect(platform.updates.map((value) => value.completed), [0, 8]);
      expect(platform.updates.last.state, ContinuedWorkState.completed);
      expect(platform.ends.single.immediate, false);
      expect(
        platform.ends.single.sequence,
        greaterThan(platform.updates.last.sequence),
      );
      driver.dispose();
    },
  );

  test(
    'privacy clear bypasses blocked update and discards queued late progress',
    () async {
      final platform = _Platform()..block = Completer<ContinuedWorkResult>();
      final driver = ContinuedWorkDriver(platform);
      driver.show(_progress(0));
      driver.show(_progress(4));
      driver.clear();
      expect(platform.ends.single.immediate, true);
      expect(
        platform.ends.single.sequence,
        greaterThan(platform.updates.single.sequence),
      );
      platform.block!.complete(const ContinuedWorkResult(visible: true));
      await _flush();
      expect(platform.updates.length, 1);
      expect(driver.result.visible, false);
      driver.dispose();
    },
  );

  test(
    'a deferred result arriving after resume receives one current retry',
    () async {
      final platform = _Platform()..block = Completer<ContinuedWorkResult>();
      final driver = ContinuedWorkDriver(platform);
      driver.show(_progress(0));
      driver.resumed();
      final block = platform.block!;
      platform.block = null;
      block.complete(
        const ContinuedWorkResult(
          supported: true,
          enabled: true,
          deferred: true,
        ),
      );
      await _flush();
      expect(platform.updates.length, 2);
      expect(driver.result.visible, true);
      driver.dispose();
    },
  );

  test(
    'revision guard is rechecked after an in-flight platform response',
    () async {
      final platform = _Platform()..block = Completer<ContinuedWorkResult>();
      var current = true;
      final driver = ContinuedWorkDriver(platform);
      driver.show(_progress(0), isCurrent: () => current);
      driver.show(_progress(1), isCurrent: () => current);
      current = false;
      platform.block!.complete(const ContinuedWorkResult(visible: true));
      await _flush();
      expect(platform.updates.length, 1);
      expect(platform.ends.single.immediate, true);
      expect(driver.result.visible, false);
      driver.dispose();
    },
  );

  test(
    'platform failure is isolated and dispose invalidates pending results',
    () async {
      final platform = _Platform()..fail = true;
      final driver = ContinuedWorkDriver(platform);
      driver.show(_progress(0));
      await _flush();
      platform.fail = false;
      platform.block = Completer<ContinuedWorkResult>();
      driver.show(_progress(1));
      driver.show(_progress(2));
      driver.dispose();
      final end = platform.ends.last;
      platform.block!.complete(const ContinuedWorkResult(visible: true));
      await _flush();
      driver.show(_progress(3));
      expect(platform.updates.length, 2);
      expect(platform.ends.last, end);
      expect(driver.result.visible, false);
    },
  );

  test(
    'real queue cancel and late HTTP never increment completed chapters',
    () async {
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      final repository = MemoryLibraryRepository();
      await repository.save(
        LibraryBook(
          id: 'book',
          title: 'private title',
          engine: 'vbook',
          sourceId: 'source',
          sourceRef: 'source-ref',
          chapters: const [
            BookChapter(id: 'chapter', title: 'chapter', index: 0),
          ],
        ),
      );
      final platform = _Platform();
      final entered = Completer<void>(), finish = Completer<void>();
      final container = ProviderContainer(
        overrides: [
          preferencesProvider.overrideWithValue(preferences),
          libraryRepositoryProvider.overrideWithValue(repository),
          taskPlatformProvider.overrideWithValue(platform),
          appLockProvider.overrideWith(_Lock.new),
          downloadJobExecutorProvider.overrideWithValue((_, _) async {
            entered.complete();
            await finish.future;
          }),
        ],
      );
      final retained = container.listen(
        continuedWorkCoordinatorProvider,
        (_, _) {},
      );
      final queue = container.read(downloadQueueProvider.notifier);
      await queue.enqueue('book', ['chapter']);
      await queue.start();
      await entered.future;
      await queue.cancelAll();
      await _flush();
      expect(queue.completedChaptersInRun, 0);
      expect(platform.updates.last.state, ContinuedWorkState.paused);
      expect(platform.updates.last.completed, 0);
      finish.complete();
      await _flush();
      expect(queue.completedChaptersInRun, 0);
      expect(platform.updates.last.state, ContinuedWorkState.paused);
      expect(platform.updates.last.completed, 0);
      retained.close();
      container.dispose();
    },
  );

  test(
    'download units are chapters; failed subset and cancel stays paused',
    () async {
      final fixture = await _fixture();
      fixture.queue.emit(
        DownloadQueueState(tasks: [_jobA, _jobB], running: true),
      );
      await _flush();
      final session = fixture.platform.updates.last.sessionId;
      expect(fixture.platform.updates.last.total, 2);
      fixture.queue.emit(
        DownloadQueueState(
          tasks: [_jobB.copyWith(status: DownloadJobStatus.failed)],
        ),
        done: 1,
      );
      await _flush();
      final terminal = fixture.platform.updates.last;
      expect(terminal.state, ContinuedWorkState.failed);
      expect((terminal.completed, terminal.failed, terminal.total), (2, 1, 2));
      expect(terminal.sessionId, session);
      fixture.queue.emit(
        DownloadQueueState(tasks: [_jobA, _jobB], running: true),
      );
      await _flush();
      fixture.queue.emit(DownloadQueueState(), done: 0);
      await _flush();
      expect(fixture.platform.updates.last.state, ContinuedWorkState.paused);
      expect(fixture.platform.updates.last.completed, 0);
      expect(
        fixture.platform.updates.last.toMap().toString().contains(
          'private title',
        ),
        false,
      );
    },
  );

  test(
    'incognito beginning or transition latches privacy for the entire run',
    () async {
      final fixture = await _fixture();
      final settings =
          fixture.container.read(settingsProvider.notifier) as _Settings;
      settings.private(true);
      fixture.queue.emit(DownloadQueueState(tasks: [_jobA], running: true));
      settings.private(false);
      fixture.queue.emit(DownloadQueueState(tasks: [_jobA], running: true));
      await _flush();
      expect(fixture.platform.updates, isEmpty);
      fixture.queue.emit(DownloadQueueState(), done: 1);
      fixture.queue.emit(DownloadQueueState(tasks: [_jobB], running: true));
      await _flush();
      expect(fixture.platform.updates, hasLength(1));
      settings.private(true);
      expect(fixture.platform.ends.last.immediate, true);
      settings.private(false);
      fixture.queue.emit(DownloadQueueState(tasks: [_jobB], running: true));
      await _flush();
      expect(fixture.platform.updates, hasLength(1));
    },
  );

  test('uninitialized/invalid/authenticating/locked states immediately hide and latch', () async {
    final fixture = await _fixture();
    final lock = fixture.container.read(appLockProvider.notifier) as _Lock;
    for (final denied in [
      const AppLockState(),
      const AppLockState(initialized: true, configurationValid: false),
      const AppLockState(initialized: true, authenticating: true),
      const AppLockState(initialized: true, locked: true),
    ]) {
      fixture.queue.emit(DownloadQueueState(tasks: [_jobA], running: true));
      await _flush();
      final before = fixture.platform.updates.length;
      lock.emit(denied);
      expect(fixture.platform.ends.last.immediate, true);
      lock.emit(const AppLockState(initialized: true));
      fixture.queue.emit(DownloadQueueState(tasks: [_jobA], running: true));
      await _flush();
      expect(fixture.platform.updates.length, before);
      fixture.queue.emit(DownloadQueueState(), done: 1);
    }
  });

  test(
    'restore begins with immediate removal before its commit finishes',
    () async {
      final fixture = await _fixture();
      fixture.queue.emit(DownloadQueueState(tasks: [_jobA], running: true));
      await _flush();
      final entered = Completer<void>(), finish = Completer<void>();
      final configuration = BackupConfiguration.capture(fixture.preferences);
      final restore = fixture.preferences.exclusive(
        () => fixture.preferences.restoreLocked(
          incoming: configuration,
          expectedFingerprint: configuration.fingerprint,
          oldLibraryFingerprint: 'a' * 64,
          newLibraryFingerprint: 'a' * 64,
          commit: (beforeCommit) async {
            entered.complete();
            await finish.future;
            await beforeCommit();
          },
        ),
      );
      await entered.future;
      expect(fixture.platform.ends.last.immediate, true);
      final before = fixture.platform.updates.length;
      fixture.queue.emit(DownloadQueueState(tasks: [_jobA], running: true));
      finish.complete();
      await restore;
      await _flush();
      expect(fixture.platform.updates.length, before);
    },
  );

  test(
    'retains active OS grant; chooses downloads then updates between runs',
    () async {
      final fixture = await _fixture();
      final backup = fixture.container.read(
        automaticBackupStatusProvider.notifier,
      );
      await backup.record(
        const AutomaticBackupRunStatus(
          stage: AutomaticBackupRunStage.running,
          userInitiated: true,
        ),
      );
      await _flush();
      expect(
        fixture.platform.updates.last.operation,
        ContinuedWorkOperation.backup,
      );
      final updates = fixture.container.read(
        libraryUpdateProgressProvider.notifier,
      );
      final generation = updates.begin();
      updates.report(
        generation,
        const LibraryUpdateProgress(
          requestedBooks: 4,
          processedBooks: 0,
          checkedBooks: 0,
          addedChapters: 0,
          skippedBooks: 0,
          failedBooks: 0,
          currentTitle: 'private title',
        ),
      );
      await _flush();
      expect(
        fixture.platform.updates.last.operation,
        ContinuedWorkOperation.backup,
      );
      fixture.queue.emit(DownloadQueueState(tasks: [_jobA], running: true));
      await _flush();
      expect(
        fixture.platform.updates.last.operation,
        ContinuedWorkOperation.backup,
      );
      await backup.record(
        const AutomaticBackupRunStatus(
          stage: AutomaticBackupRunStage.succeeded,
        ),
      );
      await _flush();
      final backupTerminal = fixture.platform.updates
          .where((v) => v.operation == ContinuedWorkOperation.backup)
          .last;
      expect((backupTerminal.completed, backupTerminal.total), (1, 1));
      expect(
        fixture.platform.updates.last.operation,
        ContinuedWorkOperation.downloads,
      );
      fixture.queue.emit(DownloadQueueState(), done: 1);
      await _flush();
      expect(
        fixture.platform.updates.last.operation,
        ContinuedWorkOperation.updates,
      );
      updates.report(
        generation,
        const LibraryUpdateProgress(
          requestedBooks: 4,
          processedBooks: 4,
          checkedBooks: 3,
          addedChapters: 17,
          skippedBooks: 0,
          failedBooks: 1,
        ),
      );
      updates.finish(generation);
      await _flush();
      final terminal = fixture.platform.updates
          .where((v) => v.operation == ContinuedWorkOperation.updates)
          .last;
      expect(
        (terminal.state, terminal.completed, terminal.total, terminal.failed),
        (ContinuedWorkState.failed, 4, 4, 1),
      );
    },
  );

  test(
    'deferred background presentation retries only on foreground lifecycle',
    () async {
      final fixture = await _fixture();
      fixture.platform.defer = true;
      fixture.queue.emit(DownloadQueueState(tasks: [_jobA], running: true));
      await _flush();
      final owner = fixture.container.read(continuedWorkCoordinatorProvider);
      expect(owner.driver.result.deferred, true);
      owner.didChangeAppLifecycleState(AppLifecycleState.paused);
      await _flush();
      expect(fixture.platform.updates.length, 1);
      fixture.platform.defer = false;
      owner.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await _flush();
      expect(fixture.platform.updates.length, 2);
      expect(
        fixture.platform.updates.last.sequence,
        greaterThan(fixture.platform.updates.first.sequence),
      );
      expect(owner.driver.result.visible, true);
    },
  );
}
