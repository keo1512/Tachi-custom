import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tachi_books/features/downloads/data/download_queue_repository.dart';
import 'package:tachi_books/features/downloads/presentation/download_queue_controller.dart';
import 'package:tachi_books/features/library/data/library_repository.dart';
import 'package:tachi_books/features/library/domain/library_book.dart';
import 'package:tachi_books/features/library/presentation/library_view_model.dart';
import 'package:tachi_books/features/settings/settings_controller.dart';

LibraryBook _book(String id, {int count = 3}) => LibraryBook(
  id: id,
  title: id,
  engine: 'vbook',
  sourceId: 'source',
  sourceRef: id,
  chapters: List.generate(
    count,
    (i) => BookChapter(id: '$i', title: 'Chapter $i', index: i, read: false),
  ),
);

Future<void> _until(bool Function() predicate) async {
  for (var i = 0; i < 100; i++) {
    if (predicate()) return;
    await Future<void>.delayed(Duration.zero);
  }
  fail('Queue did not reach the expected state');
}

class _DelayedFind extends MemoryLibraryRepository {
  Completer<void>? release;
  int finds = 0, blockAfter = 0;
  @override
  Future<LibraryBook?> find(String id) async {
    if (release != null && ++finds > blockAfter) await release!.future;
    return super.find(id);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(
    () => SharedPreferences.setMockInitialValues({'downloadConcurrency': 1}),
  );

  test('chapter and whole-book moves persist both directions and do not lose interleaved tasks', () async {
    final prefs = await SharedPreferences.getInstance();
    final container = ProviderContainer(
      overrides: [preferencesProvider.overrideWithValue(prefs)],
    );
    addTearDown(container.dispose);
    final controller = container.read(downloadQueueProvider.notifier);
    await controller.enqueue('a', ['0', '1']);
    await controller.enqueue('b', ['0']);
    await controller.enqueue('a', ['2']);
    await controller.enqueue('c', ['0']);
    String id(String book, String chapter) =>
        DownloadJob(bookId: book, chapterId: chapter).identity;
    await controller.moveBefore(id('a', '2'), id('a', '0'));
    expect(
      container.read(downloadQueueProvider).tasks.map((job) => job.identity),
      [id('a', '2'), id('a', '0'), id('a', '1'), id('b', '0'), id('c', '0')],
    );
    await controller.moveBookBefore('c', 'a');
    await controller.moveBookBefore('a', null);
    expect(DownloadQueueRepository(prefs).load().map((job) => job.identity), [
      id('c', '0'),
      id('b', '0'),
      id('a', '2'),
      id('a', '0'),
      id('a', '1'),
    ]);
    final before = prefs.getString(DownloadQueueRepository.key);
    await expectLater(
      controller.moveBefore(id('a', '0'), 'gone'),
      throwsStateError,
    );
    expect(prefs.getString(DownloadQueueRepository.key), before);
    final restarted = ProviderContainer(
      overrides: [preferencesProvider.overrideWithValue(prefs)],
    );
    addTearDown(restarted.dispose);
    expect(
      restarted.read(downloadQueueProvider).tasks.map((job) => job.identity),
      container.read(downloadQueueProvider).tasks.map((job) => job.identity),
    );
  });

  for (final oldFails in [false, true]) {
    test(
      'cancelled ${oldFails ? 'error' : 'completion'} cannot remove or retry a re-enqueued identical chapter',
      () async {
        final prefs = await SharedPreferences.getInstance(),
            repo = MemoryLibraryRepository();
        await repo.save(_book('a'));
        final releases = <Completer<void>>[],
            executions = <DownloadExecution>[];
        final container = ProviderContainer(
          overrides: [
            preferencesProvider.overrideWithValue(prefs),
            libraryRepositoryProvider.overrideWithValue(repo),
            guardedDownloadJobExecutorProvider.overrideWithValue((
              book,
              index,
              execution,
            ) async {
              executions.add(execution);
              final release = Completer<void>();
              releases.add(release);
              await release.future;
              if (oldFails && executions.indexOf(execution) == 0) {
                throw StateError('old HTTP');
              }
            }),
          ],
        );
        addTearDown(container.dispose);
        final controller = container.read(downloadQueueProvider.notifier);
        final identity = DownloadJob(bookId: 'a', chapterId: '0').identity;
        await controller.enqueue('a', ['0']);
        await controller.start();
        await _until(() => releases.length == 1);
        await controller.cancel(identity);
        expect(executions.first.isCancelled, isTrue);
        expect(DownloadQueueRepository(prefs).load(), isEmpty);
        await controller.enqueue('a', ['0']);
        expect(
          container.read(downloadQueueProvider).tasks.single.status,
          DownloadJobStatus.pending,
        );
        expect(
          releases,
          hasLength(1),
          reason: 'The old HTTP still occupies its execution slot.',
        );
        releases.first.complete();
        await _until(() => releases.length == 2);
        final fresh = container.read(downloadQueueProvider).tasks.single;
        expect(fresh.chapterId, '0');
        expect(fresh.status, DownloadJobStatus.active);
        expect(fresh.attempts, 0);
        expect(fresh.error, isNull);
        expect(executions.last.isCancelled, isFalse);
        releases.last.complete();
        await _until(() => container.read(downloadQueueProvider).tasks.isEmpty);
        expect((await repo.find('a'))!.progress, 0);
      },
    );
  }

  test('cancel one book stops its active signal and removes its pending jobs while another book continues', () async {
    final prefs = await SharedPreferences.getInstance(),
        repo = MemoryLibraryRepository();
    await repo.save(_book('a'));
    await repo.save(_book('b'));
    final first = Completer<void>(), second = Completer<void>();
    final calls = <String>[], signals = <DownloadExecution>[];
    final container = ProviderContainer(
      overrides: [
        preferencesProvider.overrideWithValue(prefs),
        libraryRepositoryProvider.overrideWithValue(repo),
        guardedDownloadJobExecutorProvider.overrideWithValue((
          book,
          index,
          execution,
        ) {
          calls.add('${book.id}/${book.chapters[index].id}');
          signals.add(execution);
          return book.id == 'a' ? first.future : second.future;
        }),
      ],
    );
    addTearDown(container.dispose);
    final controller = container.read(downloadQueueProvider.notifier);
    await controller.enqueue('a', ['0', '1', '2']);
    await controller.enqueue('b', ['0']);
    await controller.start();
    await _until(() => calls.length == 1);
    await controller.cancelBook('a');
    expect(signals.first.isCancelled, isTrue);
    expect(DownloadQueueRepository(prefs).load().map((job) => job.bookId), [
      'b',
    ]);
    first.complete();
    await _until(() => calls.length == 2);
    expect(calls, ['a/0', 'b/0']);
    await controller.cancelAll();
    expect(signals.last.isCancelled, isTrue);
    expect(DownloadQueueRepository(prefs).load(), isEmpty);
    second.complete();
    await _until(() => !container.read(downloadQueueProvider).running);
    expect(calls, hasLength(2));
  });

  test('download now promotes the selected whole book without preempting an active request', () async {
    final prefs = await SharedPreferences.getInstance(),
        repo = MemoryLibraryRepository();
    await repo.save(_book('a'));
    await repo.save(_book('b'));
    final releases = <Completer<void>>[], calls = <String>[];
    final container = ProviderContainer(
      overrides: [
        preferencesProvider.overrideWithValue(prefs),
        libraryRepositoryProvider.overrideWithValue(repo),
        downloadJobExecutorProvider.overrideWithValue((book, index) {
          calls.add('${book.id}/${book.chapters[index].id}');
          final release = Completer<void>();
          releases.add(release);
          return release.future;
        }),
      ],
    );
    addTearDown(container.dispose);
    final controller = container.read(downloadQueueProvider.notifier);
    await controller.enqueue('a', ['0', '1']);
    await controller.enqueue('b', ['0', '1']);
    await controller.start();
    await _until(() => calls.length == 1);
    await controller.downloadBookNow('b');
    expect(calls, ['a/0']);
    releases[0].complete();
    await _until(() => calls.length == 2);
    expect(calls, ['a/0', 'b/0']);
    controller.pause();
    releases[1].complete();
    await _until(() => container.read(downloadQueueProvider).tasks.length == 2);
    expect(
      DownloadQueueRepository(prefs)
          .load()
          .map((job) => '${job.bookId}/${job.chapterId}'),
      ['b/1', 'a/1'],
    );
  });

  test('download now retries one failed chapter and does not start a stale missing selection', () async {
    final prefs = await SharedPreferences.getInstance(),
        repo = MemoryLibraryRepository();
    await repo.save(_book('a'));
    const failed = DownloadJob(
      bookId: 'a',
      chapterId: '1',
      status: DownloadJobStatus.failed,
      attempts: 3,
      error: 'old',
    );
    await DownloadQueueRepository(prefs)
        .save([const DownloadJob(bookId: 'a', chapterId: '0'), failed]);
    final blocker = Completer<void>();
    final calls = <String>[];
    final container = ProviderContainer(
      overrides: [
        preferencesProvider.overrideWithValue(prefs),
        libraryRepositoryProvider.overrideWithValue(repo),
        downloadJobExecutorProvider.overrideWithValue((book, index) {
          calls.add(book.chapters[index].id);
          return blocker.future;
        }),
      ],
    );
    addTearDown(container.dispose);
    final controller = container.read(downloadQueueProvider.notifier);
    await controller.downloadNow('missing');
    expect(container.read(downloadQueueProvider).running, isFalse);
    expect(calls, isEmpty);
    await controller.downloadNow(failed.identity);
    await _until(() => calls.isNotEmpty);
    expect(calls, ['1']);
    expect(container.read(downloadQueueProvider).tasks.first.attempts, 0);
    expect(container.read(downloadQueueProvider).tasks.first.error, isNull);
    controller.pause();
    blocker.complete();
    await _until(() => container.read(downloadQueueProvider).tasks.length == 1);
  });

  test('next N reads fresh resume/read/download flags in fresh TOC order and leaves metadata untouched', () async {
    final prefs = await SharedPreferences.getInstance(),
        repo = MemoryLibraryRepository();
    final selection = _book('a', count: 7);
    final fresh = selection.copyWith(
      currentChapter: 2,
      progress: .4,
      bookmarks: ['2:.4'],
      chapters: [
        selection.chapters[6],
        selection.chapters[5],
        selection.chapters[2].copyWith(read: true),
        selection.chapters[1].copyWith(downloaded: true),
        selection.chapters[4],
        selection.chapters[3],
        selection.chapters[0],
      ],
    );
    await repo.save(fresh);
    final container = ProviderContainer(
      overrides: [
        preferencesProvider.overrideWithValue(prefs),
        libraryRepositoryProvider.overrideWithValue(repo),
      ],
    );
    addTearDown(container.dispose);
    final controller = container.read(downloadQueueProvider.notifier);
    expect(await controller.enqueueNext(selection, 2), 2);
    expect(
      container.read(downloadQueueProvider).tasks.map((job) => job.chapterId),
      ['4', '3'],
    );
    expect(await controller.enqueueNext(selection, 2), 0);
    expect((await repo.find('a'))!.toJson(), fresh.toJson());
    final local = fresh.copyWith(engine: 'local');
    await repo.save(local);
    expect(await controller.enqueueNext(local, 50), 0);
    await expectLater(controller.enqueueNext(local, 0), throwsArgumentError);
  });

  test(
    'next N rejects restore during lookup without altering the queue',
    () async {
      final prefs = await SharedPreferences.getInstance(),
          repo = _DelayedFind();
      final book = _book('a');
      await repo.save(book);
      final container = ProviderContainer(
        overrides: [
          preferencesProvider.overrideWithValue(prefs),
          libraryRepositoryProvider.overrideWithValue(repo),
        ],
      );
      addTearDown(container.dispose);
      final controller = container.read(downloadQueueProvider.notifier);
      await controller.enqueue('a', ['2']);
      final before = prefs.getString(DownloadQueueRepository.key);
      repo.release = Completer<void>();
      final pending = controller.enqueueNext(
        book,
        1,
        expectedRevision: repo.replacementRevision,
      );
      final rejected = expectLater(pending, throwsStateError);
      await repo.clear();
      await repo.save(book.copyWith(title: 'Restored'));
      repo.release!.complete();
      await rejected;
      expect(prefs.getString(DownloadQueueRepository.key), before);
    },
  );

  test('an execution captured before restore is refused before the executor dispatch', () async {
    final prefs = await SharedPreferences.getInstance(), repo = _DelayedFind();
    final book = _book('a');
    await repo.save(book);
    final calls = <String>[];
    final container = ProviderContainer(
      overrides: [
        preferencesProvider.overrideWithValue(prefs),
        libraryRepositoryProvider.overrideWithValue(repo),
        downloadJobExecutorProvider.overrideWithValue((book, index) async {
          calls.add(book.title);
        }),
      ],
    );
    addTearDown(container.dispose);
    final controller = container.read(downloadQueueProvider.notifier);
    await controller.enqueue('a', ['0', '1']);
    repo.blockAfter = 1; // Scheduler resolves source; execution lookup blocks.
    repo.release = Completer<void>();
    await controller.start();
    await _until(
      () =>
          container.read(downloadQueueProvider).tasks.first.status ==
          DownloadJobStatus.active,
    );
    await repo.clear();
    await repo.save(book.copyWith(title: 'Restored'));
    repo.release!.complete();
    await _until(
      () => container.read(downloadQueueProvider).tasks.first.attempts == 1,
    );
    expect(calls, isEmpty);
    expect(container.read(downloadQueueProvider).running, isFalse);
    expect(
      container.read(downloadQueueProvider).pauseReason,
      contains('khôi phục'),
    );
    expect(
      container.read(downloadQueueProvider).tasks.first.status,
      DownloadJobStatus.failed,
    );
    expect(
      container.read(downloadQueueProvider).tasks.last.status,
      DownloadJobStatus.pending,
    );
    await Future<void>.delayed(Duration.zero);
    expect(
      calls,
      isEmpty,
      reason: 'Neither retry nor the next pending task may automatically target restored books.',
    );
    expect((await repo.find('a'))!.title, 'Restored');
  });
}
