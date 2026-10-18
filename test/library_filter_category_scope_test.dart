import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tachi_books/core/theme/app_theme.dart';
import 'package:tachi_books/features/library/data/library_repository.dart';
import 'package:tachi_books/features/library/domain/library_book.dart';
import 'package:tachi_books/features/library/domain/library_grouping.dart';
import 'package:tachi_books/features/library/presentation/library_filter_controller.dart';
import 'package:tachi_books/features/library/presentation/library_filter_sheet.dart';
import 'package:tachi_books/features/library/presentation/library_screen.dart';
import 'package:tachi_books/features/library/presentation/library_view_model.dart';
import 'package:tachi_books/features/settings/settings_controller.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<ProviderContainer> mount(
    WidgetTester tester,
    SharedPreferences preferences,
    MemoryLibraryRepository repository,
  ) async {
    tester.view.physicalSize = const Size(430, 932);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          preferencesProvider.overrideWithValue(preferences),
          libraryRepositoryProvider.overrideWithValue(repository),
        ],
        child: MaterialApp(
          theme: appTheme(Brightness.dark),
          home: const LibraryScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return ProviderScope.containerOf(
      tester.element(find.byType(LibraryScreen)),
    );
  }

  Future<void> openSourcePicker(WidgetTester tester) async {
    await tester.ensureVisible(
      find.byKey(const ValueKey('library-sources-filter')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('library-sources-filter')));
    await tester.pumpAndSettle();
  }

  Future<void> selectSource(WidgetTester tester, String key) async {
    await tester.tap(find.byKey(ValueKey('library-filter-option-$key')));
    await tester.pumpAndSettle();
  }

  Future<void> applySources(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('library-filter-picker-apply')));
    await tester.pumpAndSettle();
  }

  Future<MemoryLibraryRepository> library() async {
    final repository = MemoryLibraryRepository();
    for (final book in [
      LibraryBook(
        id: 'a',
        title: 'Manga A',
        engine: 'tachimanga',
        sourceId: 'one',
        sourceName: 'Source One',
        author: 'Ann',
        categories: ['Manga'],
      ),
      LibraryBook(
        id: 'b',
        title: 'Manga B',
        engine: 'tachimanga',
        sourceId: 'two',
        sourceName: 'Source Two',
        author: 'Binh',
        categories: ['Manga'],
      ),
      LibraryBook(
        id: 'c',
        title: 'Novel C',
        engine: 'vbook',
        sourceId: 'three',
        sourceName: 'Source Three',
        author: 'Chi',
        categories: ['Novel'],
      ),
    ]) {
      await repository.save(book);
    }
    return repository;
  }

  for (final legacy in [false, true]) {
    testWidgets(
      'replacing selected source stays applied after closing and restart legacy=$legacy',
      (tester) async {
        final preferences = await SharedPreferences.getInstance();
        final repository = await library();
        final fingerprint = (await repository.snapshot()).fingerprint;
        if (legacy) {
          await preferences.setString(
            LibraryFilterController.preferenceKey,
            jsonEncode({
              'filter': {'source': 'tachimanga:one'},
              'sorts': {
                LibraryFilterPreferences.scope(
                  LibraryGrouping.collection,
                  'value:Manga',
                ): {
                  'source': 'tachimanga:one',
                },
              },
            }),
          );
        }
        final container = await mount(tester, preferences, repository);
        await tester.tap(find.byTooltip('Lọc thư viện'));
        await tester.pumpAndSettle();
        if (!legacy) {
          await openSourcePicker(tester);
          await selectSource(tester, 'tachimanga:one');
          await applySources(tester);
        }
        await openSourcePicker(tester);
        await selectSource(tester, 'tachimanga:two');
        await selectSource(tester, 'tachimanga:one');
        await applySources(tester);
        expect(
          container
              .read(libraryFilterProvider)
              .forGroup(LibraryGrouping.collection, 'value:Manga')
              .selectedSources,
          {'tachimanga:two'},
        );
        await tester.tap(find.byTooltip('Đóng bộ lọc'));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('library-book-a')), findsNothing);
        expect(find.byKey(const ValueKey('library-book-b')), findsOneWidget);
        await tester.tap(find.byTooltip('Lọc thư viện'));
        await tester.pumpAndSettle();
        await openSourcePicker(tester);
        expect(
          tester
              .widget<CheckboxListTile>(
                find.byKey(
                  const ValueKey('library-filter-option-tachimanga:one'),
                ),
              )
              .value,
          false,
        );
        expect(
          tester
              .widget<CheckboxListTile>(
                find.byKey(
                  const ValueKey('library-filter-option-tachimanga:two'),
                ),
              )
              .value,
          true,
        );
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        final restarted = await mount(tester, preferences, repository);
        expect(
          restarted
              .read(libraryFilterProvider)
              .forGroup(LibraryGrouping.collection, 'value:Manga')
              .selectedSources,
          {'tachimanga:two'},
        );
        expect(find.byKey(const ValueKey('library-book-b')), findsOneWidget);
        expect((await repository.snapshot()).fingerprint, fingerprint);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'source and author options use current category regardless of filters',
    (tester) async {
      final preferences = await SharedPreferences.getInstance();
      final repository = await library();
      final container = await mount(tester, preferences, repository);
      await container
          .read(libraryFilterProvider.notifier)
          .save(
            const LibraryFilter(sources: {'tachimanga:one'}, author: 'ann'),
            grouping: LibraryGrouping.collection,
            groupKey: 'value:Manga',
          );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Lọc thư viện'));
      await tester.pumpAndSettle();
      await openSourcePicker(tester);
      expect(
        find.widgetWithText(CheckboxListTile, 'Source One'),
        findsOneWidget,
      );
      expect(
        find.widgetWithText(CheckboxListTile, 'Source Two'),
        findsOneWidget,
      );
      expect(
        find.widgetWithText(CheckboxListTile, 'Source Three'),
        findsNothing,
      );
      await tester.tap(find.byTooltip('Đóng danh sách'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Tác giả'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Tác giả'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('library-filter-option-ann')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('library-filter-option-binh')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('library-filter-option-chi')),
        findsNothing,
      );
      await tester.tap(find.byTooltip('Đóng danh sách'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('library-filter-scope')),
        100,
        scrollable: find
            .descendant(
              of: find.byKey(const ValueKey('library-filter-options')),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Phạm vi và danh mục'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('Danh mục'),
        100,
        scrollable: find
            .descendant(
              of: find.byKey(const ValueKey('library-filter-options')),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.ensureVisible(find.text('Danh mục'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Danh mục'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('library-filter-option-Novel')),
      );
      await tester.pumpAndSettle();
      await openSourcePicker(tester);
      expect(
        find.widgetWithText(CheckboxListTile, 'Source Three'),
        findsOneWidget,
      );
      expect(find.widgetWithText(CheckboxListTile, 'Source One'), findsNothing);
      expect(find.widgetWithText(CheckboxListTile, 'Source Two'), findsNothing);
      await tester.tap(find.byTooltip('Đóng danh sách'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Tác giả'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Tác giả'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('library-filter-option-chi')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('library-filter-option-ann')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('library-filter-option-binh')),
        findsNothing,
      );
      expect(
        container
            .read(libraryFilterProvider)
            .forGroup(LibraryGrouping.collection, 'value:Novel')
            .selectedSources,
        isEmpty,
      );
      expect(
        container
            .read(libraryFilterProvider)
            .forGroup(LibraryGrouping.collection, 'value:Novel')
            .author,
        isEmpty,
      );
      expect(tester.takeException(), isNull);
    },
  );
}
