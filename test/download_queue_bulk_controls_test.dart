import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tachi_books/core/theme/app_theme.dart';
import 'package:tachi_books/features/downloads/data/download_queue_repository.dart';
import 'package:tachi_books/features/downloads/presentation/download_queue_controller.dart';
import 'package:tachi_books/features/downloads/presentation/downloads_screen.dart';
import 'package:tachi_books/features/library/data/library_repository.dart';
import 'package:tachi_books/features/library/domain/library_book.dart';
import 'package:tachi_books/features/library/presentation/library_view_model.dart';
import 'package:tachi_books/features/privacy/application/app_lock_controller.dart';
import 'package:tachi_books/features/settings/settings_controller.dart';

LibraryBook _book(String id) => LibraryBook(
  id: id,
  title: 'Truyện $id',
  engine: 'vbook',
  sourceId: id,
  sourceRef: id,
  chapters: [
    for (var index = 0; index < 3; index++)
      BookChapter(id: '$index', title: '$id chương $index', index: index),
  ],
);

String _id(String book, String chapter) =>
    DownloadJob(bookId: book, chapterId: chapter).identity;

class _Unlocked extends AppLockController {
  @override
  AppLockState build() => const AppLockState(initialized: true);
  @override
  Future<void> initialize() async {}
  void lock() => state = state.copyWith(locked: true);
  void markUnlocked() => state = state.copyWith(locked: false);
}

class _BlockedWrite extends DownloadQueueRepository {
  _BlockedWrite(super.preferences);
  final started = Completer<void>(), release = Completer<void>();
  bool block = true;
  @override
  Future<void> save(List<DownloadJob> tasks) async {
    if (block) {
      block = false;
      started.complete();
      await release.future;
    }
    await super.save(tasks);
  }
}

Future<void> _until(bool Function() check) async {
  for (var i = 0; i < 100; i++) {
    if (check()) return;
    await Future<void>.delayed(Duration.zero);
  }
  fail('Queue did not settle');
}

Future<
  ({
    ProviderContainer container,
    SharedPreferences prefs,
    MemoryLibraryRepository repo,
  })
>
_fixture({List<DownloadJob>? jobs, DownloadJobExecutor? executor}) async {
  final prefs = await SharedPreferences.getInstance();
  final repo = MemoryLibraryRepository();
  await repo.save(_book('a'));
  await repo.save(_book('b'));
  await DownloadQueueRepository(prefs).save(
    jobs ??
        [
          const DownloadJob(bookId: 'a', chapterId: '0'),
          const DownloadJob(
            bookId: 'a',
            chapterId: '1',
            status: DownloadJobStatus.paused,
          ),
          const DownloadJob(bookId: 'b', chapterId: '0'),
          const DownloadJob(
            bookId: 'b',
            chapterId: '1',
            status: DownloadJobStatus.failed,
            attempts: 3,
            error: 'HTTP 503',
          ),
        ],
  );
  final container = ProviderContainer(
    overrides: [
      preferencesProvider.overrideWithValue(prefs),
      libraryRepositoryProvider.overrideWithValue(repo),
      appLockProvider.overrideWith(_Unlocked.new),
      if (executor != null)
        downloadJobExecutorProvider.overrideWithValue(executor),
    ],
  );
  addTearDown(container.dispose);
  return (container: container, prefs: prefs, repo: repo);
}

