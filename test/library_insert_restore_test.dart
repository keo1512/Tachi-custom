import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:isar_community/isar.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tachi_books/features/library/data/document_importer.dart';
import 'package:tachi_books/features/library/data/library_mutation.dart';
import 'package:tachi_books/features/library/data/library_repository.dart';
import 'package:tachi_books/features/library/domain/library_book.dart';
import 'package:tachi_books/features/library/domain/library_reading.dart';
import 'package:tachi_books/features/library/presentation/library_view_model.dart';
import 'package:tachi_books/features/sources/data/source_repository.dart';
import 'package:tachi_books/features/sources/domain/catalogue.dart';

const item = CatalogueBook(
  ref: 'title',
  title: 'Original',
  sourceId: 'fixture',
  engine: SourceEngine.vbook,
  kind: ContentKind.novel,
);

class _PausedSource extends SourceRepository {
  _PausedSource() : super(tachimangaUrl: '', vbookUrl: '');
  final started = Completer<void>(), release = Completer<void>();
  @override
  Future<CatalogueBook> detail(CatalogueBook book) async {
    started.complete();
    await release.future;
    return book;
  }

  @override
  Future<List<CatalogueChapter>> chapters(CatalogueBook book) async => const [
    CatalogueChapter(ref: 'c1', title: 'One', index: 0),
  ];
}

