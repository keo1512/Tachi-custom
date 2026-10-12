import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tachi_books/features/library/data/backup_validation.dart';
import 'package:tachi_books/features/library/data/library_repository.dart';
import 'package:tachi_books/features/library/data/library_snapshot.dart';
import 'package:tachi_books/features/library/domain/chapter_list_options.dart';
import 'package:tachi_books/features/library/domain/library_book.dart';
import 'package:tachi_books/features/library/presentation/library_view_model.dart';
import 'package:tachi_books/features/settings/settings_controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'filters preserve canonical indices and unknown numbers never collapse',
    () {
      final book = fixture();
      expect(const ChapterListOptions(read: 'unread').indices(book), [1, 2, 3]);
      expect(const ChapterListOptions(bookmarked: 'yes').indices(book), [1]);
      expect(const ChapterListOptions(download: 'downloaded').indices(book), [
        0,
      ]);
      expect(const ChapterListOptions(scanlator: 'B').indices(book), [1]);
      expect(
        const ChapterListOptions(excludedScanlators: ['A']).indices(book),
        [1, 2, 3],
      );
      expect(
        const ChapterListOptions(
          hideDuplicates: true,
          preferredScanlator: 'B',
        ).indices(book),
        [1, 2, 3],
      );
      expect(const ChapterListOptions(hideDuplicates: true).indices(book), [
        0,
        2,
        3,
      ]);
      expect(
        const ChapterListOptions(
          sort: ChapterSort.number,
          descending: true,
        ).indices(book),
        [1, 0, 2, 3],
      );
      expect(duplicateChapterIndices(book), {0, 1});
    },
  );

  test('chapter list options roundtrip; legacy and malformed backups are handled explicitly', () {
    final repository = MemoryLibraryRepository();
    final validator = BackupValidator(repository);
    final options = const ChapterListOptions(
      read: 'unread',
      sort: ChapterSort.number,
      descending: true,
      hideDuplicates: true,
      preferredScanlator: 'A',
      excludedScanlators: ['B'],
    ).toJson();
    final book = fixture().copyWith(
      chapters: [
        for (final c in fixture().chapters) c.copyWith(downloaded: false),
      ],
      chapterListPreferences: options,
    );
    final json = LibrarySnapshot([LibrarySnapshotEntry(book, {})]).toJson();
    Uint8List encode() => Uint8List.fromList(utf8.encode(jsonEncode(json)));
    expect(
      validator
          .validateSnapshot(encode())
          .entries
          .single
          .book
          .chapterListPreferences,
      options,
    );
    final entry = (json['entries'] as List).single as Map;
    final data = entry['book'] as Map;
    data.remove('chapterListPreferences');
    expect(
      validator
          .validateSnapshot(encode())
          .entries
          .single
          .book
          .chapterListPreferences,
      isEmpty,
    );
    for (final invalid in <Object?>[
      null,
      [],
      'x',
      {'read': 'maybe'},
      {'sort': 3},
      {'descending': 1},
      {'preferredScanlator': false},
      {'scanlator': []},
      {
        'excludedScanlators': [2],
      },
    ]) {
      data['chapterListPreferences'] = invalid;
      expect(
        () => validator.validateSnapshot(encode()),
        throwsFormatException,
        reason: '$invalid',
      );
    }
  });

  test('batch chapter updates preserve unrelated metadata/cache and refuse stale editor', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final repo = MemoryLibraryRepository();
    await repo.save(fixture());
    await repo.saveChapter(
      'book',
      0,
      ReaderContent(kind: 'manga', images: ['data:image/png;base64,AQ==']),
    );
    final container = ProviderContainer(
      overrides: [
        libraryRepositoryProvider.overrideWithValue(repo),
        preferencesProvider.overrideWithValue(prefs),
      ],
    );
    addTearDown(container.dispose);
    await container.read(libraryProvider.future);
    final vm = container.read(libraryProvider.notifier);
    await vm.markChaptersRead('book', ['b', 'c'], true);
    await vm.setChapterBookmarks('book', ['c'], true);
    await vm.updateChapterListPreferences(
      'book',
      const ChapterListOptions(bookmarked: 'yes').toJson(),
    );
    var book = (await repo.find('book'))!;
    expect(book.chapters.map((c) => c.read), [true, true, true, false]);
    expect(book.bookmarks, ['1:0.5', '2:0.0000']);
    expect(book.notes, 'keep');
    expect((await repo.readChapter('book', 0))!.images, [
      'data:image/png;base64,AQ==',
    ]);
    await vm.resetBookReading('book');
    book = (await repo.find('book'))!;
    expect(book.chapters.every((c) => c.read == false), isTrue);
    expect(book.lastRead, isNull);
    expect(book.bookmarks, ['1:0.5', '2:0.0000']);
    final revision = repo.replacementRevision;
    await repo.clear();
    await repo.save(fixture().copyWith(notes: 'restored'));
    await expectLater(
      vm.setChapterBookmarks('book', ['a'], true, expectedRevision: revision),
      throwsStateError,
    );
    expect((await repo.find('book'))!.notes, 'restored');
    expect((await repo.find('book'))!.bookmarks, ['1:0.5']);
  });
}

LibraryBook fixture() => LibraryBook(
  id: 'book',
  title: 'Book',
  kind: 'manga',
  notes: 'keep',
  currentChapter: 1,
  progress: .3,
  lastRead: DateTime(2026, 10, 10),
  bookmarks: ['1:0.5'],
  chapters: const [
    BookChapter(
      id: 'a',
      title: 'Chapter 1 A',
      index: 0,
      number: 1,
      scanlator: 'A',
      downloaded: true,
      read: true,
    ),
    BookChapter(
      id: 'b',
      title: 'Chapter 1 B',
      index: 1,
      number: 1,
      scanlator: 'B',
      read: false,
    ),
    BookChapter(id: 'c', title: 'Special', index: 2, read: false),
    BookChapter(id: 'd', title: 'Special', index: 3, number: -1, read: false),
  ],
);
