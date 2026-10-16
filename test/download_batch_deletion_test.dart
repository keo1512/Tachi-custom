import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:isar_community/isar.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tachi_books/features/downloads/presentation/download_deletion_controller.dart';
import 'package:tachi_books/features/downloads/presentation/download_queue_controller.dart';
import 'package:tachi_books/features/library/data/library_mutation.dart';
import 'package:tachi_books/features/library/data/library_repository.dart';
import 'package:tachi_books/features/library/data/library_snapshot.dart';
import 'package:tachi_books/features/library/domain/library_book.dart';
import 'package:tachi_books/features/library/presentation/library_view_model.dart';
import 'package:tachi_books/features/settings/settings_controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  final native = Platform.environment['TACHI_ISAR_TEST_LIBRARY'];
  for (final store in ['memory', 'preferences', 'isar']) {
    test(
      '$store batch validates every title before atomic deletion and preserves local/bookmarked data',
      () async {
        final repo = await _open(store, native);
        final first = _book('first'),
            second = _book('second'),
            local = _book('local').copyWith(engine: 'local');
        try {
          for (final book in [first, second, local]) {
            await _cache(repo, book);
          }
          final revision = repo.replacementRevision;
          final before = (await repo.snapshot()).encode();
          await expectLater(
            repo.deleteDownloadedChaptersBatch([
              LibraryChapterDeletion(first, ['one']),
              LibraryChapterDeletion(second, ['missing']),
            ], expectedRevision: revision),
            throwsStateError,
          );
          expect((await repo.snapshot()).encode(), before);
          expect(repo.replacementRevision, revision);
          await expectLater(
            repo.deleteDownloadedChaptersBatch([
              LibraryChapterDeletion(first, ['one']),
              LibraryChapterDeletion(local, ['one']),
            ], expectedRevision: revision),
            throwsStateError,
          );
          expect((await repo.snapshot()).encode(), before);
          expect(
            await repo.deleteDownloadedChaptersBatch([
              LibraryChapterDeletion(first, ['one', 'two', 'three']),
              LibraryChapterDeletion(second, ['one', 'two', 'three']),
            ], expectedRevision: revision),
            4,
          );
          expect(repo.replacementRevision, revision + 1);
          for (final original in [first, second]) {
            final saved = (await repo.find(original.id))!;
            expect(saved.chapters.map((chapter) => chapter.downloaded), [
              false,
              true,
              false,
            ]);
            expect(saved.progress, original.progress);
            expect(saved.bookmarks, original.bookmarks);
            expect(await repo.readChapter(original.id, 0), isNull);
            expect(await repo.readChapter(original.id, 1), isNotNull);
            expect(await repo.readChapter(original.id, 2), isNull);
          }
          expect(
            (await repo.find(local.id))!.chapters
                .every((chapter) => chapter.downloaded),
            true,
          );
          expect(await repo.readChapter(local.id, 0), isNotNull);
          if (store == 'preferences') {
            final reopened = await LibraryRepository.openWebPreview();
            expect(
              (await reopened.snapshot()).encode(),
              (await repo.snapshot()).encode(),
            );
          }
        } finally {
          await _close(repo);
        }
      },
      skip: store == 'isar' && native == null
          ? 'Opt-in native Isar library.'
          : false,
    );

    test(
      '$store marking two titles read with automatic deletion is one batch',
      () async {
        final repo = await _open(store, native);
        final books = [
          _book('first'),
          _book('second'),
          _book('local').copyWith(engine: 'local'),
        ];
        final container = await _container(repo);
        try {
          for (final book in books) {
            await _cache(repo, book);
          }
          await container.read(libraryProvider.future);
          await container
              .read(downloadDeletionProvider.notifier)
              .update(afterManualRead: true);
          final revision = repo.replacementRevision;
          await container
              .read(libraryProvider.notifier)
              .markManyChaptersRead(
                {
                  for (final book in books) book.id: ['one', 'two', 'three'],
                },
                true,
                expectedRevision: revision,
              );
          expect(repo.replacementRevision, revision + 1);
          for (final book in books) {
            final saved = (await repo.find(book.id))!;
            expect(
              saved.chapters.every((chapter) => chapter.read == true),
              true,
            );
            expect(
              saved.chapters.map((chapter) => chapter.downloaded),
              book.engine == 'local'
                  ? [true, true, true]
                  : [false, true, false],
            );
            expect(saved.progress, book.progress);
            expect(saved.bookmarks, book.bookmarks);
          }
        } finally {
          container.dispose();
          await _close(repo);
        }
      },
      skip: store == 'isar' && native == null
          ? 'Opt-in native Isar library.'
          : false,
    );
  }

  test('native batch queued behind a shared-handle restore refuses the replacement before commit', () async {
    final repo = await _open('isar', native);
    try {
      final books = [_book('first'), _book('second')];
      for (final book in books) {
        await _cache(repo, book);
      }
      final snapshot = await repo.snapshot();
      final incoming = LibrarySnapshot([
        for (final entry in snapshot.entries)
          LibrarySnapshotEntry(
            entry.book.copyWith(title: 'Restored ${entry.book.title}'),
            entry.contents,
          ),
      ]);
      final other = await LibraryRepository.open(
        directoryPath: _directories[repo]!.path,
      );
      final revision = repo.replacementRevision;
      final restoring = other.replaceSnapshot(
        incoming,
        expectedFingerprint: snapshot.fingerprint,
      );
      final rejection = expectLater(
        repo.deleteDownloadedChaptersBatch([
          for (final book in books)
            LibraryChapterDeletion(book, ['one', 'three']),
        ], expectedRevision: revision),
        throwsStateError,
      );
      await restoring;
      await rejection;
      expect((await repo.snapshot()).encode(), incoming.encode());
    } finally {
      await _close(repo);
    }
  }, skip: native == null ? 'Opt-in native Isar library.' : false);

  for (final autoRead in [false, true]) {
    test(
      'restore while cancelling the first selected book rejects ${autoRead ? 'automatic' : 'manual'} batch deletion',
      () async {
        final repo = MemoryLibraryRepository();
        final books = [_book('first'), _book('second')];
        for (final book in books) {
          await _cache(repo, book);
        }
        final queue = _BlockedQueue();
        final container = await _container(repo, queue: queue);
        try {
          await container.read(libraryProvider.future);
          await container.read(downloadQueueProvider.notifier).enqueue(
            'first',
            ['one'],
          );
          await container.read(downloadQueueProvider.notifier).enqueue(
            'second',
            ['one'],
          );
          final queued = container
              .read(downloadQueueProvider)
              .tasks
              .map((task) => task.toJson())
              .toList();
          if (autoRead) {
            await container
                .read(downloadDeletionProvider.notifier)
                .update(afterManualRead: true);
          }
          final deletion = autoRead
              ? container
                    .read(libraryProvider.notifier)
                    .markManyChaptersRead(
                      {
                        for (final book in books) book.id: ['one'],
                      },
                      true,
                      expectedRevision: repo.replacementRevision,
                    )
              : container.read(downloadDeletionProvider.notifier).deleteMany([
                  for (final book in books)
                    LibraryChapterDeletion(book, ['one']),
                ], expectedRevision: repo.replacementRevision);
          final rejection = expectLater(deletion, throwsStateError);
          await queue.entered.future;
          await repo.clear();
          for (final book in books) {
            await _cache(repo, book.copyWith(title: 'Restored ${book.title}'));
          }
          final restored = (await repo.snapshot()).encode();
          queue.release.complete();
          await rejection;
          expect(queue.calls, 1);
          expect(
            container
                .read(downloadQueueProvider)
                .tasks
                .map((task) => task.toJson())
                .toList(),
            queued,
          );
          expect((await repo.snapshot()).encode(), restored);
        } finally {
          container.dispose();
        }
      },
    );
  }
}

