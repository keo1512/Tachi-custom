import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:isar_community/isar.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tachi_books/features/downloads/presentation/download_deletion_controller.dart';
import 'package:tachi_books/features/downloads/presentation/download_queue_controller.dart';
import 'package:tachi_books/features/library/data/attachment_store_native.dart';
import 'package:tachi_books/features/library/data/library_repository.dart';
import 'package:tachi_books/features/library/domain/library_book.dart';
import 'package:tachi_books/features/library/presentation/library_view_model.dart';
import 'package:tachi_books/features/settings/settings_controller.dart';

const _png =
    'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jf1kAAAAASUVORK5CYII=';
const _second =
    'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=';
LibraryBook _book() => LibraryBook(
  id: 'book',
  title: 'Remote',
  kind: 'manga',
  engine: 'tachimanga',
  sourceId: 'source',
  sourceRef: '/book',
  currentChapter: 2,
  progress: .7,
  bookmarks: ['1:0.25'],
  notes: 'Notes',
  chapters: const [
    BookChapter(
      id: 'read',
      title: 'Read',
      index: 100,
      downloaded: true,
      read: true,
    ),
    BookChapter(
      id: 'protected',
      title: 'Protected',
      index: 99,
      downloaded: true,
      read: true,
    ),
    BookChapter(
      id: 'unread',
      title: 'Unread',
      index: 3,
      downloaded: true,
      read: false,
    ),
  ],
);
Future<void> _cache(LibraryRepository repository, LibraryBook book) async {
  await repository.save(book);
  for (var i = 0; i < book.chapters.length; i++) {
    await repository.saveChapter(
      book.id,
      i,
      ReaderContent(kind: 'manga', images: [_png]),
    );
  }
}

Future<void> _until(bool Function() predicate) async {
  for (var i = 0; i < 150; i++) {
    if (predicate()) return;
    await Future<void>.delayed(Duration.zero);
  }
  fail('Expected deletion/queue state');
}