Future<void> _show(
  WidgetTester tester,
  ProviderContainer container,
  double width,
) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = Size(width, 850);
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: appTheme(Brightness.dark),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(1.5)),
          child: child!,
        ),
        home: const DownloadsScreen(),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _picker(WidgetTester tester) async {
  await tester.tap(find.byTooltip('Quản lý nhiều tác vụ tải xuống'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Chọn nhiều chương để hủy tải'));
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(
    () => SharedPreferences.setMockInitialValues({'downloadConcurrency': 2}),
  );

  test('cancelMany removes only chosen identities across books in one write and survives restart', () async {
    final fixture = await _fixture();
    final queue = fixture.container.read(downloadQueueProvider.notifier);
    final before = (await fixture.repo.snapshot()).encode();
    await queue.cancelMany([
      _id('a', '0'),
      _id('b', '1'),
      _id('a', '0'),
    ], expectedRevision: fixture.repo.replacementRevision);
    final restored = DownloadQueueRepository(fixture.prefs).load();
    expect(restored.map((job) => job.identity), [_id('a', '1'), _id('b', '0')]);
    expect(restored.first.status, DownloadJobStatus.paused);
    expect((await fixture.repo.snapshot()).encode(), before);
  });

  test('cancelMany copies caller selection before queued write and does not target later edits', () async {
    final fixture = await _fixture();
    final queue = fixture.container.read(downloadQueueProvider.notifier);
    final blocked = _BlockedWrite(fixture.prefs);
    queue.repository = blocked;
    final first = queue.enqueue('a', ['2']);
    await blocked.started.future;
    final selected = <String>{_id('a', '0')};
    final pending = queue.cancelMany(selected);
    selected.clear();
    selected.add(_id('b', '0'));
    blocked.release.complete();
    await first;
    await pending;
    expect(
      DownloadQueueRepository(fixture.prefs).load().map((job) => job.identity),
      [_id('a', '1'), _id('b', '0'), _id('b', '1'), _id('a', '2')],
    );
  });

  test('stale restore or privacy guard refuses selected cancellation without poisoning storage', () async {
    final fixture = await _fixture();
    final queue = fixture.container.read(downloadQueueProvider.notifier);
    final revision = fixture.repo.replacementRevision;
    final raw = fixture.prefs.getString(DownloadQueueRepository.key);
    await fixture.repo.clear();
    await fixture.repo.save(_book('a'));
    await expectLater(
      queue.cancelMany([_id('a', '0')], expectedRevision: revision),
      throwsStateError,
    );
    await expectLater(
      queue.cancelMany([
        _id('b', '0'),
      ], guard: () => throw StateError('Locked')),
      throwsStateError,
    );
    expect(fixture.prefs.getString(DownloadQueueRepository.key), raw);
    expect(fixture.container.read(downloadQueueProvider).storageError, isNull);
  });

  test(
    'retry-all failed resets attempts while manually paused jobs remain paused',
    () async {
      final releases = <Completer<void>>[];
      final calls = <String>[];
      final fixture = await _fixture(
        jobs: [
          const DownloadJob(
            bookId: 'a',
            chapterId: '1',
            status: DownloadJobStatus.paused,
          ),
          const DownloadJob(
            bookId: 'b',
            chapterId: '1',
            status: DownloadJobStatus.failed,
            attempts: 3,
            error: 'old error',
          ),
        ],
        executor: (book, index) {
          calls.add('${book.id}/${book.chapters[index].id}');
          final release = Completer<void>();
          releases.add(release);
          return release.future;
        },
      );
      final queue = fixture.container.read(downloadQueueProvider.notifier);
      await queue.retry(expectedRevision: fixture.repo.replacementRevision);
      await _until(() => calls.isNotEmpty);
      expect(calls, ['b/1']);
      final tasks = fixture.container.read(downloadQueueProvider).tasks;
      expect(tasks.first.status, DownloadJobStatus.paused);
      expect(tasks.last.attempts, 0);
      expect(tasks.last.error, isNull);
      queue.pause();
      releases.single.complete();
      await _until(
        () => fixture.container.read(downloadQueueProvider).tasks.length == 1,
      );
      expect(
        DownloadQueueRepository(fixture.prefs).load().single.status,
        DownloadJobStatus.paused,
      );
    },
  );

  test(
    'retry-all rejects stale restore before resetting or dispatching',
    () async {
      var calls = 0;
      final fixture = await _fixture(executor: (_, _) async => calls++);
      final queue = fixture.container.read(downloadQueueProvider.notifier);
      final revision = fixture.repo.replacementRevision;
      final before = fixture.prefs.getString(DownloadQueueRepository.key);
      await fixture.repo.clear();
      await expectLater(
        queue.retry(expectedRevision: revision),
        throwsStateError,
      );
      expect(fixture.prefs.getString(DownloadQueueRepository.key), before);
      expect(calls, 0);
      expect(fixture.container.read(downloadQueueProvider).running, isFalse);
    },
  );

  for (final width in [320.0, 430.0]) {
    testWidgets(
      'bulk picker cancels arbitrary chapters from two books and preserves unchosen at $width',
      (tester) async {
        final fixture = await _fixture();
        await _show(tester, fixture.container, width);
        expect(find.textContaining('4 chương trong hàng đợi'), findsOneWidget);
        await _picker(tester);
        await tester.tap(
          find.byKey(ValueKey('cancel-download-${_id('a', '0')}')),
        );
        await tester.scrollUntilVisible(
          find.byKey(ValueKey('cancel-download-${_id('b', '1')}')),
          100,
          scrollable: find.byType(Scrollable).last,
        );
        await tester.tap(
          find.byKey(ValueKey('cancel-download-${_id('b', '1')}')),
        );
        await tester.pump();
        await tester.tap(find.text('Hủy tải 2 chương'));
        await tester.pumpAndSettle();
        expect(
          DownloadQueueRepository(fixture.prefs)
              .load()
              .map((job) => job.identity),
          [_id('a', '1'), _id('b', '0')],
        );
        expect(find.text('Đã hủy các tác vụ đã chọn'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final invalidation in ['restore', 'lock']) {
    testWidgets(
      'picker rejects stale $invalidation selection even after unlocking',
      (tester) async {
        final fixture = await _fixture();
        await _show(tester, fixture.container, 320);
        await _picker(tester);
        await tester.tap(find.text('Chọn tất cả'));
        await tester.pump();
        final raw = fixture.prefs.getString(DownloadQueueRepository.key);
        if (invalidation == 'restore') {
          await fixture.repo.clear();
          await fixture.repo.save(_book('a'));
        } else {
          final lock =
              fixture.container.read(appLockProvider.notifier) as _Unlocked;
          lock.lock();
          await tester.pump();
          lock.markUnlocked();
          await tester.pump();
        }
        await tester.tap(find.text('Hủy tải 4 chương'));
        await tester.pumpAndSettle();
        expect(fixture.prefs.getString(DownloadQueueRepository.key), raw);
        expect(
          fixture.container.read(downloadQueueProvider).storageError,
          isNull,
        );
        expect(
          find.textContaining(
            invalidation == 'restore' ? 'khôi phục' : 'mở khóa',
          ),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'explicit failed retry-all menu leaves paused chapters untouched',
    (tester) async {
      final release = Completer<void>();
      final calls = <String>[];
      final fixture = await _fixture(
        jobs: [
          const DownloadJob(
            bookId: 'a',
            chapterId: '1',
            status: DownloadJobStatus.paused,
          ),
          const DownloadJob(
            bookId: 'b',
            chapterId: '1',
            status: DownloadJobStatus.failed,
            attempts: 3,
          ),
        ],
        executor: (book, index) {
          calls.add('${book.id}/${book.chapters[index].id}');
          return release.future;
        },
      );
      await _show(tester, fixture.container, 320);
      await tester.tap(find.byTooltip('Quản lý nhiều tác vụ tải xuống'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Thử lại tất cả tác vụ thất bại'));
      for (var i = 0; i < 10 && calls.isEmpty; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(calls, ['b/1']);
      expect(
        fixture.container.read(downloadQueueProvider).tasks.first.status,
        DownloadJobStatus.paused,
      );
      fixture.container.read(downloadQueueProvider.notifier).pause();
      release.complete();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );
}
