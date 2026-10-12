import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tachi_books/features/downloads/presentation/download_queue_controller.dart';
import 'package:tachi_books/features/library/data/library_repository.dart';
import 'package:tachi_books/features/library/domain/library_book.dart';
import 'package:tachi_books/features/library/presentation/library_view_model.dart';
import 'package:tachi_books/features/settings/settings_controller.dart';

LibraryBook _book(String id, String source, {String engine = 'tachimanga'}) =>
    LibraryBook(
      id: id,
      title: id,
      engine: engine,
      sourceId: source,
      sourceRef: id,
      chapters: const [
        BookChapter(id: 'one', title: 'One', index: 0),
        BookChapter(id: 'two', title: 'Two', index: 1),
      ],
    );
Future<void> _until(bool Function() predicate) async {
  for (var i = 0; i < 100; i++) {
    if (predicate()) return;
    await Future<void>.delayed(Duration.zero);
  }
  fail('Expected source scheduler state');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(
    () => SharedPreferences.setMockInitialValues({'downloadConcurrency': 3}),
  );
  test('one active chapter per source across titles, while independent sources fill global slots', () async {
    final prefs = await SharedPreferences.getInstance(),
        repo = MemoryLibraryRepository();
    final books = [
      _book('a', '9223372036854775806'),
      _book('b', '9223372036854775806'),
      _book('c', '9223372036854775805'),
      _book('d', '9223372036854775806', engine: 'vbook'),
    ];
    for (final book in books) {
      await repo.save(book);
    }
    final calls = <String>[],
        releases = <String, Completer<void>>{},
        activeSources = <String>{};
    final container = ProviderContainer(
      overrides: [
        preferencesProvider.overrideWithValue(prefs),
        libraryRepositoryProvider.overrideWithValue(repo),
        downloadJobExecutorProvider.overrideWithValue((book, index) async {
          final key = '${book.engine}/${book.sourceId}',
              identity = '${book.id}/${book.chapters[index].id}';
          expect(
            activeSources.add(key),
            isTrue,
            reason: 'A source must never have two concurrent chapters.',
          );
          calls.add(identity);
          final release = Completer<void>();
          releases[identity] = release;
          await release.future;
          activeSources.remove(key);
        }),
      ],
    );
    addTearDown(container.dispose);
    final queue = container.read(downloadQueueProvider.notifier);
    await queue.enqueueBooks(books);
    await queue.start();
    await _until(() => calls.length == 3);
    expect(calls, ['a/one', 'c/one', 'd/one']);
    expect(
      calls,
      isNot(contains('b/one')),
      reason: 'Same source across two titles is still serialized.',
    );
    releases['a/one']!.complete();
    await _until(() => calls.length == 4);
    expect(
      calls.last,
      'a/two',
      reason: 'The source keeps queue order when its slot frees.',
    );
    releases['a/two']!.complete();
    await _until(() => calls.length == 5);
    expect(calls.last, 'b/one');
    queue.pause();
    releases['b/one']!.complete();
    releases['c/one']!.complete();
    releases['d/one']!.complete();
    await _until(() => container.read(downloadQueueProvider).tasks.length == 3);
    expect(activeSources, isEmpty);
    expect(
      container
          .read(downloadQueueProvider)
          .tasks
          .map((job) => '${job.bookId}/${job.chapterId}'),
      ['b/two', 'c/two', 'd/two'],
    );
  });

  test('cancelling one source does not free its slot until old HTTP ends, other sources continue', () async {
    final prefs = await SharedPreferences.getInstance(),
        repo = MemoryLibraryRepository();
    for (final book in [
      _book('a', 'same'),
      _book('b', 'same'),
      _book('c', 'other'),
    ]) {
      await repo.save(book);
    }
    final calls = <String>[], releases = <String, Completer<void>>{};
    final container = ProviderContainer(
      overrides: [
        preferencesProvider.overrideWithValue(prefs),
        libraryRepositoryProvider.overrideWithValue(repo),
        downloadJobExecutorProvider.overrideWithValue((book, index) {
          final id = '${book.id}/${book.chapters[index].id}';
          calls.add(id);
          return (releases[id] = Completer<void>()).future;
        }),
      ],
    );
    addTearDown(container.dispose);
    final queue = container.read(downloadQueueProvider.notifier);
    await queue.enqueue('a', ['one']);
    await queue.enqueue('b', ['one']);
    await queue.enqueue('c', ['one', 'two']);
    await queue.start();
    await _until(() => calls.length == 2);
    expect(calls, ['a/one', 'c/one']);
    await queue.cancelBook('a');
    releases['c/one']!.complete();
    await _until(() => calls.length == 3);
    expect(calls.last, 'c/two');
    expect(calls, isNot(contains('b/one')));
    releases['a/one']!.complete();
    await _until(() => calls.length == 4);
    expect(calls.last, 'b/one');
    queue.pause();
    releases['b/one']!.complete();
    releases['c/two']!.complete();
    await _until(() => container.read(downloadQueueProvider).tasks.isEmpty);
  });
}