ProviderContainer _container(
  SharedPreferences preferences,
  LibraryRepository repo,
) => ProviderContainer(
  overrides: [
    preferencesProvider.overrideWithValue(preferences),
    libraryRepositoryProvider.overrideWithValue(repo),
  ],
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'reader disposal after provider disposal leaves offline content untouched',
    () async {
      final repository = MemoryLibraryRepository();
      final book = _book();
      await _cache(repository, book);
      final container = _container(
        await SharedPreferences.getInstance(),
        repository,
      );
      final controller = container.read(downloadDeletionProvider.notifier);
      await controller.update(afterReading: true);
      container.dispose();
      expect(
        await controller.deleteReadChapters(
          book,
          ['read'],
          event: DownloadDeletionEvent.readerLeft,
          expectedRevision: repository.replacementRevision,
        ),
        0,
      );
      expect((await repository.find(book.id))!.chapters.first.downloaded, true);
      expect(await repository.readChapter(book.id, 0), isNotNull);
    },
  );

  test('atomic delete preserves progress/read/bookmarks and protects bookmarked chapters in latest TOC positions', () async {
    final repo = MemoryLibraryRepository(), book = _book();
    await _cache(repo, book);
    final old = (await repo.openChapter(book.id, 'read'))!,
        revision = repo.replacementRevision;
    expect(
      await repo.deleteDownloadedChapters(book, [
        'read',
        'protected',
        'unread',
      ], expectedRevision: revision),
      2,
    );
    final saved = (await repo.find(book.id))!;
    expect(saved.chapters.map((chapter) => chapter.downloaded), [
      false,
      true,
      false,
    ]);
    expect(saved.progress, book.progress);
    expect(saved.currentChapter, book.currentChapter);
    expect(saved.bookmarks, book.bookmarks);
    expect(saved.notes, book.notes);
    expect(saved.chapters.map((chapter) => chapter.read), [true, true, false]);
    expect(await repo.readChapter(book.id, 0), isNull);
    expect(await repo.readChapter(book.id, 1), isNotNull);
    expect(repo.replacementRevision, revision + 1);
    await expectLater(
      repo.commitChapter(
        old,
        ReaderContent(kind: 'manga', images: [_png]),
        downloaded: true,
      ),
      throwsStateError,
    );
    expect(await repo.readChapter(book.id, 0), isNull);
    final now = repo.replacementRevision;
    expect(
      await repo.deleteDownloadedChapters(saved, [
        'protected',
      ], expectedRevision: now),
      0,
    );
    expect(
      repo.replacementRevision,
      now,
      reason: 'A protected/no-op deletion must not invalidate requests.',
    );
    expect(
      await repo.deleteDownloadedChapters(
        saved,
        ['protected'],
        expectedRevision: now,
        protectBookmarks: false,
      ),
      1,
    );
    expect((await repo.find(book.id))!.bookmarks, book.bookmarks);
  });

  test('deletion resolves latest stable IDs after TOC reorder and read-only mode uses independent flags', () async {
    final repo = MemoryLibraryRepository(), book = _book();
    await _cache(repo, book);
    await repo.updateChapterOrder(book, [
      book.chapters[2],
      book.chapters[1],
      book.chapters[0],
    ], expectedRevision: repo.replacementRevision);
    final fresh = (await repo.find(book.id))!;
    expect(
      await repo.deleteDownloadedChapters(
        book,
        ['read', 'protected', 'unread'],
        expectedRevision: repo.replacementRevision,
        readOnly: true,
      ),
      1,
    );
    expect(await repo.readChapter(book.id, 2), isNull);
    expect(await repo.readChapter(book.id, 0), isNotNull);
    expect(await repo.readChapter(book.id, 1), isNotNull);
    expect((await repo.find(book.id))!.currentChapter, fresh.currentChapter);
  });

  test('stale revision, local imported originals, mismatched source and unknown selection never delete bytes', () async {
    final repo = MemoryLibraryRepository(), book = _book();
    await _cache(repo, book);
    final before = (await repo.snapshot()).encode();
    await expectLater(
      repo.deleteDownloadedChapters(book, [
        'read',
        'gone',
      ], expectedRevision: repo.replacementRevision),
      throwsStateError,
    );
    await expectLater(
      repo.deleteDownloadedChapters(book.copyWith(sourceId: 'other'), [
        'read',
      ], expectedRevision: repo.replacementRevision),
      throwsStateError,
    );
    expect((await repo.snapshot()).encode(), before);
    final oldRevision = repo.replacementRevision;
    await repo.clear();
    await _cache(repo, book.copyWith(title: 'Restored'));
    final restored = (await repo.snapshot()).encode();
    await expectLater(
      repo.deleteDownloadedChapters(book, [
        'read',
      ], expectedRevision: oldRevision),
      throwsStateError,
    );
    expect((await repo.snapshot()).encode(), restored);
    final local = book.copyWith(engine: 'local');
    await _cache(repo, local);
    final imported = (await repo.snapshot()).encode();
    await expectLater(
      repo.deleteDownloadedChapters(local, [
        'read',
      ], expectedRevision: repo.replacementRevision),
      throwsStateError,
    );
    expect((await repo.snapshot()).encode(), imported);
  });

  test('automatic deletion policy defaults off, persists opt-in and separates leave/manual-read events', () async {
    final prefs = await SharedPreferences.getInstance(),
        repo = MemoryLibraryRepository(),
        book = _book();
    await _cache(repo, book);
    final container = _container(prefs, repo);
    addTearDown(container.dispose);
    final controller = container.read(downloadDeletionProvider.notifier);
    expect(container.read(downloadDeletionProvider).protectBookmarks, true);
    expect(
      await controller.deleteReadChapters(
        book,
        ['read'],
        event: DownloadDeletionEvent.readerLeft,
        expectedRevision: repo.replacementRevision,
      ),
      0,
    );
    expect(
      await controller.deleteReadChapters(
        book,
        ['read'],
        event: DownloadDeletionEvent.manuallyMarkedRead,
        expectedRevision: repo.replacementRevision,
      ),
      0,
    );
    await Future.wait([
      controller.update(afterReading: true),
      controller.update(afterManualRead: false),
    ]);
    expect(
      await controller.deleteReadChapters(
        book,
        ['read'],
        event: DownloadDeletionEvent.manuallyMarkedRead,
        expectedRevision: repo.replacementRevision,
      ),
      0,
    );
    expect(
      await controller.deleteReadChapters(
        book,
        ['read', 'protected', 'unread'],
        event: DownloadDeletionEvent.readerLeft,
        expectedRevision: repo.replacementRevision,
      ),
      1,
    );
    expect(
      (await repo.find(book.id))!.chapters.map((chapter) => chapter.downloaded),
      [false, true, true],
    );
    final restarted = _container(prefs, repo);
    addTearDown(restarted.dispose);
    expect(restarted.read(downloadDeletionProvider).afterReading, true);
    expect(restarted.read(downloadDeletionProvider).afterManualRead, false);
    expect(restarted.read(downloadDeletionProvider).protectBookmarks, true);
    await restarted
        .read(downloadDeletionProvider.notifier)
        .update(afterManualRead: true, protectBookmarks: false);
    expect(
      await restarted
          .read(downloadDeletionProvider.notifier)
          .deleteReadChapters(
            book,
            ['protected'],
            event: DownloadDeletionEvent.manuallyMarkedRead,
            expectedRevision: repo.replacementRevision,
          ),
      1,
    );
  });

  test('manual deletion cancels active+pending book jobs before invalidating late commit and pauses other restored-sensitive work', () async {
    final prefs = await SharedPreferences.getInstance(),
        repo = MemoryLibraryRepository(),
        book = _book();
    await _cache(repo, book);
    final incoming = book.copyWith(
      chapters: book.chapters
          .map((chapter) => chapter.copyWith(downloaded: false))
          .toList(),
    );
    await repo.save(incoming);
    final other = incoming.copyWith(id: 'other', sourceRef: '/other');
    await repo.save(other);
    final entered = Completer<void>(), release = Completer<void>();
    final container = ProviderContainer(
      overrides: [
        preferencesProvider.overrideWithValue(prefs),
        libraryRepositoryProvider.overrideWithValue(repo),
        guardedDownloadJobExecutorProvider.overrideWithValue((
          selection,
          index,
          execution,
        ) async {
          final read = (await repo.openChapter(
            selection.id,
            selection.chapters[index].id,
          ))!;
          entered.complete();
          await release.future;
          expect(execution.isCancelled, isTrue);
          await expectLater(
            repo.commitChapter(
              read,
              ReaderContent(kind: 'manga', images: [_second]),
              downloaded: true,
            ),
            throwsStateError,
          );
        }),
      ],
    );
    addTearDown(container.dispose);
    final queue = container.read(downloadQueueProvider.notifier);
    await queue.enqueue(book.id, ['read', 'unread']);
    await queue.enqueue(other.id, ['read']);
    await queue.start();
    await entered.future;
    expect(
      await container.read(downloadDeletionProvider.notifier).deleteChapters(
        incoming,
        ['read'],
        expectedRevision: repo.replacementRevision,
      ),
      1,
    );
    expect(container.read(downloadQueueProvider).tasks.single.bookId, other.id);
    expect(await repo.readChapter(book.id, 0), isNull);
    release.complete();
    await _until(() => !container.read(downloadQueueProvider).running);
    expect(container.read(downloadQueueProvider).tasks.single.bookId, other.id);
    expect(container.read(downloadQueueProvider).pauseReason, isNotNull);
    final restarted = _container(prefs, repo);
    addTearDown(restarted.dispose);
    expect(restarted.read(downloadQueueProvider).tasks.single.bookId, other.id);
    expect(restarted.read(downloadQueueProvider).running, false);
    expect(await repo.readChapter(book.id, 0), isNull);
    expect((await repo.find(book.id))!.notes, book.notes);
  });

  test('invalid bookmark protection refuses deletion, corrupted saved policy defaults safely off without overwriting raw', () async {
    final prefs = await SharedPreferences.getInstance(),
        repo = MemoryLibraryRepository();
    final book = _book().copyWith(bookmarks: ['invalid']);
    await _cache(repo, book);
    final before = (await repo.snapshot()).encode();
    await expectLater(
      repo.deleteDownloadedChapters(book, [
        'read',
      ], expectedRevision: repo.replacementRevision),
      throwsStateError,
    );
    expect((await repo.snapshot()).encode(), before);
    await prefs.setString(DownloadDeletionController.preferenceKey, 'broken');
    final container = _container(prefs, repo);
    addTearDown(container.dispose);
    expect(container.read(downloadDeletionProvider).afterReading, false);
    expect(container.read(downloadDeletionProvider).protectBookmarks, true);
    expect(prefs.getString(DownloadDeletionController.preferenceKey), 'broken');
  });

  final native = Platform.environment['TACHI_ISAR_TEST_LIBRARY'];
  test('native deletion removes exclusive files, retains shared/cover pages, and persists flags after restart with shared-handle CAS', () async {
    await Isar.initializeIsarCore(
      libraries: {Abi.current(): native!},
      download: false,
    );
    final dir = await Directory.systemTemp.createTemp('tachi-delete-native-');
    var repo = await LibraryRepository.open(directoryPath: dir.path);
    final book = _book().copyWith(cover: _png, bookmarks: []);
    try {
      await _cache(repo, book);
      await repo.saveChapter(
        book.id,
        0,
        ReaderContent(kind: 'manga', images: [_png, _second]),
      );
      final other = await LibraryRepository.open(directoryPath: dir.path);
      final old = (await other.openChapter(book.id, 'read'))!;
      Future<List<File>> files() async =>
          Directory('${dir.path}/attachments')
              .list(recursive: true)
              .where((entity) => entity is File)
              .cast<File>()
              .toList();
      expect(await files(), hasLength(2));
      expect(
        await repo.deleteDownloadedChapters(book, [
          'read',
        ], expectedRevision: repo.replacementRevision),
        1,
      );
      expect(
        await files(),
        hasLength(1),
        reason: 'Shared first page is cover and another chapter; only exclusive second page is removed.',
      );
      await expectLater(
        other.commitChapter(
          old,
          ReaderContent(kind: 'manga', images: [_second]),
          downloaded: true,
        ),
        throwsStateError,
      );
      expect(await files(), hasLength(1));
      expect((await other.readChapter(book.id, 1))!.images, [_png]);
      await repo.close();
      repo = await LibraryRepository.open(directoryPath: dir.path);
      expect(
        (await repo.find(book.id))!.chapters
            .map((chapter) => chapter.downloaded),
        [false, true, true],
      );
      expect(await repo.readChapter(book.id, 0), isNull);
      expect((await repo.find(book.id))!.cover, _png);
    } finally {
      await repo.close();
      await dir.delete(recursive: true);
    }
  }, skip: native == null ? 'Opt-in native Isar library.' : false);

  test('attachment cleanup rejects a foreign folder or traversal without deleting either valid file', () async {
    final dir = await Directory.systemTemp.createTemp('tachi-delete-files-');
    try {
      final store = await AttachmentStore.open(dir.path);
      final one = await store.store(
        'one',
        UriData.parse(_png).contentAsBytes(),
        'image/png',
      );
      final two = await store.store(
        'two',
        UriData.parse(_second).contentAsBytes(),
        'image/png',
      );
      await expectLater(
        store.removeUnreferenced('one', [one, two], []),
        throwsFormatException,
      );
      await expectLater(
        store.removeUnreferenced('one', [
          '${one.split('?').first}/../../victim',
        ], []),
        throwsFormatException,
      );
      expect(await store.resolve(one), _png);
      expect(await store.resolve(two), _second);
    } finally {
      await dir.delete(recursive: true);
    }
  });
}
