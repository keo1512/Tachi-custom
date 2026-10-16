import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tachi_books/features/library/data/backup_service.dart';
import 'package:tachi_books/features/library/data/document_importer.dart';
import 'package:tachi_books/features/library/data/library_repository.dart';
import 'package:tachi_books/features/library/domain/library_book.dart';
import 'package:tachi_books/features/library/domain/library_grouping.dart';
import 'package:tachi_books/features/library/domain/library_search.dart';
import 'package:tachi_books/features/library/presentation/library_filter_controller.dart';
import 'package:tachi_books/features/library/presentation/library_filter_sheet.dart';
import 'package:tachi_books/features/library/presentation/library_group_dialog.dart';
import 'package:tachi_books/features/settings/settings_controller.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('legacy category migration preserves membership and explicit moves remain compatible', () {
    final old = LibraryBook(
      id: 'legacy',
      title: 'Legacy',
      collection: 'Saved shelf',
    ).toJson()..remove('categories');
    final book = LibraryBook.fromJson(old);
    expect(book.collection, 'Saved shelf');
    expect(book.categories, ['Saved shelf']);
    final multiple = book.copyWith(
      categories: ['Saved shelf', 'Second shelf', 'Saved shelf'],
    );
    expect(multiple.categories, ['Saved shelf', 'Second shelf']);
    expect(multiple.copyWith(author: 'Author').categories, multiple.categories);
    expect(multiple.copyWith(collection: 'Moved').categories, ['Moved']);
    expect(multiple.copyWith(categories: []).categories, ['Mặc định']);
    expect(() => multiple.categories.add('Mutation'), throwsUnsupportedError);
    expect(LibraryBook.fromJson(multiple.toJson()).toJson(), multiple.toJson());
  });

  test('a title belongs to every selected category with independent author groups and search', () {
    final book = LibraryBook(
      id: 'b',
      title: 'Book',
      categories: ['Reading', 'Favorites'],
      author: 'Author',
    );
    final groups = libraryGroups([book, book], LibraryGrouping.collection);
    expect(groups.map((group) => group.label), ['Favorites', 'Reading']);
    expect(
      groups.every(
        (group) => group.bookIds.length == 1 && group.bookIds.contains('b'),
      ),
      isTrue,
    );
    expect(
      libraryGroups([book], LibraryGrouping.author).single.label,
      'Author',
    );
    expect(LibrarySearch('category:Favorites').matches(book), isTrue);
    expect(LibrarySearch('collection:Reading').matches(book), isTrue);
    expect(LibrarySearch('Favorites').matches(book), isTrue);
    expect(const LibraryFilter(category: 'Favorites').matches(book), isTrue);
  });

  test('three-state filters combine nonsequential read flags, downloaded pages, bookmarks and exact source', () {
    final book = LibraryBook(
      id: 'b',
      title: 'Book',
      engine: 'tachimanga',
      sourceId: '9007199254740995',
      chapters: const [
        BookChapter(id: '0', title: 'First', index: 0, read: true),
        BookChapter(
          id: '1',
          title: 'Second',
          index: 1,
          downloaded: true,
          read: false,
        ),
      ],
      bookmarks: ['1:0.5'],
    );
    const filter = LibraryFilter(
      unread: LibraryTriState.include,
      downloaded: LibraryTriState.include,
      bookmarked: LibraryTriState.include,
      source: 'tachimanga:9007199254740995',
    );
    expect(filter.matches(book), isTrue);
    expect(filter.copyWith(excludeSource: true).matches(book), isFalse);
    expect(
      filter.copyWith(source: 'vbook:other', excludeSource: true).matches(book),
      isTrue,
    );
    expect(
      filter.copyWith(downloaded: LibraryTriState.exclude).matches(book),
      isFalse,
    );
    expect(
      filter.copyWith(source: 'tachimanga:9007199254740994').matches(book),
      isFalse,
    );
    expect(
      filter.copyWith(favorite: LibraryTriState.include).matches(book),
      isFalse,
    );
    expect(
      filter.copyWith(favorite: LibraryTriState.exclude).matches(book),
      isTrue,
    );
    expect(
      filter
          .copyWith(unread: LibraryTriState.exclude)
          .matches(book.copyWith(completed: true)),
      isTrue,
    );
    expect(filter.active, isTrue);
  });

  test('sorting uses actual dates and chapter metadata while unknown dates remain unknown', () {
    final first = LibraryBook(
      id: 'a',
      title: 'A',
      createdAt: DateTime.utc(2025),
      lastUpdated: DateTime.utc(2026),
      chapters: [
        BookChapter(
          id: 'c',
          title: 'C',
          index: 0,
          uploadedAt: DateTime.utc(2024),
          read: true,
        ),
      ],
    );
    final second = LibraryBook(
      id: 'b',
      title: 'B',
      createdAt: DateTime.utc(2026),
      lastUpdated: DateTime.utc(2025),
      chapters: [
        BookChapter(
          id: 'c',
          title: 'C',
          index: 0,
          uploadedAt: DateTime.utc(2025),
          read: false,
        ),
      ],
    );
    final unknown = LibraryBook(id: 'z', title: 'Unknown');
    for (final order in [LibraryOrder.added, LibraryOrder.latest]) {
      final books = [unknown, first, second]
        ..sort(LibraryFilter(order: order).compare);
      expect(books.map((book) => book.id), ['b', 'a', 'z']);
    }
    expect(
      LibraryFilter(order: LibraryOrder.updated).compare(first, second),
      lessThan(0),
    );
    expect(
      LibraryFilter(order: LibraryOrder.read).compare(first, second),
      lessThan(0),
    );
    expect(
      LibraryFilter(order: LibraryOrder.unread).compare(first, second),
      greaterThan(0),
    );
    final random = const LibraryFilter(
      order: LibraryOrder.random,
      randomSeed: 123,
    );
    final before = [first, second, unknown]..sort(random.compare);
    final after = [unknown, second, first]..sort(random.compare);
    expect(after.map((book) => book.id), before.map((book) => book.id));
    expect(unknown.createdAt, isNull);
  });

  test('category sorting and display/filter settings survive restart and concurrent saves', () async {
    final preferences = await SharedPreferences.getInstance();
    final container = ProviderContainer(
      overrides: [preferencesProvider.overrideWithValue(preferences)],
    );
    addTearDown(container.dispose);
    final controller = container.read(libraryFilterProvider.notifier);
    await Future.wait([
      controller.save(
        const LibraryFilter(
          order: LibraryOrder.title,
          display: LibraryDisplay.list,
        ),
        grouping: LibraryGrouping.collection,
        groupKey: 'value:A',
      ),
      controller.save(
        const LibraryFilter(
          order: LibraryOrder.total,
          reverse: true,
          downloaded: LibraryTriState.exclude,
          showLocalBadge: true,
        ),
        grouping: LibraryGrouping.collection,
        groupKey: 'value:B',
      ),
    ]);
    container.invalidate(libraryFilterProvider);
    final saved = container.read(libraryFilterProvider);
    expect(
      saved.forGroup(LibraryGrouping.collection, 'value:A').order,
      LibraryOrder.title,
    );
    expect(
      saved.forGroup(LibraryGrouping.collection, 'value:B').order,
      LibraryOrder.total,
    );
    expect(
      saved.forGroup(LibraryGrouping.collection, 'value:B').reverse,
      isTrue,
    );
    expect(saved.filter.downloaded, LibraryTriState.exclude);
    expect(saved.filter.showLocalBadge, isTrue);
    expect(saved.sorts, hasLength(2));
    expect(
      saved.forGroup(LibraryGrouping.collection, 'value:A').downloaded,
      LibraryTriState.any,
    );
    expect(
      saved.forGroup(LibraryGrouping.collection, 'value:B').downloaded,
      LibraryTriState.exclude,
    );
  });

  test('new imports receive default categories while repeat imports retain prior membership and timestamps', () async {
    final repository = MemoryLibraryRepository();
    final bytes = utf8.encode('Offline novel content');
    final book = await DocumentImporter().import(
      'novel.txt',
      bytes,
      repository,
      defaultCategories: ['Reading', 'Author shelf'],
    );
    expect(book.categories, ['Reading', 'Author shelf']);
    expect(book.createdAt, isNotNull);
    await repository.mutateBook(
      book.id,
      (latest) => latest.copyWith(categories: ['Manual'], progress: .5),
    );
    final repeat = await DocumentImporter().import(
      'novel.txt',
      bytes,
      repository,
      defaultCategories: ['New defaults'],
    );
    expect(repeat.categories, ['Manual']);
    expect(repeat.progress, .5);
    expect(repeat.createdAt, book.createdAt);
    expect(
      (await repository.readChapter(book.id, 0))!.html,
      contains('Offline novel content'),
    );
  });

  test('scanlator matching uses provided chapter metadata and saved source exclusion retains exact IDs', () {
    final book = LibraryBook(
      id: 'b',
      title: 'B',
      chapters: const [
        BookChapter(id: 'c', title: 'C', index: 0, scanlator: 'Nhóm dịch A'),
      ],
    );
    const filter = LibraryFilter(
      scanlator: 'NHÓM DỊCH',
      source: 'tachimanga:9007199254740995',
      excludeSource: true,
    );
    expect(filter.matches(book), isTrue);
    expect(filter.copyWith(scanlator: 'Different').matches(book), isFalse);
    expect(filter.matches(book.copyWith(chapters: const [])), isFalse);
    expect(LibraryFilter.fromJson(filter.toJson()).toJson(), filter.toJson());
  });

  testWidgets(
    'filter sheet resets all active constraints and keeps scanner text editable',
    (tester) async {
      LibraryFilter? result;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: LibraryFilterSheet(
              value: const LibraryFilter(
                downloaded: LibraryTriState.exclude,
                source: 's',
                scanlator: 'Old',
              ),
              collections: const [],
              sources: const {'s': 'Source'},
              onChanged: (value) => result = value,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final scrollable = find
          .descendant(
            of: find.byType(ListView).first,
            matching: find.byType(Scrollable),
          )
          .first;
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('library-scanlator')),
        250,
        scrollable: scrollable,
      );
      await tester.enterText(
        find.byKey(const ValueKey('library-scanlator')),
        'New group',
      );
      await tester.pump();
      expect(result!.scanlator, 'New group');
      await tester.scrollUntilVisible(
        find.text('Đặt lại bộ lọc'),
        -250,
        scrollable: scrollable,
      );
      await tester.tap(find.text('Đặt lại bộ lọc'));
      await tester.pump();
      expect(result!.active, isFalse);
      expect(result!.scanlator, '');
      expect(tester.takeException(), isNull);
    },
  );

  test(
    'malformed saved filter is preserved instead of silently overwritten',
    () async {
      SharedPreferences.setMockInitialValues({
        LibraryFilterController.preferenceKey: '{bad',
      });
      final preferences = await SharedPreferences.getInstance();
      final container = ProviderContainer(
        overrides: [preferencesProvider.overrideWithValue(preferences)],
      );
      addTearDown(container.dispose);
      expect(container.read(libraryFilterProvider).filter.active, isFalse);
      await expectLater(
        container
            .read(libraryFilterProvider.notifier)
            .save(const LibraryFilter(), grouping: LibraryGrouping.collection),
        throwsFormatException,
      );
      expect(
        preferences.getString(LibraryFilterController.preferenceKey),
        '{bad',
      );
    },
  );

  test('invalid additive category/date/chapter metadata rejects before restore changes data', () async {
    for (final malformed in [
      {
        'categories': ['Valid', 3],
      },
      {
        'categories': [''],
      },
      {'createdAt': 'not-a-date'},
      {'readerPreferences': 'not-an-object'},
      {
        'chapters': [
          {'id': 'c', 'title': 'C', 'index': 0, 'uploadedAt': 'bad'},
        ],
      },
      {
        'chapters': [
          {'id': 'c', 'title': 'C', 'index': 0, 'number': 'bad'},
        ],
      },
    ]) {
      final repository = MemoryLibraryRepository();
      final book = LibraryBook(id: 'keep', title: 'Original');
      await repository.save(book);
      final before = (await repository.snapshot()).fingerprint;
      final envelope = jsonDecode(
        utf8.decode(await BackupService(repository).export()),
      ) as Map<String, dynamic>;
      (envelope['entries'][0]['book'] as Map).addAll(malformed);
      await expectLater(
        BackupService(repository).replace(
          utf8.encode(jsonEncode(envelope)),
          expectedFingerprint: before,
        ),
        throwsFormatException,
      );
      expect((await repository.snapshot()).fingerprint, before);
      expect(await repository.recoverySnapshot(), isNull);
    }
  });

  for (final width in [320.0, 430.0]) {
    testWidgets(
      'multi-category dialog chooses existing and new categories at $width',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = Size(width, 932);
        addTearDown(tester.view.reset);
        LibraryGroupEdit? result;
        await tester.pumpWidget(
          MaterialApp(
            home: Builder(
              builder: (context) => TextButton(
                onPressed: () async {
                  result = await showLibraryGroupDialog(
                    context,
                    books: [
                      LibraryBook(
                        id: 'b',
                        title: 'B',
                        categories: ['Existing'],
                      ),
                      LibraryBook(id: 'c', title: 'C', categories: ['Other']),
                    ],
                    selectedIds: {'b'},
                    grouping: LibraryGrouping.collection,
                  );
                },
                child: const Text('Open'),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Open'));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('multiple-categories')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('assign-category-Other')));
        await tester.enterText(
          find.byKey(const ValueKey('group-name')),
          'New category',
        );
        await tester.tap(find.text('Lưu'));
        await tester.pumpAndSettle();
        expect(result!.categories, ['Existing', 'Other', 'New category']);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
