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

LibraryBook _book(String id, {String engine = 'vbook', int count = 3}) =>
    LibraryBook(
      id: id,
      title: id,
      engine: engine,
      sourceId: 'source',
      sourceRef: id,
      chapters: List.generate(
        count,
        (i) => BookChapter(
          id: 'chapter-$i',
          title: 'Chapter $i',
          index: i,
          read: false,
        ),
      ),
    );

class _CountingQueue extends DownloadQueueRepository {
  _CountingQueue(super.preferences);
  int saves = 0;
  bool failNext = false;
  @override
  Future<void> save(List<DownloadJob> tasks) async {
    saves++;
    if (failNext) {
      failNext = false;
      throw StateError('Injected persistence error');
    }
    await super.save(tasks);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('bulk enqueue skips local/offline chapters and deduplicates books and existing jobs durably', () async {
    final prefs = await SharedPreferences.getInstance(),
        repo = MemoryLibraryRepository();
    final a = _book('a'),
        b = _book('b'),
        local = _book('local', engine: 'local');
    await repo.save(
      a.copyWith(
        chapters: [
          a.chapters[0].copyWith(downloaded: true),
          ...a.chapters.skip(1),
        ],
      ),
    );
    await repo.save(b);
    await repo.save(local);
    final container = ProviderContainer(
      overrides: [
        preferencesProvider.overrideWithValue(prefs),
        libraryRepositoryProvider.overrideWithValue(repo),
      ],
    );
    addTearDown(container.dispose);
    final queue = container.read(downloadQueueProvider.notifier);
    await queue.enqueue('a', ['chapter-1']);
    expect(await queue.enqueueBooks([a, a, b, local]), 4);
    expect(await queue.enqueueBooks([a, b, local]), 0);
    final tasks = DownloadQueueRepository(prefs).load();
    expect(tasks.map((t) => '${t.bookId}/${t.chapterId}'), [
      'a/chapter-1',
      'a/chapter-2',
      'b/chapter-0',
      'b/chapter-1',
      'b/chapter-2',
    ]);
    expect(container.read(downloadQueueProvider).running, isFalse);
    final reopened = ProviderContainer(
      overrides: [preferencesProvider.overrideWithValue(prefs)],
    );
    addTearDown(reopened.dispose);
    expect(
      reopened.read(downloadQueueProvider).tasks.map((t) => t.identity),
      tasks.map((t) => t.identity),
    );
  });

  test('unread batch uses fresh independent flags rather than the selection snapshot or resume prefix', () async {
    final prefs = await SharedPreferences.getInstance(),
        repo = MemoryLibraryRepository();
    final selection = _book('a');
    await repo.save(
      selection.copyWith(
        currentChapter: 2,
        progress: .9,
        lastRead: DateTime.utc(2026),
        chapters: [
          selection.chapters[0].copyWith(read: false),
          selection.chapters[1].copyWith(read: true),
          selection.chapters[2].copyWith(read: false, downloaded: true),
        ],
      ),
    );
    final container = ProviderContainer(
      overrides: [
        preferencesProvider.overrideWithValue(prefs),
        libraryRepositoryProvider.overrideWithValue(repo),
      ],
    );
    addTearDown(container.dispose);
    expect(
      await container.read(downloadQueueProvider.notifier).enqueueBooks([
        selection,
      ], unreadOnly: true),
      1,
    );
    expect(
      container.read(downloadQueueProvider).tasks.single.chapterId,
      'chapter-0',
    );
  });

  test('large batch is one durable write and persistence failure leaves the prior queue untouched', () async {
    final prefs = await SharedPreferences.getInstance(),
        repo = MemoryLibraryRepository();
    final a = _book('a', count: 500), b = _book('b', count: 500);
    await repo.save(a);
    await repo.save(b);
    final container = ProviderContainer(
      overrides: [
        preferencesProvider.overrideWithValue(prefs),
        libraryRepositoryProvider.overrideWithValue(repo),
      ],
    );
    addTearDown(container.dispose);
    final queue = container.read(downloadQueueProvider.notifier);
    await queue.enqueue('keep', ['keep']);
    final persistence = _CountingQueue(prefs);
    queue.repository = persistence;
    final before = prefs.getString(DownloadQueueRepository.key);
    persistence.failNext = true;
    await expectLater(queue.enqueueBooks([a, b]), throwsStateError);
    expect(prefs.getString(DownloadQueueRepository.key), before);
    expect(container.read(downloadQueueProvider).tasks.single.bookId, 'keep');
    expect(await queue.enqueueBooks([a, b]), 1000);
    expect(
      persistence.saves,
      2,
      reason: 'One failed write plus one complete batch write, not one write per chapter.',
    );
    expect(DownloadQueueRepository(prefs).load().length, 1001);
  });

  test('bulk selection from before restore cannot change the queue', () async {
    final prefs = await SharedPreferences.getInstance(),
        repo = MemoryLibraryRepository();
    final book = _book('a');
    await repo.save(book);
    final revision = repo.replacementRevision;
    final container = ProviderContainer(
      overrides: [
        preferencesProvider.overrideWithValue(prefs),
        libraryRepositoryProvider.overrideWithValue(repo),
      ],
    );
    addTearDown(container.dispose);
    final queue = container.read(downloadQueueProvider.notifier);
    await queue.enqueue('keep', ['keep']);
    final before = prefs.getString(DownloadQueueRepository.key);
    await repo.clear();
    await repo.save(book);
    await expectLater(
      queue.enqueueBooks([book], expectedRevision: revision),
      throwsStateError,
    );
    expect(prefs.getString(DownloadQueueRepository.key), before);
    expect(container.read(downloadQueueProvider).tasks.single.bookId, 'keep');
  });

  test('queued batches retain concurrency/pause behavior and skip chapters completed by another download', () async {
    final prefs = await SharedPreferences.getInstance(),
        repo = MemoryLibraryRepository();
    final a = _book('a', count: 2), b = _book('b', count: 2);
    await repo.save(a);
    await repo.save(b);
    final calls = <String>[], release = Completer<void>();
    final container = ProviderContainer(
      overrides: [
        preferencesProvider.overrideWithValue(prefs),
        libraryRepositoryProvider.overrideWithValue(repo),
        downloadJobExecutorProvider.overrideWithValue((book, index) async {
          calls.add('${book.id}/${book.chapters[index].id}');
          await release.future;
        }),
      ],
    );
    addTearDown(container.dispose);
    final queue = container.read(downloadQueueProvider.notifier);
    expect(await queue.enqueueBooks([a, b]), 4);
    await queue.start();
    for (var i = 0; i < 30 && calls.length < 2; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(calls.length, 2);
    queue.pause();
    release.complete();
    for (
      var i = 0;
      i < 30 && container.read(downloadQueueProvider).tasks.length > 2;
      i++
    ) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(container.read(downloadQueueProvider).tasks.length, 2);
    expect(calls.length, 2);
    await repo.save(
      b.copyWith(
        chapters: b.chapters.map((c) => c.copyWith(downloaded: true)).toList(),
      ),
    );
    await queue.start();
    for (
      var i = 0;
      i < 30 && container.read(downloadQueueProvider).tasks.isNotEmpty;
      i++
    ) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(container.read(downloadQueueProvider).tasks, isEmpty);
    expect(
      calls.length,
      2,
      reason: 'Already completed offline chapters do not download again.',
    );
  });
}
