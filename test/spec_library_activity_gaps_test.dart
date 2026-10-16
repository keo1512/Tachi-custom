import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tachi_books/core/theme/app_theme.dart';
import 'package:tachi_books/features/downloads/presentation/downloads_screen.dart';
import 'package:tachi_books/features/library/data/library_repository.dart';
import 'package:tachi_books/features/library/domain/library_book.dart';
import 'package:tachi_books/features/library/presentation/activity_screens.dart';
import 'package:tachi_books/features/library/presentation/book_detail_screen.dart';
import 'package:tachi_books/features/library/presentation/library_category_controller.dart';
import 'package:tachi_books/features/library/presentation/library_filter_sheet.dart';
import 'package:tachi_books/features/library/presentation/library_screen.dart';
import 'package:tachi_books/features/library/presentation/library_view_model.dart';
import 'package:tachi_books/features/settings/settings_controller.dart';
import 'package:tachi_books/features/sources/data/source_repository.dart';
import 'package:tachi_books/features/sources/domain/catalogue.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final width in [320.0, 430.0]) {
    testWidgets('display sheet changes actual library columns at $width', (
      tester,
    ) async {
      final book = _book('one');
      final fixture = await _show(
        tester,
        const LibraryScreen(),
        width,
        books: [book],
      );
      final before = (await fixture.repo.snapshot()).fingerprint;
      await tester.tap(find.byTooltip('Lọc thư viện'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Hiển thị'));
      await tester.pumpAndSettle();
      final slider = find.byKey(const ValueKey('library-columns-slider'));
      await tester.ensureVisible(slider);
      await tester.drag(slider, const Offset(-400, 0));
      await tester.pumpAndSettle();
      expect(fixture.container.read(settingsProvider).libraryColumns, 2);
      await tester.tap(find.byTooltip('Đóng bộ lọc'));
      await tester.pumpAndSettle();
      final grid = tester.widget<GridView>(find.byType(GridView));
      expect(
        (grid.gridDelegate as SliverGridDelegateWithFixedCrossAxisCount)
            .crossAxisCount,
        2,
      );
      expect((await fixture.repo.snapshot()).fingerprint, before);
      expect(find.byType(LibraryFilterSheet), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      'detail category assignment includes empty categories and can remove the old category at $width',
      (tester) async {
        final book = _book('one');
        final fixture = await _show(
          tester,
          BookDetailScreen(id: book.id),
          width,
          books: [book],
        );
        await fixture.container
            .read(libraryCategoriesProvider.notifier)
            .create('Chưa có truyện');
        final before = (await fixture.repo.find(book.id))!;
        await tester.tap(find.byTooltip('Tùy chọn'));
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text('Gán nhiều danh mục'));
        await tester.tap(find.text('Gán nhiều danh mục'));
        await tester.pumpAndSettle();
        final original = find.byKey(const ValueKey('assign-category-Kệ cũ'));
        final empty = find.byKey(
          const ValueKey('assign-category-Chưa có truyện'),
        );
        expect(tester.widget<CheckboxListTile>(original).value, true);
        expect(tester.widget<CheckboxListTile>(empty).value, false);
        await tester.ensureVisible(original);
        await tester.tap(original);
        await tester.ensureVisible(empty);
        await tester.tap(empty);
        await tester.tap(find.widgetWithText(TextButton, 'Lưu'));
        await tester.pumpAndSettle();
        final saved = (await fixture.repo.find(book.id))!;
        expect(saved.categories, ['Chưa có truyện']);
        expect(saved.chapters, before.chapters);
        expect(saved.progress, before.progress);
        expect(saved.bookmarks, before.bookmarks);
        expect(saved.notes, before.notes);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'history search reset and single-item confirmation preserve reading data at $width',
      (tester) async {
        final book = _book('one');
        final fixture = await _show(
          tester,
          const HistoryScreen(),
          width,
          books: [book],
        );
        await tester.tap(find.byTooltip('Tìm lịch sử'));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byType(CupertinoSearchTextField),
          'không có',
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Xóa tìm kiếm'));
        await tester.pumpAndSettle();
        expect(find.text(book.title), findsOneWidget);
        await tester.tap(find.byTooltip('Xóa lịch sử ${book.title}'));
        await tester.pumpAndSettle();
        expect(find.text('Xóa lịch sử đọc?'), findsOneWidget);
        await tester.tap(find.text('Hủy'));
        await tester.pumpAndSettle();
        expect((await fixture.repo.find(book.id))!.toJson(), book.toJson());
        await tester.tap(find.byTooltip('Xóa lịch sử ${book.title}'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Xóa lịch sử'));
        await tester.pumpAndSettle();
        expect(
          (await fixture.repo.find(book.id))!.toJson(),
          book.copyWith(clearLastRead: true).toJson(),
        );
        expect(find.text('Mở thư viện'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );

    for (final screen in [
      const DownloadsScreen(),
      const RecentDownloadsScreen(),
    ]) {
      testWidgets(
        'empty ${screen.runtimeType} returns to the library at $width',
        (tester) async {
          await _show(tester, screen, width);
          final action = screen is DownloadsScreen
              ? 'Chọn truyện trong thư viện'
              : 'Mở thư viện';
          await tester.tap(find.text(action));
          await tester.pumpAndSettle();
          expect(find.text('Thư viện đích'), findsOneWidget);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets(
    'library replacement clears a multi-selection even when restored books reuse the same ID',
    (tester) async {
      final book = _book('one');
      final fixture = await _show(
        tester,
        const LibraryScreen(),
        320,
        books: [book],
      );
      await tester.longPress(find.byKey(const ValueKey('library-book-one')));
      await tester.pumpAndSettle();
      expect(find.text('Đã chọn 1'), findsOneWidget);
      await fixture.repo.clear();
      final restored = book.copyWith(title: 'Truyện sau khôi phục');
      await fixture.repo.save(restored);
      await fixture.container.read(libraryProvider.notifier).refresh();
      await tester.pumpAndSettle();
      expect(find.text('Đã chọn 1'), findsNothing);
      expect(find.byTooltip('Hủy chọn sách'), findsNothing);
      expect((await fixture.repo.find(book.id))!.toJson(), restored.toJson());
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'library keeps visible books and real progress while a source update is pending',
    (tester) async {
      final gate = Completer<List<CatalogueChapter>>();
      final source = _Source(gate.future);
      final book = _book('one');
      final fixture = await _show(
        tester,
        const LibraryScreen(),
        430,
        books: [book],
        source: source,
      );
      final update = fixture.container
          .read(libraryProvider.notifier)
          .updateBooks([book.id]);
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const ValueKey('library-book-one')), findsOneWidget);
      final indicator = tester.widget<LinearProgressIndicator>(
        find.byType(LinearProgressIndicator),
      );
      expect(indicator.value, 0);
      expect(indicator.semanticsLabel, 'Đang kiểm tra chương mới: 0/1 truyện');
      gate.complete(const [
        CatalogueChapter(ref: 'one-c', title: 'Chương', index: 0),
      ]);
      await update;
      await tester.pumpAndSettle();
      expect(find.byType(LinearProgressIndicator), findsNothing);
      expect(find.byKey(const ValueKey('library-book-one')), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  for (final screen in [const HistoryScreen(), const RecentDownloadsScreen()]) {
    testWidgets('${screen.runtimeType} error can retry the actual repository', (
      tester,
    ) async {
      final repo = _FailOnceRepository();
      final book = _book('one');
      final fixture = await _show(
        tester,
        screen,
        320,
        books: [book],
        repo: repo,
      );
      expect(find.text('Thử lại'), findsOneWidget);
      expect(repo.listCalls, 1);
      await tester.tap(find.text('Thử lại'));
      await tester.pumpAndSettle();
      expect(repo.listCalls, 2);
      expect(find.text(book.title), findsOneWidget);
      expect((await fixture.repo.find(book.id))!.toJson(), book.toJson());
      expect(tester.takeException(), isNull);
    });
  }
}

LibraryBook _book(String id) => LibraryBook(
  id: id,
  title: 'Truyện $id',
  engine: 'tachimanga',
  sourceId: '9223372036854775806',
  sourceRef: '/$id',
  kind: 'novel',
  categories: const ['Kệ cũ'],
  progress: .4,
  lastRead: DateTime(2026, 10, 10),
  bookmarks: const ['0:.4'],
  notes: 'Ghi chú cần giữ',
  chapters: [
    BookChapter(
      id: '$id-c',
      title: 'Chương',
      index: 0,
      read: false,
      downloaded: true,
      discoveredAt: DateTime(2026, 10, 10),
    ),
  ],
);

typedef _Fixture = ({
  ProviderContainer container,
  MemoryLibraryRepository repo,
});
Future<_Fixture> _show(
  WidgetTester tester,
  Widget screen,
  double width, {
  List<LibraryBook> books = const [],
  MemoryLibraryRepository? repo,
  SourceRepository? source,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = Size(width, 932);
  addTearDown(tester.view.reset);
  final repository = repo ?? MemoryLibraryRepository();
  for (final book in books) {
    await repository.save(book);
    await repository.saveChapter(
      book.id,
      0,
      ReaderContent(kind: 'novel', html: '<p>Nội dung được giữ</p>'),
    );
  }
  final container = ProviderContainer(
    overrides: [
      preferencesProvider.overrideWithValue(
        await SharedPreferences.getInstance(),
      ),
      libraryRepositoryProvider.overrideWithValue(repository),
      if (source != null) sourceRepositoryProvider.overrideWithValue(source),
    ],
  );
  addTearDown(container.dispose);
  final router = GoRouter(
    initialLocation: '/screen',
    routes: [
      GoRoute(path: '/screen', builder: (_, _) => screen),
      GoRoute(
        path: '/',
        builder: (_, _) => const Scaffold(body: Text('Thư viện đích')),
      ),
    ],
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
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
  return (container: container, repo: repository);
}

class _Source extends SourceRepository {
  _Source(this.result) : super(tachimangaUrl: '', vbookUrl: '');
  final Future<List<CatalogueChapter>> result;
  @override
  Future<List<CatalogueChapter>> chapters(CatalogueBook book) => result;
}

class _FailOnceRepository extends MemoryLibraryRepository {
  int listCalls = 0;
  @override
  Future<List<LibraryBook>> list() {
    if (++listCalls == 1) throw StateError('Không đọc được thư viện');
    return super.list();
  }
}
