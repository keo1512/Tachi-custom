import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tachi_books/core/theme/app_theme.dart';
import 'package:tachi_books/features/library/data/library_repository.dart';
import 'package:tachi_books/features/library/domain/library_book.dart';
import 'package:tachi_books/features/library/presentation/library_screen.dart';
import 'package:tachi_books/features/library/presentation/library_view_model.dart';
import 'package:tachi_books/features/settings/settings_controller.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets(
    'a group dialog opened before restore cannot regroup a replacement book',
    (tester) async {
      final repo = MemoryLibraryRepository();
      await repo.save(
        LibraryBook(id: '1', title: 'Original', collection: 'Original shelf'),
      );
      await mountLibrary(tester, repo, const Size(430, 932));
      await tester.longPress(find.byKey(const ValueKey('library-book-1')));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Gom nhóm sách đã chọn'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('folder-name')),
        'Stale shelf',
      );
      final replacement = LibraryBook(
        id: '1',
        title: 'Replacement',
        collection: 'Restored shelf',
      );
      await repo.clear();
      await repo.save(replacement);
      final container = ProviderScope.containerOf(
        tester.element(find.byType(LibraryScreen)),
      );
      await container.read(libraryProvider.notifier).refresh();
      await tester.pumpAndSettle();
      await tester.tap(find.text('Lưu'));
      await tester.pumpAndSettle();
      expect((await repo.find('1'))!.toJson(), replacement.toJson());
      expect(
        find.textContaining('Thư viện đã được thay đổi hoặc khôi phục'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );

  for (final size in const [Size(320, 568), Size(430, 932)]) {
    testWidgets(
      'multi-select assigns an explicit series without replacing manual shelves at $size',
      (tester) async {
        final repo = MemoryLibraryRepository();
        await repo.save(
          LibraryBook(
            id: '1',
            title: 'First',
            collection: 'Manual 1',
            author: 'Shared author',
          ),
        );
        await repo.save(
          LibraryBook(
            id: '2',
            title: 'Second',
            collection: 'Manual 1',
            author: 'Shared author',
          ),
        );
        await repo.save(LibraryBook(id: '3', title: 'Third'));
        await mountLibrary(tester, repo, size);
        await tester.longPress(find.byKey(const ValueKey('library-book-1')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('library-book-2')));
        await tester.pumpAndSettle();
        expect(find.text('Đã chọn 2'), findsOneWidget);
        await openMetadata(tester);
        await tester.pumpAndSettle();
        await tester.tap(
          find.byWidgetPredicate((widget) => widget is DropdownButtonFormField),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Bộ truyện').last);
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const ValueKey('group-name')),
          'Series đã gán',
        );
        if (size.width == 320) {
          tester.view.viewInsets = const FakeViewPadding(bottom: 260);
          await tester.pumpAndSettle();
          await tester.ensureVisible(find.text('Áp dụng'));
        }
        await tester.tap(find.text('Áp dụng'));
        await tester.pumpAndSettle();
        tester.view.resetViewInsets();
        await tester.pumpAndSettle();
        expect((await repo.find('1'))!.series, 'Series đã gán');
        expect((await repo.find('2'))!.series, 'Series đã gán');
        expect((await repo.find('3'))!.series, '');
        expect((await repo.find('1'))!.collection, 'Manual 1');
        expect((await repo.find('2'))!.collection, 'Manual 1');
        await tester.tap(find.byTooltip('Thao tác thư viện'));
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const ValueKey('library-group-mode-series')),
        );
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const ValueKey('library-folder-value:series đã gán')),
        );
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('library-book-1')), findsOneWidget);
        expect(find.byKey(const ValueKey('library-book-2')), findsOneWidget);
        expect(find.byKey(const ValueKey('library-book-3')), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'menu selection moves all selected books to a manual shelf without changing their author or series',
    (tester) async {
      final repo = MemoryLibraryRepository();
      await repo.save(
        LibraryBook(
          id: '1',
          title: 'First',
          author: 'Author 1',
          series: 'Series 1',
        ),
      );
      await repo.save(
        LibraryBook(
          id: '2',
          title: 'Second',
          author: 'Author 2',
          series: 'Series 2',
        ),
      );
      await mountLibrary(tester, repo, const Size(320, 568));
      await tester.tap(find.byTooltip('Thao tác thư viện'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Chọn nhiều sách'));
      await tester.pumpAndSettle();
      expect(find.text('Đã chọn 0'), findsOneWidget);
      await tester.tap(find.byTooltip('Chọn tất cả sách hiển thị'));
      await tester.pumpAndSettle();
      await openMetadata(tester);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('group-name')),
        'Kệ mới',
      );
      await tester.tap(find.text('Áp dụng'));
      await tester.pumpAndSettle();
      expect((await repo.list()).map((book) => book.collection), [
        'Kệ mới',
        'Kệ mới',
      ]);
      expect((await repo.find('1'))!.author, 'Author 1');
      expect((await repo.find('2'))!.series, 'Series 2');
      expect(
        find.byKey(const ValueKey('library-group-value:Kệ mới')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'author grouping, visible-only select-all and cancel leave data intact',
    (tester) async {
      final repo = MemoryLibraryRepository();
      await repo.save(
        LibraryBook(
          id: '1',
          title: 'First',
          author: 'Shared author',
          collection: 'Keep 1',
        ),
      );
      await repo.save(
        LibraryBook(
          id: '2',
          title: 'Second',
          author: ' shared   author ',
          collection: 'Keep 1',
        ),
      );
      await repo.save(LibraryBook(id: '3', title: 'Third'));
      final before = (await repo.list()).map((book) => book.toJson()).toList();
      await mountLibrary(tester, repo, const Size(320, 568));
      await tester.tap(find.byTooltip('Thao tác thư viện'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('library-group-mode-author')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('library-folder-value:shared author')),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('library-book-3')), findsNothing);
      await tester.longPress(find.byKey(const ValueKey('library-book-1')));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Chọn tất cả sách hiển thị'));
      await tester.pumpAndSettle();
      expect(find.text('Đã chọn 2'), findsOneWidget);
      await tester.tap(find.byTooltip('Gom nhóm sách đã chọn'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('folder-name')),
        'Changed author',
      );
      await tester.tap(find.text('Hủy'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Hủy chọn sách'));
      await tester.pumpAndSettle();
      expect((await repo.list()).map((book) => book.toJson()).toList(), before);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      await mountLibrary(tester, repo, const Size(320, 568));
      expect(find.byKey(const ValueKey('library-group-all')), findsNothing);
      expect(
        find.byKey(const ValueKey('library-folder-value:shared author')),
        findsOneWidget,
      );
      // Newly imported explicit metadata joins the active derived group.
      await repo.save(
        LibraryBook(
          id: '4',
          title: 'New book',
          author: 'Shared author',
          collection: 'Keep 1',
        ),
      );
      final container = ProviderScope.containerOf(
        tester.element(find.byType(LibraryScreen)),
      );
      await container.read(libraryProvider.notifier).refresh();
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('library-folder-value:shared author')),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('library-book-4')), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}

Future<void> mountLibrary(
  WidgetTester tester,
  MemoryLibraryRepository repo,
  Size size,
) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);
  final prefs = await SharedPreferences.getInstance();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        libraryRepositoryProvider.overrideWithValue(repo),
        preferencesProvider.overrideWithValue(prefs),
      ],
      child: MaterialApp(
        theme: appTheme(Brightness.dark),
        home: const LibraryScreen(),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> openMetadata(WidgetTester tester) async {
  await tester.tap(find.byTooltip('Thao tác với sách đã chọn'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Danh mục và thông tin truyện'));
}
