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
import 'package:tachi_books/features/settings/settings_controller.dart';

String _id(String book, String chapter) =>
    DownloadJob(bookId: book, chapterId: chapter).identity;
LibraryBook _book(String id, {String? source}) => LibraryBook(
  id: id,
  title: 'Truyện $id',
  engine: 'vbook',
  sourceId: source ?? id,
  sourceRef: '/$id',
  chapters: const [
    BookChapter(id: '0', title: 'Chương 0', index: 0),
    BookChapter(id: '1', title: 'Chương 1', index: 1),
  ],
);
Future<void> _until(bool Function() condition) async {
  for (var attempt = 0; attempt < 150; attempt++) {
    if (condition()) return;
    await Future<void>.delayed(Duration.zero);
  }
  fail('Queue did not reach expected state');
}

Future<
  ({
    ProviderContainer container,
    MemoryLibraryRepository repo,
    SharedPreferences prefs,
  })
>
_open(
  GuardedDownloadJobExecutor executor, {
  int concurrency = 2,
  List<LibraryBook>? books,
}) async {
  SharedPreferences.setMockInitialValues({'downloadConcurrency': concurrency});
  final prefs = await SharedPreferences.getInstance(),
      repo = MemoryLibraryRepository();
  for (final book in books ?? [_book('a'), _book('b')]) {
    await repo.save(book);
  }
  final container = ProviderContainer(
    overrides: [
      preferencesProvider.overrideWithValue(prefs),
      libraryRepositoryProvider.overrideWithValue(repo),
      guardedDownloadJobExecutorProvider.overrideWithValue(executor),
    ],
  );
  addTearDown(container.dispose);
  await container.read(libraryProvider.future);
  return (container: container, repo: repo, prefs: prefs);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('active job pause retains identity and attempts through late completion; independent job continues', () async {
    final first = Completer<void>(), second = Completer<void>();
    final calls = <String>[], executions = <String, DownloadExecution>{};
    final f = await _open((book, index, execution) async {
      calls.add('${book.id}:$index');
      executions[book.id] = execution;
      await (book.id == 'a' ? first.future : second.future);
    });
    final queue = f.container.read(downloadQueueProvider.notifier);
    await queue.enqueue('a', ['0']);
    await queue.enqueue('b', ['0']);
    await queue.start();
    await _until(() => calls.length == 2);
    await queue.pauseJob(_id('a', '0'));
    expect(executions['a']!.isCancelled, true);
    expect(executions['b']!.isCancelled, false);
    expect(f.container.read(downloadQueueProvider).running, true);
    second.complete();
    await _until(
      () => f.container.read(downloadQueueProvider).tasks.length == 1,
    );
    first.complete();
    await _until(() => !f.container.read(downloadQueueProvider).running);
    final paused = f.container.read(downloadQueueProvider).tasks.single;
    expect(paused.identity, _id('a', '0'));
    expect(paused.status, DownloadJobStatus.paused);
    expect(paused.attempts, 0);
    expect(paused.error, null);
    expect(
      DownloadQueueRepository(f.prefs).load().single.status,
      DownloadJobStatus.paused,
    );
    expect(calls, ['a:0', 'b:0']);
  });

  test('policy start and retry do not resume manually paused jobs; explicit resume all does', () async {
    final calls = <String>[];
    final f = await _open(
      (book, index, _) async => calls.add('${book.id}:$index'),
    );
    final queue = f.container.read(downloadQueueProvider.notifier);
    await queue.enqueue('a', ['0', '1']);
    await queue.pauseJob(_id('a', '0'));
    await queue.start();
    await _until(() => !f.container.read(downloadQueueProvider).running);
    expect(calls, ['a:1']);
    await queue.retry();
    await _until(() => !f.container.read(downloadQueueProvider).running);
    expect(calls, ['a:1']);
    expect(
      DownloadQueueRepository(f.prefs).load().single.status,
      DownloadJobStatus.paused,
    );
    await queue.resumeAll();
    await _until(() => f.container.read(downloadQueueProvider).tasks.isEmpty);
    expect(calls, ['a:1', 'a:0']);
  });

  test('single resume when whole queue stopped keeps other waiting jobs paused durably', () async {
    final calls = <String>[];
    final f = await _open(
      (book, index, _) async => calls.add('${book.id}:$index'),
    );
    final queue = f.container.read(downloadQueueProvider.notifier);
    await queue.enqueue('a', ['0', '1']);
    await queue.enqueue('b', ['0']);
    await queue.pauseJob(_id('a', '0'));
    await queue.resumeJob(_id('a', '0'));
    await _until(() => !f.container.read(downloadQueueProvider).running);
    expect(calls, ['a:0']);
    expect(
      DownloadQueueRepository(f.prefs).load().map((job) => job.status),
      everyElement(DownloadJobStatus.paused),
    );
    final reopened = ProviderContainer(
      overrides: [preferencesProvider.overrideWithValue(f.prefs)],
    );
    addTearDown(reopened.dispose);
    expect(
      reopened.read(downloadQueueProvider).tasks.map((job) => job.identity),
      [_id('a', '1'), _id('b', '0')],
    );
    expect(
      reopened.read(downloadQueueProvider).tasks.map((job) => job.status),
      everyElement(DownloadJobStatus.paused),
    );
    await queue.resumeAll();
    await _until(() => f.container.read(downloadQueueProvider).tasks.isEmpty);
    expect(calls.toSet(), {'a:0', 'a:1', 'b:0'});
  });

  test(
    'resume during old HTTP cannot overlap physical concurrency or same source',
    () async {
      final releases = <Completer<void>>[], executions = <DownloadExecution>[];
      var inflight = 0, maximum = 0;
      final f = await _open(
        (book, index, execution) async {
          executions.add(execution);
          final release = Completer<void>();
          releases.add(release);
          inflight++;
          maximum = inflight > maximum ? inflight : maximum;
          await release.future;
          inflight--;
          if (executions.indexOf(execution) == 0) {
            throw StateError('late old HTTP');
          }
        },
        concurrency: 1,
        books: [
          _book('a'),
          _book('b', source: 'a'),
        ],
      );
      final queue = f.container.read(downloadQueueProvider.notifier);
      await queue.enqueue('a', ['0']);
      await queue.enqueue('b', ['0']);
      await queue.start();
      await _until(() => releases.length == 1);
      await queue.pauseJob(_id('a', '0'));
      await queue.resumeJob(_id('a', '0'));
      for (var i = 0; i < 10; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(releases.length, 1);
      releases[0].complete();
      await _until(() => releases.length == 2);
      expect(f.container.read(downloadQueueProvider).tasks.first.attempts, 0);
      releases[1].complete();
      await _until(() => releases.length == 3);
      releases[2].complete();
      await _until(() => f.container.read(downloadQueueProvider).tasks.isEmpty);
      expect(maximum, 1);
      expect(executions.first.isCancelled, true);
    },
  );

  for (final width in [320.0, 430.0]) {
    testWidgets(
      'per chapter menu pauses and resumes while retaining other pending jobs at $width',
      (tester) async {
        final calls = <String>[];
        final f = await _open(
          (book, index, _) async => calls.add('${book.id}:$index'),
        );
        final queue = f.container.read(downloadQueueProvider.notifier);
        await queue.enqueue('a', ['0', '1']);
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = Size(width, 850);
        addTearDown(tester.view.reset);
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: f.container,
            child: MaterialApp(
              theme: appTheme(Brightness.dark),
              home: const DownloadsScreen(),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Truyện a'));
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Tùy chọn chương 0'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Tạm dừng chương'));
        await tester.pumpAndSettle();
        expect(find.text('Đã tạm dừng'), findsOneWidget);
        expect(calls, isEmpty);
        await tester.tap(find.byTooltip('Tùy chọn chương 0'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Tiếp tục chương'));
        await tester.pumpAndSettle();
        expect(calls, ['a:0']);
        expect(
          DownloadQueueRepository(f.prefs).load().single.status,
          DownloadJobStatus.paused,
        );
        expect(tester.takeException(), null);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
}
