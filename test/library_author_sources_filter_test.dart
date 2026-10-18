import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tachi_books/core/theme/app_theme.dart';
import 'package:tachi_books/features/library/data/backup_configuration.dart';
import 'package:tachi_books/features/library/data/library_repository.dart';
import 'package:tachi_books/features/library/domain/library_authors.dart';
import 'package:tachi_books/features/library/domain/library_book.dart';
import 'package:tachi_books/features/library/domain/library_grouping.dart';
import 'package:tachi_books/features/library/presentation/library_filter_controller.dart';
import 'package:tachi_books/features/library/presentation/library_filter_sheet.dart';
import 'package:tachi_books/features/library/presentation/library_screen.dart';
import 'package:tachi_books/features/library/presentation/library_view_model.dart';
import 'package:tachi_books/features/settings/settings_controller.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('author filtering matches exact names and explicit coauthors across sources', () {
    const filter = LibraryFilter(author: '  ANN   Lee  ');
    LibraryBook book(String author) =>
        LibraryBook(id: 'b', title: 'Book', author: author);
    for (final author in [
      'Ann Lee',
      'ANN  LEE',
      'Other; Ann Lee',
      'Ann Lee, Other',
      'Other\nAnn Lee',
    ]) {
      expect(filter.matches(book(author)), isTrue, reason: author);
    }
    for (final author in ['', 'Anna Lee', 'Ann Leeman', 'Other']) {
      expect(filter.matches(book(author)), isFalse, reason: author);
    }
    expect(libraryAuthorNames('Ann Lee; ANN  LEE; Other').length, 2);
    expect(filter.active, isTrue);
  });

  test('multiple sources use OR with engine identity; author and other filters use AND', () {
    final books = [
      LibraryBook(
        id: 'a',
        title: 'A',
        author: 'Ann',
        engine: 'tachimanga',
        sourceId: '9007199254740995',
        favorite: true,
      ),
      LibraryBook(
        id: 'b',
        title: 'B',
        author: 'Ann; Other',
        engine: 'vbook',
        sourceId: 'same',
        favorite: true,
      ),
      LibraryBook(
        id: 'c',
        title: 'C',
        author: 'Other',
        engine: 'vbook',
        sourceId: 'same',
        favorite: true,
      ),
      LibraryBook(
        id: 'd',
        title: 'D',
        author: 'Ann',
        engine: 'tachimanga',
        sourceId: 'same',
        favorite: true,
      ),
      LibraryBook(
        id: 'e',
        title: 'E',
        author: 'Ann',
        engine: 'tachimanga',
        sourceId: '9007199254740994',
        favorite: true,
      ),
      LibraryBook(
        id: 'f',
        title: 'F',
        author: 'Ann',
        engine: 'vbook',
        sourceId: 'same',
      ),
    ];
    const filter = LibraryFilter(
      sources: {'tachimanga:9007199254740995', 'vbook:same'},
      author: 'ann',
      favorite: LibraryTriState.include,
    );
    expect(books.where(filter.matches).map((book) => book.id), ['a', 'b']);
    expect(
      books
          .where(filter.copyWith(excludeSource: true).matches)
          .map((book) => book.id),
      ['d', 'e'],
    );
    expect(filter.copyWith(sources: {}).matches(books[3]), isTrue);
    expect(filter.copyWith(source: 'tachimanga:same').selectedSources, {
      'tachimanga:same',
    });
    expect(
      filter
          .copyWith(source: 'all', author: '', favorite: LibraryTriState.any)
          .active,
      isFalse,
    );
  });

  test('legacy single source migrates and new sets round trip without losing 64 bit identities', () {
    final old = LibraryFilter.fromJson({
      'source': 'tachimanga:9007199254740995',
      'excludeSource': true,
      'scanlator': 'Retired',
    });
    expect(old.selectedSources, {'tachimanga:9007199254740995'});
    expect(old.excludeSource, isTrue);
    final selected = {'vbook:9007199254740995', 'tachimanga:9007199254740995'};
    final next = old.copyWith(sources: selected, author: 'Ann');
    selected.clear();
    final loaded = LibraryFilter.fromJson(
      jsonDecode(jsonEncode(next.toJson())) as Map<String, dynamic>,
    );
    expect(loaded.selectedSources, hasLength(2));
    expect(loaded.author, 'ann');
    expect(loaded.excludeSource, isTrue);
    expect(() => loaded.selectedSources.clear(), throwsUnsupportedError);
    expect(
      LibraryFilter.fromJson({'sources': [], 'source': 'legacy'})
          .selectedSources,
      isEmpty,
    );
    expect(LibraryFilter.fromJson(old.toJson()).source, old.source);
    for (final value in [
      'source',
      [1],
      [''],
      ['all'],
      List.filled(10001, 'vbook:x'),
    ]) {
      expect(
        () => LibraryFilter.fromJson({'sources': value}),
        throwsFormatException,
      );
    }
    expect(
      () => LibraryFilter.fromJson({'author': 123}),
      throwsFormatException,
    );
  });

  test(
    'multi-source author presets survive restart and public backup validation',
    () async {
      final preferences = await SharedPreferences.getInstance();
      final container = ProviderContainer(
        overrides: [preferencesProvider.overrideWithValue(preferences)],
      );
      addTearDown(container.dispose);
      const filter = LibraryFilter(
        sources: {'tachimanga:a', 'vbook:b'},
        author: 'ann',
        excludeSource: true,
      );
      final controller = container.read(libraryFilterProvider.notifier);
      await controller.save(
        filter,
        grouping: LibraryGrouping.collection,
        groupKey: 'value:Manga',
      );
      await controller.savePreset('Author sources', filter);
      final config = BackupConfiguration.capture(preferences);
      expect(config.values, contains('libraryFilterV1'));
      final restarted = ProviderContainer(
        overrides: [preferencesProvider.overrideWithValue(preferences)],
      );
      addTearDown(restarted.dispose);
      final loaded = restarted.read(libraryFilterProvider);
      expect(
        loaded
            .forGroup(LibraryGrouping.collection, 'value:Manga')
            .selectedSources,
        filter.selectedSources,
      );
      expect(loaded.presets['Author sources']!.author, 'ann');
      expect(loaded.presets['Author sources']!.excludeSource, isTrue);
    },
  );

  for (final scale in [1.0, 1.5]) {
    testWidgets(
      'library filters fit iPhone 15 Pro Max and apply author plus multiple sources at scale $scale',
      (tester) async {
        tester.view.physicalSize = const Size(430, 932);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final preferences = await SharedPreferences.getInstance();
        final repository = MemoryLibraryRepository();
        for (final book in [
          LibraryBook(
            id: 'a',
            title: 'A',
            author: 'Ann',
            engine: 'tachimanga',
            sourceId: 'one',
            sourceName: 'Source A',
          ),
          LibraryBook(
            id: 'b',
            title: 'B',
            author: 'Ann; Other',
            engine: 'vbook',
            sourceId: 'two',
            sourceName: 'Source B',
          ),
          LibraryBook(
            id: 'c',
            title: 'C',
            author: 'Other',
            engine: 'vbook',
            sourceId: 'three',
            sourceName: 'Source C',
          ),
        ]) {
          await repository.save(book);
        }
        final before = (await repository.snapshot()).fingerprint;
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              preferencesProvider.overrideWithValue(preferences),
              libraryRepositoryProvider.overrideWithValue(repository),
            ],
            child: MaterialApp(
              theme: appTheme(Brightness.dark),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context).copyWith(
                  textScaler: TextScaler.linear(scale),
                  padding: const EdgeInsets.only(top: 59, bottom: 34),
                ),
                child: child!,
              ),
              home: const LibraryScreen(),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Lọc thư viện'));
        await tester.pumpAndSettle();
        final content = tester.state<ScrollableState>(
          find
              .descendant(
                of: find.byKey(const ValueKey('library-filter-options')),
                matching: find.byType(Scrollable),
              )
              .first,
        );
        expect(
          tester
              .getSize(find.byKey(const ValueKey('library-filter-sheet')))
              .height,
          lessThan(932 * .65),
        );
        await tester.scrollUntilVisible(
          find.byTooltip('Lọc Hoàn thành'),
          100,
          scrollable: find
              .descendant(
                of: find.byKey(const ValueKey('library-filter-options')),
                matching: find.byType(Scrollable),
              )
              .first,
        );
        await tester.pumpAndSettle();
        expect(find.byTooltip('Lọc Hoàn thành').hitTestable(), findsOneWidget);
        expect(find.text('Nhóm dịch'), findsNothing);
        await tester.scrollUntilVisible(
          find.text('Tác giả'),
          100,
          scrollable: find
              .descendant(
                of: find.byKey(const ValueKey('library-filter-options')),
                matching: find.byType(Scrollable),
              )
              .first,
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Tác giả'));
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(ListTile, 'Ann'));
        await tester.pumpAndSettle();
        await tester.scrollUntilVisible(
          find.byKey(const ValueKey('library-sources-filter')),
          -100,
          scrollable: find
              .descendant(
                of: find.byKey(const ValueKey('library-filter-options')),
                matching: find.byType(Scrollable),
              )
              .first,
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Nguồn truyện').first);
        await tester.pumpAndSettle();
        for (final key in ['tachimanga:one', 'vbook:two']) {
          await tester.tap(find.byKey(ValueKey('library-filter-option-$key')));
          await tester.pumpAndSettle();
        }
        await tester.tap(
          find.byKey(const ValueKey('library-filter-picker-apply')),
        );
        await tester.pumpAndSettle();
        expect(content.position.maxScrollExtent, greaterThan(0));
        await tester.ensureVisible(find.text('Loại trừ nguồn đã chọn'));
        await tester.pumpAndSettle();
        expect(
          find.text('Loại trừ nguồn đã chọn').hitTestable(),
          findsOneWidget,
        );
        await tester.tap(find.byTooltip('Đóng bộ lọc'));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('library-book-a')), findsOneWidget);
        expect(find.byKey(const ValueKey('library-book-b')), findsOneWidget);
        expect(find.byKey(const ValueKey('library-book-c')), findsNothing);
        expect((await repository.snapshot()).fingerprint, before);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
