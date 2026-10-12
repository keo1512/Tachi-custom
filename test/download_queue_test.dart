import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tachi_books/features/downloads/data/download_queue_repository.dart';
import 'package:tachi_books/features/downloads/presentation/download_queue_controller.dart';
import 'package:tachi_books/features/library/data/library_repository.dart';
import 'package:tachi_books/features/library/domain/library_book.dart';
import 'package:tachi_books/features/library/presentation/library_view_model.dart';
import 'package:tachi_books/features/settings/settings_controller.dart';
import 'package:tachi_books/features/sources/data/source_repository.dart';
import 'package:tachi_books/features/sources/domain/catalogue.dart';

LibraryBook _book([List<String> ids = const ['a', 'b', 'c']]) => LibraryBook(
  id: 'book',
  title: 'Queue fixture',
  engine: 'vbook',
  sourceRef: 'book-ref',
  sourceId: 'source',
  currentChapter: 1,
  progress: .5,
  bookmarks: const ['1:0.5000'],
  chapters: [
    for (var i = 0; i < ids.length; i++)
      BookChapter(id: ids[i], title: ids[i], index: i),
  ],
);

Future<void> _until(bool Function() condition) async {
  for (var attempt = 0; attempt < 50; attempt++) {
    if (condition()) return;
    await Future<void>.delayed(Duration.zero);
  }
  fail('Download queue did not reach the expected state');
}

