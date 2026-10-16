import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tachi_books/core/theme/app_theme.dart';
import 'package:tachi_books/features/downloads/presentation/downloads_screen.dart';
import 'package:tachi_books/features/downloads/presentation/download_deletion_controller.dart';
import 'package:tachi_books/features/library/data/library_repository.dart';
import 'package:tachi_books/features/library/domain/library_book.dart';
import 'package:tachi_books/features/library/presentation/activity_screens.dart';
import 'package:tachi_books/features/library/presentation/library_view_model.dart';
import 'package:tachi_books/features/settings/settings_controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final width in [320.0, 430.0]) {
    testWidgets(
      'history offers an explicit resume action at $width with large text',
      (tester) async {
        final repo = MemoryLibraryRepository();
        await repo.save(
          _book(
            'one',
            'Truyện đang đọc có tên dài để kiểm tra',
          ).copyWith(lastRead: DateTime(2026, 10, 10)),
        );
        await _show(tester, repo, const HistoryScreen(), width);
        expect(find.widgetWithText(TextButton, 'Tiếp tục đọc'), findsOneWidget);
        final resume = tester.widget<TextButton>(
          find.widgetWithText(TextButton, 'Tiếp tục đọc'),
        );
        expect(resume.onPressed, isNotNull);
        expect(tester.takeException(), isNull);
      },
    );
    testWidgets(
      'updates select range, invert and mark real chapters at $width with large text',
      (tester) async {
        final repo = MemoryLibraryRepository();
        final book = _book('one', 'Truyện đầu tiên');
        await repo.save(book);
        await repo.save(_book('two', 'Truyện thứ hai'));
        await _show(tester, repo, const UpdatesScreen(), width);
        expect(find.text('Chưa đọc'), findsWidgets);
        final container = ProviderScope.containerOf(
          tester.element(find.byType(UpdatesScreen)),
        );
        await container
            .read(downloadDeletionProvider.notifier)
            .update(afterManualRead: true);
        await tester.longPress(find.text('one chương 3'));
        await tester.pumpAndSettle();
        expect(find.text('1 đã chọn'), findsOneWidget);
        await tester.scrollUntilVisible(find.text('one chương 1'), 90);
        await tester.ensureVisible(find.text('one chương 1'));
        await tester.pumpAndSettle();
        await tester.longPress(find.text('one chương 1'));
        await tester.pumpAndSettle();
        expect(find.text('3 đã chọn'), findsOneWidget);
        await tester.tap(find.byTooltip('Chọn nhiều chương cập nhật'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Đảo lựa chọn'));
        await tester.pumpAndSettle();
        expect(find.text('3 đã chọn'), findsOneWidget);
        // Inverting picks the other title, independently of chapter source ordinal.
        final last = tester.widget<Checkbox>(
          find.byWidgetPredicate(
            (widget) =>
                widget is Checkbox &&
                widget.semanticLabel == 'Chọn Truyện đầu tiên one chương 1',
          ),
        );
        expect(last.value, false);
        await tester.tap(find.byTooltip('Chọn nhiều chương cập nhật'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Chọn tất cả'));
        await tester.pumpAndSettle();
        expect(find.text('6 đã chọn'), findsOneWidget);
        await tester.tap(find.text('Đánh dấu đã đọc'));
        await tester.pumpAndSettle();
        expect(find.text('Đã đọc'), findsWidgets);
        for (final saved in (await repo.list())) {
          expect(
            saved.chapters.every((chapter) => chapter.read == true),
            isTrue,
          );
          expect(saved.chapters.map((chapter) => chapter.downloaded), [
            false,
            true,
            false,
          ]);
        }
        expect((await repo.find(book.id))!.bookmarks, book.bookmarks);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'download selection confirms and protects bookmarks and imported content at $width',
      (tester) async {
        final repo = MemoryLibraryRepository();
        final book = _book('one', 'Truyện đã tải');
        final second = _book('two', 'Truyện thứ hai đã tải');
        final local = _book(
          'local',
          'Nội dung đã nhập',
        ).copyWith(engine: 'local');
        for (final item in [book, second, local]) {
          await repo.save(item);
          for (var i = 0; i < item.chapters.length; i++) {
            await repo.saveChapter(
              item.id,
              i,
              ReaderContent(kind: 'novel', html: '<p>${item.id} $i</p>'),
            );
          }
        }
        await _show(tester, repo, const RecentDownloadsScreen(), width);
        await tester.tap(find.byTooltip('Chọn chương đã tải'));
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Chọn tất cả chương đã tải'));
        await tester.pumpAndSettle();
        expect(find.text('6 đã chọn'), findsOneWidget);
        await tester.tap(find.byTooltip('Xóa nội dung đã chọn'));
        await tester.pumpAndSettle();
        expect(find.text('Xóa nội dung đã tải?'), findsOneWidget);
        await tester.tap(find.text('Hủy'));
        await tester.pumpAndSettle();
        expect(
          (await repo.find(book.id))!.chapters
              .every((chapter) => chapter.downloaded),
          isTrue,
        );
        await tester.tap(find.byTooltip('Xóa nội dung đã chọn'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Xóa đã chọn'));
        await tester.pumpAndSettle();
        expect(
          (await repo.find(book.id))!.chapters
              .map((chapter) => chapter.downloaded),
          [false, true, false],
        );
        expect(await repo.readChapter(book.id, 0), isNull);
        expect(await repo.readChapter(book.id, 1), isNotNull);
        expect(
          (await repo.find(second.id))!.chapters
              .map((chapter) => chapter.downloaded),
          [false, true, false],
        );
        expect(await repo.readChapter(second.id, 0), isNull);
        expect(await repo.readChapter(second.id, 1), isNotNull);
        expect(
          (await repo.find(local.id))!.chapters
              .every((chapter) => chapter.downloaded),
          isTrue,
        );
        expect(await repo.readChapter(local.id, 0), isNotNull);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('restoring a library cancels stale update selection', (
    tester,
  ) async {
    final repo = MemoryLibraryRepository();
    final book = _book('one', 'Truyện trước khôi phục');
    await repo.save(book);
    await _show(tester, repo, const UpdatesScreen(), 430);
    await tester.longPress(find.text('one chương 3'));
    await tester.pumpAndSettle();
    expect(find.text('1 đã chọn'), findsOneWidget);
    final container = ProviderScope.containerOf(
      tester.element(find.byType(UpdatesScreen)),
    );
    await repo.clear();
    await repo.save(book.copyWith(title: 'Truyện mới khôi phục'));
    await container.read(libraryProvider.notifier).refresh();
    await tester.pumpAndSettle();
    expect(find.text('1 đã chọn'), findsNothing);
    expect(find.byTooltip('Hủy chọn chương cập nhật'), findsNothing);
    expect(
      (await repo.find(book.id))!.chapters
          .every((chapter) => chapter.read == false),
      isTrue,
    );
    expect(tester.takeException(), isNull);
  });
}

LibraryBook _book(String id, String title) => LibraryBook(
  id: id,
  title: title,
  kind: 'manga',
  engine: 'tachimanga',
  sourceId: '2553532324170433933',
  sourceName: 'TruyenQQ',
  currentChapter: 1,
  progress: .4,
  bookmarks: const ['1:.4'],
  chapters: [
    for (var i = 0; i < 3; i++)
      BookChapter(
        id: '$id-$i',
        title: '$id chương ${i + 1}',
        index: 10 + i,
        read: false,
        downloaded: true,
        discoveredAt: DateTime(2026, 10, 10),
      ),
  ],
);

Future<void> _show(
  WidgetTester tester,
  LibraryRepository repo,
  Widget screen,
  double width,
) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = Size(width, width == 320 ? 568 : 932);
  addTearDown(tester.view.reset);
  final prefs = await SharedPreferences.getInstance();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        preferencesProvider.overrideWithValue(prefs),
        libraryRepositoryProvider.overrideWithValue(repo),
      ],
      child: MaterialApp(
        theme: appTheme(Brightness.dark),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(1.5)),
          child: child!,
        ),
        home: screen,
      ),
    ),
  );
  await tester.pumpAndSettle();
}
