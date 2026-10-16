import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tachi_books/core/theme/app_theme.dart';
import 'package:tachi_books/features/library/data/library_repository.dart';
import 'package:tachi_books/features/library/domain/library_book.dart';
import 'package:tachi_books/features/library/domain/library_grouping.dart';
import 'package:tachi_books/features/library/presentation/library_categories_screen.dart';
import 'package:tachi_books/features/library/presentation/library_filter_controller.dart';
import 'package:tachi_books/features/library/presentation/library_filter_sheet.dart';
import 'package:tachi_books/features/library/presentation/library_group_order_controller.dart';
import 'package:tachi_books/features/library/presentation/library_view_model.dart';
import 'package:tachi_books/features/library/presentation/library_screen.dart';
import 'package:tachi_books/features/settings/settings_controller.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final width in [320.0, 430.0]) {
    testWidgets(
      'empty library offers discovery without hiding import at $width',
      (tester) async {
        await _mount(tester, width);
        expect(find.text('Khám phá truyện'), findsOneWidget);
        expect(find.text('Nhập EPUB, TXT, CBZ'), findsOneWidget);
        await tester.tap(find.text('Khám phá truyện'));
        await tester.pumpAndSettle();
        expect(find.text('Nguồn truyện'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('search empty state clears the visible query at $width', (
      tester,
    ) async {
      final repo = await _mount(
        tester,
        width,
        books: [LibraryBook(id: 'b', title: 'Truyện đã lưu')],
      );
      await tester.tap(find.byTooltip('Tìm trong thư viện'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'không tồn tại');
      await tester.pumpAndSettle();
      expect(
        find.text('Không tìm thấy truyện cho “không tồn tại”.'),
        findsOneWidget,
      );
      await tester.tap(find.text('Xóa tìm kiếm'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('library-book-b')), findsOneWidget);
      expect((await repo.find('b'))!.title, 'Truyện đã lưu');
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      'filter empty state resets criteria and keeps display preferences at $width',
      (tester) async {
        const filter = LibraryFilter(
          favorite: LibraryTriState.include,
          display: LibraryDisplay.list,
          showSource: true,
        );
        final repo = await _mount(
          tester,
          width,
          books: [LibraryBook(id: 'b', title: 'Truyện đã lưu')],
          filter: filter,
        );
        expect(find.text('Không có truyện phù hợp'), findsOneWidget);
        await tester.tap(find.text('Đặt lại bộ lọc'));
        await tester.pumpAndSettle();
        final container = ProviderScope.containerOf(
          tester.element(find.byType(LibraryScreen)),
        );
        final saved = container.read(libraryFilterProvider).filter;
        expect(saved.active, isFalse);
        expect(saved.display, LibraryDisplay.list);
        expect(saved.showSource, isTrue);
        expect(find.byKey(const ValueKey('library-book-b')), findsOneWidget);
        expect((await repo.list()).length, 1);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'category inline validation and drag order preserve memberships at $width',
      (tester) async {
        final repo = MemoryLibraryRepository();
        await repo.save(
          LibraryBook(id: 'b', title: 'Truyện', categories: ['A', 'B']),
        );
        final preferences = await SharedPreferences.getInstance();
        final container = ProviderContainer(
          overrides: [
            preferencesProvider.overrideWithValue(preferences),
            libraryRepositoryProvider.overrideWithValue(repo),
          ],
        );
        addTearDown(container.dispose);
        await container.read(libraryProvider.future);
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = Size(width, 932);
        addTearDown(tester.view.reset);
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              theme: appTheme(Brightness.dark),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(textScaler: const TextScaler.linear(1.5)),
                child: child!,
              ),
              home: const LibraryCategoriesScreen(),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('Quản lý danh mục'), findsOneWidget);
        final list = tester.widget<ReorderableListView>(
          find.byType(ReorderableListView),
        );
        list.onReorderItem!(0, 1);
        await tester.pumpAndSettle();
        expect(
          container.read(
            libraryGroupOrderProvider,
          )[LibraryGrouping.collection.name],
          ['value:B', 'value:A'],
        );
        expect((await repo.find('b'))!.categories, ['A', 'B']);
        await tester.tap(find.byTooltip('Tạo danh mục'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Tạo'));
        await tester.pumpAndSettle();
        expect(find.text('Nhập tên danh mục.'), findsOneWidget);
        await tester.enterText(
          find.byKey(const ValueKey('category-name')),
          'A',
        );
        await tester.tap(find.text('Tạo'));
        await tester.pumpAndSettle();
        expect(find.text('Danh mục này đã tồn tại.'), findsOneWidget);
        expect(find.byType(AlertDialog), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }
}

Future<MemoryLibraryRepository> _mount(
  WidgetTester tester,
  double width, {
  List<LibraryBook> books = const [],
  LibraryFilter filter = const LibraryFilter(),
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = Size(width, 932);
  addTearDown(tester.view.reset);
  final repo = MemoryLibraryRepository();
  for (final book in books) {
    await repo.save(book);
  }
  final preferences = await SharedPreferences.getInstance();
  await preferences.setString(
    LibraryFilterController.preferenceKey,
    jsonEncode(LibraryFilterPreferences(filter: filter).toJson()),
  );
  final router = GoRouter(
    initialLocation: '/library',
    routes: [
      GoRoute(path: '/library', builder: (_, _) => const LibraryScreen()),
      GoRoute(
        path: '/browse',
        builder: (_, _) => const Scaffold(body: Text('Nguồn truyện')),
      ),
    ],
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        preferencesProvider.overrideWithValue(preferences),
        libraryRepositoryProvider.overrideWithValue(repo),
      ],
      child: MaterialApp.router(
        routerConfig: router,
        theme: appTheme(Brightness.dark),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: const TextScaler.linear(1.5)),
          child: child!,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return repo;
}