class _PausedImport extends MemoryLibraryRepository {
  final started = Completer<void>(), release = Completer<void>();
  @override
  Future<LibraryBook> insertBook(
    LibraryBook book, {
    Map<int, ReaderContent> contents = const {},
    required int expectedRevision,
  }) async {
    started.complete();
    await release.future;
    return super.insertBook(
      book,
      contents: contents,
      expectedRevision: expectedRevision,
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final replace in [false, true]) {
    test(
      'source add pending before ${replace ? 'replacement' : 'another add'} preserves the existing title',
      () async {
        final repo = MemoryLibraryRepository(), source = _PausedSource();
        final container = ProviderContainer(
          overrides: [
            libraryRepositoryProvider.overrideWithValue(repo),
            sourceRepositoryProvider.overrideWithValue(source),
          ],
        );
        addTearDown(container.dispose);
        await container.read(libraryProvider.future);
        final pending = container
            .read(libraryProvider.notifier)
            .addFromSource(item);
        final rejected = replace
            ? expectLater(pending, throwsStateError)
            : null;
        await source.started.future;
        if (replace) await repo.clear();
        final restored = LibraryBook(
          id: sha256.convert(utf8.encode('vbook:fixture:title')).toString(),
          title: 'Keep restored',
          notes: 'Keep notes',
          progress: .5,
          bookmarks: ['0:0.5000'],
          chapters: const [
            BookChapter(id: 'c1', title: 'One', index: 0, read: true),
          ],
        );
        await repo.save(restored);
        final stable = (await repo.snapshot()).encode();
        source.release.complete();
        if (rejected != null) {
          await rejected;
        } else {
          expect((await pending).toJson(), restored.toJson());
        }
        expect((await repo.snapshot()).encode(), stable);
      },
    );
  }

  test(
    'document import cannot replace or delete a title restored during staging',
    () async {
      final repo = _PausedImport();
      final bytes = Uint8List.fromList(utf8.encode('Authored local text'));
      final pending = DocumentImporter().import('fixture.txt', bytes, repo);
      final rejected = expectLater(pending, throwsStateError);
      await repo.started.future;
      expect(await repo.list(), isEmpty);
      await repo.clear();
      final id = sha256.convert(bytes).toString();
      await repo.save(
        LibraryBook(
          id: id,
          title: 'Restored',
          chapters: const [
            BookChapter(
              id: 'restored-c',
              title: 'Restored chapter',
              index: 0,
              downloaded: true,
            ),
          ],
        ),
      );
      await repo.saveChapter(
        id,
        0,
        ReaderContent(kind: 'novel', html: '<p>Keep restored bytes</p>'),
      );
      final stable = (await repo.snapshot()).encode();
      repo.release.complete();
      await rejected;
      expect((await repo.snapshot()).encode(), stable);
    },
  );

  test(
    'new chapters stay unread when inserted before an inferred-read chapter',
    () {
      final legacy = LibraryBook(
        id: 'book',
        title: 'Legacy',
        currentChapter: 1,
        progress: .5,
        lastRead: DateTime.utc(2026),
        chapters: const [
          BookChapter(id: 'a', title: 'A', index: 0),
          BookChapter(id: 'b', title: 'B', index: 1),
          BookChapter(id: 'c', title: 'C', index: 2),
        ],
      );
      final change = remapChapterOrder(legacy, const [
        BookChapter(id: 'new', title: 'New', index: 0),
        BookChapter(id: 'a', title: 'A', index: 1),
        BookChapter(id: 'b', title: 'B', index: 2),
        BookChapter(id: 'c', title: 'C', index: 3),
      ]);
      expect(change.book.chapters.map((c) => c.read), [
        false,
        true,
        false,
        false,
      ]);
      expect(change.book.currentChapter, 2);
      expect(change.book.progress * 4 - 2, .5);
      expect(readChapterCount(change.book), 1);
      final completed = remapChapterOrder(
        legacy.copyWith(completed: true),
        change.book.chapters,
      );
      expect(completed.book.completed, isFalse);
      expect(completed.book.chapters.map((c) => c.read), [
        false,
        true,
        true,
        true,
      ]);
    },
  );

  test('marking a completed title chapter unread preserves all other read states and resume', () async {
    final repo = MemoryLibraryRepository();
    final book = LibraryBook(
      id: 'book',
      title: 'Finished',
      completed: true,
      currentChapter: 1,
      progress: .75,
      bookmarks: ['1:0.5000'],
      chapters: const [
        BookChapter(id: 'a', title: 'A', index: 0),
        BookChapter(id: 'b', title: 'B', index: 1),
      ],
    );
    await repo.save(book);
    final container = ProviderContainer(
      overrides: [libraryRepositoryProvider.overrideWithValue(repo)],
    );
    addTearDown(container.dispose);
    await container.read(libraryProvider.future);
    await container
        .read(libraryProvider.notifier)
        .markChapterRead('book', 'a', false);
    final result = (await repo.find('book'))!;
    expect(result.completed, isFalse);
    expect(result.chapters.map((c) => c.read), [false, true]);
    expect(result.currentChapter, book.currentChapter);
    expect(result.progress, book.progress);
    expect(result.bookmarks, book.bookmarks);
  });

  test(
    'preference insert keeps the full library unchanged on capacity failure',
    () async {
      SharedPreferences.setMockInitialValues({});
      final repo = await LibraryRepository.openWebPreview();
      await repo.save(LibraryBook(id: 'keep', title: 'Keep'));
      final before = (await repo.snapshot()).encode();
      await expectLater(
        repo.insertBook(
          LibraryBook(
            id: 'new',
            title: 'New',
            chapters: const [BookChapter(id: 'c', title: 'C', index: 0)],
          ),
          contents: {
            0: ReaderContent(kind: 'novel', html: 'x' * (5 * 1024 * 1024)),
          },
          expectedRevision: repo.replacementRevision,
        ),
        throwsFormatException,
      );
      expect((await repo.snapshot()).encode(), before);
      expect(await repo.readChapter('new', 0), isNull);
    },
  );

  test('legacy Suwayomi ordinal identities cannot silently remap offline data to new URLs', () async {
    final repo = MemoryLibraryRepository();
    final legacy = LibraryBook(
      id: 'legacy',
      title: 'Legacy',
      engine: 'tachimanga',
      sourceId: '123',
      sourceRef: '7',
      progress: .5,
      bookmarks: ['0:0.5000'],
      chapters: const [
        BookChapter(
          id: '1',
          title: 'Chapter 1',
          index: 1,
          read: true,
          downloaded: true,
        ),
      ],
    );
    await repo.save(legacy);
    await repo.saveChapter(
      legacy.id,
      0,
      ReaderContent(kind: 'novel', html: '<p>Keep original bytes</p>'),
    );
    final before = (await repo.snapshot()).encode();
    await expectLater(
      repo.updateChapterOrder(legacy, const [
        BookChapter(id: '/chapter/first', title: 'Chapter 1', index: 1),
      ], expectedRevision: repo.replacementRevision),
      throwsStateError,
    );
    expect((await repo.snapshot()).encode(), before);
  });

  test('manga resume movement freezes all legacy inferred read states before changing the position', () async {
    final repo = MemoryLibraryRepository();
    await repo.save(
      LibraryBook(
        id: 'legacy',
        title: 'Legacy',
        kind: 'manga',
        currentChapter: 2,
        progress: 2.5 / 3,
        lastRead: DateTime.utc(2026),
        chapters: const [
          BookChapter(id: 'a', title: 'A', index: 0),
          BookChapter(id: 'b', title: 'B', index: 1),
          BookChapter(id: 'c', title: 'C', index: 2),
        ],
      ),
    );
    final container = ProviderContainer(
      overrides: [libraryRepositoryProvider.overrideWithValue(repo)],
    );
    addTearDown(container.dispose);
    await container.read(libraryProvider.future);
    await container
        .read(libraryProvider.notifier)
        .updateProgress('legacy', 'a', 0, inferCompletionFromFraction: false);
    final result = (await repo.find('legacy'))!;
    expect(result.chapters.map((c) => c.read), [true, true, false]);
    expect(result.currentChapter, 0);
    expect(result.progress, 0);
  });

  final nativeLibrary = Platform.environment['TACHI_ISAR_TEST_LIBRARY'];
  test('native insertion is revision checked across shared handles and commits all chapters together', () async {
    await Isar.initializeIsarCore(libraries: {Abi.current(): nativeLibrary!});
    final directory = await Directory.systemTemp.createTemp(
      'tachibooks-insert-',
    );
    final first = await LibraryRepository.open(directoryPath: directory.path);
    final second = await LibraryRepository.open(directoryPath: directory.path);
    try {
      final revision = first.replacementRevision;
      await second.clear();
      final book = LibraryBook(
        id: 'new',
        title: 'New',
        chapters: const [
          BookChapter(id: 'c', title: 'C', index: 0, downloaded: true),
        ],
      );
      await expectLater(
        first.insertBook(
          book,
          contents: {0: ReaderContent(kind: 'novel', html: '<p>stale</p>')},
          expectedRevision: revision,
        ),
        throwsStateError,
      );
      expect(await second.find('new'), isNull);
      expect(await second.readChapter('new', 0), isNull);
      await first.insertBook(
        book,
        contents: {0: ReaderContent(kind: 'novel', html: '<p>complete</p>')},
        expectedRevision: first.replacementRevision,
      );
      expect((await second.find('new'))!.chapters.single.downloaded, isTrue);
      expect((await second.readChapter('new', 0))!.html, '<p>complete</p>');
    } finally {
      await first.close();
      await directory.delete(recursive: true);
    }
  }, skip: nativeLibrary == null ? 'Opt-in native Isar DLL.' : false);
}