class _BlockedQueue extends DownloadQueueController {
  final entered = Completer<void>(), release = Completer<void>();
  int calls = 0;
  @override
  Future<void> cancelMany(
    Iterable<String> identities, {
    int? expectedRevision,
    void Function()? guard,
  }) async {
    calls++;
    if (calls == 1) {
      entered.complete();
      await release.future;
    }
    await super.cancelMany(
      identities,
      expectedRevision: expectedRevision,
      guard: guard,
    );
  }
}

LibraryBook _book(String id) => LibraryBook(
  id: id,
  title: id,
  engine: 'tachimanga',
  kind: 'novel',
  sourceId: '2553532324170433933',
  sourceRef: '/$id',
  currentChapter: 1,
  progress: .4,
  bookmarks: ['1:.4'],
  chapters: const [
    BookChapter(
      id: 'one',
      title: 'One',
      index: 10,
      read: false,
      downloaded: true,
    ),
    BookChapter(
      id: 'two',
      title: 'Two',
      index: 11,
      read: false,
      downloaded: true,
    ),
    BookChapter(
      id: 'three',
      title: 'Three',
      index: 12,
      read: false,
      downloaded: true,
    ),
  ],
);
Future<void> _cache(LibraryRepository repo, LibraryBook book) async {
  await repo.save(book);
  for (var i = 0; i < book.chapters.length; i++) {
    await repo.saveChapter(
      book.id,
      i,
      ReaderContent(kind: 'novel', html: '<p>${book.id} $i</p>'),
    );
  }
}

final _directories = <LibraryRepository, Directory>{};
Future<LibraryRepository> _open(String store, String? native) async {
  if (store == 'memory') return MemoryLibraryRepository();
  if (store == 'preferences') return LibraryRepository.openWebPreview();
  await Isar.initializeIsarCore(
    libraries: {Abi.current(): native!},
    download: false,
  );
  final directory = await Directory.systemTemp.createTemp(
    'tachi-batch-delete-',
  );
  final repo = await LibraryRepository.open(directoryPath: directory.path);
  _directories[repo] = directory;
  return repo;
}

Future<void> _close(LibraryRepository repo) async {
  await repo.close();
  final dir = _directories.remove(repo);
  if (dir != null) await dir.delete(recursive: true);
}

Future<ProviderContainer> _container(
  LibraryRepository repo, {
  _BlockedQueue? queue,
}) async => ProviderContainer(
  overrides: [
    preferencesProvider.overrideWithValue(
      await SharedPreferences.getInstance(),
    ),
    libraryRepositoryProvider.overrideWithValue(repo),
    if (queue != null) downloadQueueProvider.overrideWith(() => queue),
  ],
);