class _QueueSource extends SourceRepository {
  _QueueSource() : super(tachimangaUrl: '', vbookUrl: 'http://localhost:4570');
  @override
  Future<ChapterContent> chapter(
    CatalogueBook book,
    CatalogueChapter chapter,
  ) async => ChapterContent(
    kind: ContentKind.novel,
    html: '<p>Offline ${chapter.ref}</p>',
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('queue deduplicates identities durably and starts paused', () async {
    final prefs = await SharedPreferences.getInstance();
    final container = ProviderContainer(
      overrides: [preferencesProvider.overrideWithValue(prefs)],
    );
    addTearDown(container.dispose);
    final controller = container.read(downloadQueueProvider.notifier);
    await Future.wait([
      controller.enqueue('book', ['a', 'b', 'a']),
      controller.enqueue('book', ['b', 'c']),
    ]);
    expect(
      container.read(downloadQueueProvider).tasks.map((job) => job.chapterId),
      ['a', 'b', 'c'],
    );
    expect(container.read(downloadQueueProvider).running, false);
    expect(DownloadQueueRepository(prefs).load().map((job) => job.chapterId), [
      'a',
      'b',
      'c',
    ]);
    expect(
      (jsonDecode(prefs.getString(DownloadQueueRepository.key)!)
          as Map)['version'],
      1,
    );
  });

  test(
    'pause finishes active jobs but leaves pending work durable for restart',
    () async {
      final prefs = await SharedPreferences.getInstance();
      final repo = MemoryLibraryRepository();
      await repo.save(_book());
      final calls = <String>[];
      final blockers = <String, Completer<void>>{};
      final container = ProviderContainer(
        overrides: [
          preferencesProvider.overrideWithValue(prefs),
          libraryRepositoryProvider.overrideWithValue(repo),
          downloadJobExecutorProvider.overrideWithValue((book, index) {
            final id = book.chapters[index].id;
            calls.add(id);
            return (blockers[id] = Completer<void>()).future;
          }),
        ],
      );
      addTearDown(container.dispose);
      final controller = container.read(downloadQueueProvider.notifier);
      await controller.enqueue('book', ['a', 'b', 'c']);
      await controller.start();
      await _until(() => calls.length == 1);
      expect(calls, ['a']);
      expect(
        DownloadQueueRepository(prefs)
            .load()
            .where((task) => task.status == DownloadJobStatus.pending)
            .length,
        3,
        reason: 'An interrupted active job must reload as pending.',
      );
      controller.pause();
      blockers['a']!.complete();
      await _until(
        () => container.read(downloadQueueProvider).tasks.length == 2,
      );
      expect(calls, ['a']);
      expect(container.read(downloadQueueProvider).running, false);
      final restarted = ProviderContainer(
        overrides: [preferencesProvider.overrideWithValue(prefs)],
      );
      addTearDown(restarted.dispose);
      expect(
        restarted
            .read(downloadQueueProvider)
            .tasks
            .map((task) => task.chapterId),
        ['b', 'c'],
      );
      expect(restarted.read(downloadQueueProvider).running, false);
    },
  );

  test(
    'job resolves original chapter identity against fresh reordered book',
    () async {
      final prefs = await SharedPreferences.getInstance();
      final repo = MemoryLibraryRepository();
      await repo.save(_book());
      final seen = <String>[];
      final container = ProviderContainer(
        overrides: [
          preferencesProvider.overrideWithValue(prefs),
          libraryRepositoryProvider.overrideWithValue(repo),
          downloadJobExecutorProvider.overrideWithValue((book, index) async {
            seen.add('${book.chapters[index].id}:$index');
          }),
        ],
      );
      addTearDown(container.dispose);
      final controller = container.read(downloadQueueProvider.notifier);
      await controller.enqueue('book', ['b']);
      await repo.save(_book(['c', 'a', 'b']));
      await controller.start();
      await _until(() => container.read(downloadQueueProvider).tasks.isEmpty);
      expect(seen, ['b:2']);
      expect((await repo.find('book'))!.chapters.map((chapter) => chapter.id), [
        'c',
        'a',
        'b',
      ]);
    },
  );

  test(
    'failed downloads retain errors and retry actual pending work',
    () async {
      final prefs = await SharedPreferences.getInstance();
      final repo = MemoryLibraryRepository();
      await repo.save(_book());
      var calls = 0;
      final container = ProviderContainer(
        overrides: [
          preferencesProvider.overrideWithValue(prefs),
          libraryRepositoryProvider.overrideWithValue(repo),
          downloadJobExecutorProvider.overrideWithValue((_, _) async {
            if (++calls <= 3) throw StateError('Network fixture unavailable');
          }),
        ],
      );
      addTearDown(container.dispose);
      final controller = container.read(downloadQueueProvider.notifier);
      await controller.enqueue('book', ['a']);
      await controller.start();
      await _until(
        () =>
            container.read(downloadQueueProvider).tasks.single.status ==
            DownloadJobStatus.failed,
      );
      expect(
        DownloadQueueRepository(prefs).load().single.error,
        contains('Network fixture unavailable'),
      );
      expect(calls, 3);
      expect(DownloadQueueRepository(prefs).load().single.attempts, 3);
      final reopened = DownloadQueueRepository(prefs).load();
      expect(reopened.single.status, DownloadJobStatus.failed);
      expect(reopened.single.attempts, 3);
      await controller.retry();
      await _until(() => container.read(downloadQueueProvider).tasks.isEmpty);
      expect(calls, 4);
      expect(DownloadQueueRepository(prefs).load(), isEmpty);
    },
  );

  test('a transient failure automatically retries and preserves the original chapter identity', () async {
    final prefs = await SharedPreferences.getInstance();
    final repo = MemoryLibraryRepository();
    await repo.save(_book());
    final calls = <String>[];
    final container = ProviderContainer(
      overrides: [
        preferencesProvider.overrideWithValue(prefs),
        libraryRepositoryProvider.overrideWithValue(repo),
        downloadJobExecutorProvider.overrideWithValue((book, index) async {
          calls.add(book.chapters[index].id);
          if (calls.length == 1) throw StateError('Transient failure');
        }),
      ],
    );
    addTearDown(container.dispose);
    final queue = container.read(downloadQueueProvider.notifier);
    await queue.enqueue('book', ['b']);
    await queue.start();
    await _until(
      () =>
          calls.length == 2 &&
          container.read(downloadQueueProvider).tasks.isEmpty,
    );
    expect(calls, ['b', 'b']);
    expect((await repo.find('book'))!.progress, .5);
    expect(DownloadQueueRepository(prefs).load(), isEmpty);
  });

  test('old queue entries default attempts to zero and invalid attempts preserve raw data', () async {
    final old = jsonEncode({
      'version': 1,
      'tasks': [
        {'bookId': 'book', 'chapterId': 'a', 'status': 'active'},
      ],
    });
    SharedPreferences.setMockInitialValues({DownloadQueueRepository.key: old});
    var prefs = await SharedPreferences.getInstance();
    final job = DownloadQueueRepository(prefs).load().single;
    expect(job.attempts, 0);
    expect(job.status, DownloadJobStatus.pending);
    for (final invalid in [-1, 4, 'three']) {
      final raw = jsonEncode({
        'version': 1,
        'tasks': [
          {
            'bookId': 'book',
            'chapterId': 'a',
            'status': 'failed',
            'attempts': invalid,
          },
        ],
      });
      SharedPreferences.setMockInitialValues({
        DownloadQueueRepository.key: raw,
      });
      prefs = await SharedPreferences.getInstance();
      expect(DownloadQueueRepository(prefs).load, throwsFormatException);
      expect(prefs.getString(DownloadQueueRepository.key), raw);
    }
  });

  test('malformed persisted queue is reported and never overwritten', () async {
    for (final raw in [
      '{"version":99,"tasks":[{"private":"retain"}]}',
      '{"tasks": malformed-json-retain}',
    ]) {
      SharedPreferences.setMockInitialValues({
        DownloadQueueRepository.key: raw,
      });
      final prefs = await SharedPreferences.getInstance();
      final container = ProviderContainer(
        overrides: [preferencesProvider.overrideWithValue(prefs)],
      );
      addTearDown(container.dispose);
      expect(
        container.read(downloadQueueProvider).storageError,
        contains('Dữ liệu gốc được giữ nguyên'),
      );
      expect(
        container.read(downloadQueueProvider).storageError,
        isNot(contains(raw)),
      );
      await expectLater(
        container.read(downloadQueueProvider.notifier).enqueue('book', ['a']),
        throwsStateError,
      );
      expect(prefs.getString(DownloadQueueRepository.key), raw);
    }
  });

  test('default executor downloads real repository content without moving reader progress', () async {
    final prefs = await SharedPreferences.getInstance();
    final repo = MemoryLibraryRepository();
    final original = _book();
    await repo.save(original);
    final source = _QueueSource();
    addTearDown(source.dispose);
    final container = ProviderContainer(
      overrides: [
        preferencesProvider.overrideWithValue(prefs),
        libraryRepositoryProvider.overrideWithValue(repo),
        sourceRepositoryProvider.overrideWithValue(source),
      ],
    );
    addTearDown(container.dispose);
    await container.read(libraryProvider.future);
    final controller = container.read(downloadQueueProvider.notifier);
    await controller.enqueue('book', ['c']);
    await controller.start();
    await _until(() => container.read(downloadQueueProvider).tasks.isEmpty);
    expect((await repo.readChapter('book', 2))!.html, '<p>Offline c</p>');
    final saved = (await repo.find('book'))!;
    expect(saved.chapters[2].downloaded, true);
    expect(saved.currentChapter, original.currentChapter);
    expect(saved.progress, original.progress);
    expect(saved.bookmarks, original.bookmarks);
  });
}
