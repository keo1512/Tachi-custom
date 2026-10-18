import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tachi_books/core/theme/app_theme.dart';
import 'package:tachi_books/features/library/data/library_repository.dart';
import 'package:tachi_books/features/library/domain/library_book.dart';
import 'package:tachi_books/features/library/domain/library_folders.dart';
import 'package:tachi_books/features/library/presentation/library_screen.dart';
import 'package:tachi_books/features/library/presentation/library_filter_controller.dart';
import 'package:tachi_books/features/library/presentation/library_filter_sheet.dart';
import 'package:tachi_books/features/library/presentation/library_view_model.dart';
import 'package:tachi_books/features/settings/settings_controller.dart';

void main() {
  testWidgets(
    'hidden category tabs keep a compact selector; filter category changes navigate instead of intersecting',
    (tester) async {
      SharedPreferences.setMockInitialValues({
        'libraryFilterV1': jsonEncode(
          LibraryFilterPreferences(
            filter: const LibraryFilter(showCategoryTabs: false),
          ).toJson(),
        ),
      });
      final repository = MemoryLibraryRepository();
      await repository.save(
        LibraryBook(id: 'a', title: 'A', categories: ['Manga']),
      );
      await repository.save(
        LibraryBook(id: 'b', title: 'B', categories: ['Novel']),
      );
      await mount(tester, repository, 320);
      await tester.tap(find.byKey(const ValueKey('library-category-selector')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Novel (1)').last);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('library-book-b')), findsOneWidget);
      expect(find.byKey(const ValueKey('library-book-a')), findsNothing);
      await tester.tap(find.byTooltip('Lọc thư viện'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Danh mục'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Danh mục'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ListTile, 'Manga'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Đóng bộ lọc'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('library-book-a')), findsOneWidget);
      expect(find.byKey(const ValueKey('library-book-b')), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
  for (final width in [320.0, 430.0]) {
    testWidgets(
      'author folders open inside categories without an All tab at $width',
      (tester) async {
        SharedPreferences.setMockInitialValues({
          'libraryGrouping': 'author',
          'libraryColumns': 8,
        });
        final repository = MemoryLibraryRepository();
        for (final book in [
          LibraryBook(
            id: 'a',
            title: 'Grand Blue',
            author: 'Same Author',
            categories: ['Manga'],
          ),
          LibraryBook(
            id: 'b',
            title: 'Blue Box',
            author: 'Same Author',
            categories: ['Manga'],
          ),
          LibraryBook(
            id: 'c',
            title: 'Novel',
            author: 'Same Author',
            categories: ['Novel'],
          ),
        ]) {
          await repository.save(book);
        }
        final before = (await repository.snapshot()).fingerprint;
        await mount(tester, repository, width);
        expect(find.byKey(const ValueKey('library-group-all')), findsNothing);
        expect(
          find.byKey(const ValueKey('library-group-value:same author')),
          findsNothing,
        );
        final folder = find.byKey(
          const ValueKey('library-folder-value:same author'),
        );
        expect(folder, findsOneWidget);
        expect(find.text('2 truyện'), findsOneWidget);
        expect(find.byKey(const ValueKey('library-book-a')), findsNothing);
        await tester.tap(folder);
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('library-book-a')), findsOneWidget);
        expect(find.byKey(const ValueKey('library-book-b')), findsOneWidget);
        await tester.tap(find.byTooltip('Về danh mục'));
        await tester.pumpAndSettle();
        expect(folder, findsOneWidget);
        await tester.tap(
          find.byKey(const ValueKey('library-group-value:Novel')),
        );
        await tester.pumpAndSettle();
        expect(folder, findsNothing);
        expect(find.byKey(const ValueKey('library-book-c')), findsOneWidget);
        expect((await repository.snapshot()).fingerprint, before);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'selection creates a folder and dissolves it without changing categories or author',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final repository = MemoryLibraryRepository();
      await repository.save(
        LibraryBook(id: 'a', title: 'A', author: 'X', categories: ['Manga']),
      );
      await repository.save(
        LibraryBook(id: 'b', title: 'B', author: 'Y', categories: ['Manga']),
      );
      final before = (await repository.snapshot()).fingerprint;
      final preferences = await mount(tester, repository, 430);
      await tester.longPress(find.byKey(const ValueKey('library-book-a')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('library-book-b')));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Gom nhóm sách đã chọn'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('folder-name')),
        'My folder',
      );
      await tester.tap(find.text('Lưu'));
      await tester.pumpAndSettle();
      final folder = find.byKey(
        const ValueKey('library-folder-folder:My folder'),
      );
      expect(folder, findsOneWidget);
      expect(
        LibraryFolders.decodeWithCategories(
          preferences.getString(LibraryFolders.preferenceKey),
          preferences.getString(LibraryFolders.categoryPreferenceKey),
        ).namesIn('Manga').length,
        2,
      );
      await tester.tap(folder);
      await tester.pumpAndSettle();
      expect((await repository.snapshot()).fingerprint, before);
      await repository.remove('b');
      final container = ProviderScope.containerOf(
        tester.element(find.byType(LibraryScreen)),
      );
      await container.read(libraryProvider.notifier).refresh();
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Sửa thư mục'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Bỏ thư mục, giữ các truyện'));
      await tester.pumpAndSettle();
      expect(folder, findsNothing);
      expect(find.byKey(const ValueKey('library-book-a')), findsOneWidget);
      expect(find.byKey(const ValueKey('library-book-b')), findsNothing);
      expect((await repository.find('a'))!.author, 'X');
      expect((await repository.find('a'))!.categories, ['Manga']);
      expect(tester.takeException(), isNull);
    },
  );
}

Future<SharedPreferences> mount(
  WidgetTester tester,
  MemoryLibraryRepository repository,
  double width,
) async {
  tester.view.physicalSize = Size(width, 932);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final preferences = await SharedPreferences.getInstance();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        preferencesProvider.overrideWithValue(preferences),
        libraryRepositoryProvider.overrideWithValue(repository),
      ],
      child: MaterialApp(
        theme: appTheme(Brightness.dark),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(1.5)),
          child: child!,
        ),
        home: const LibraryScreen(),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return preferences;
}
