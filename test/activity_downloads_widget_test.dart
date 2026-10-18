import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tachi_books/core/theme/app_theme.dart';
import 'package:tachi_books/features/downloads/presentation/downloads_screen.dart';
import 'package:tachi_books/features/library/data/library_repository.dart';
import 'package:tachi_books/features/library/domain/library_book.dart';
import 'package:tachi_books/features/library/domain/library_reading.dart';
import 'package:tachi_books/features/library/presentation/activity_book_cover.dart';
import 'package:tachi_books/features/library/presentation/activity_screens.dart';
import 'package:tachi_books/features/library/presentation/library_view_model.dart';
import 'package:tachi_books/features/settings/settings_controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final size in [
    const Size(320, 568),
    const Size(844, 390),
    const Size(1024, 768),
  ]) {
    testWidgets('activity and empty downloads fit $size', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = size;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      final repository = MemoryLibraryRepository();
      await repository.save(
        _book(
          'primary',
          'Một tựa sách rất dài kiểm tra bố cục và nội dung thực tế',
        ),
      );
      final prefs = await SharedPreferences.getInstance();
      for (final screen in [
        const UpdatesScreen(),
        const HistoryScreen(),
        const DownloadsScreen(),
      ]) {
        await _show(tester, prefs, repository, screen);
        expect(
          tester.takeException(),
          isNull,
          reason: '${screen.runtimeType} must fit $size.',
        );
        final covers = tester.widgetList<ActivityBookCover>(
          find.byType(ActivityBookCover),
        );
        if (screen is UpdatesScreen) {
          expect(covers, isNotEmpty);
          expect(covers.first.width, 48);
          expect(covers.first.height, 48);
          expect(find.byTooltip('Đã tải chương'), findsOneWidget);
        } else if (screen is HistoryScreen) {
          expect(covers.single.width, 82);
          expect(covers.single.height, 120);
          expect(find.text('Chương giữa'), findsOneWidget);
        } else {
          expect(find.text('Σ(ಠ_ಠ)'), findsOneWidget);
          expect(find.text('Không có tải xuống'), findsOneWidget);
          final continueButton = tester.widget<FilledButton>(
            find.widgetWithText(FilledButton, 'Tiếp tục'),
          );
          expect(
            continueButton.onPressed,
            isNull,
            reason: 'An empty queue cannot pretend to resume work.',
          );
        }
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      }
    });
  }

  testWidgets(
    'updates retain earlier unread flags, hide later read flags and filter by shelf',
    (tester) async {
      final repo = MemoryLibraryRepository();
      for (final item in [('first', 'Kệ A'), ('second', 'Kệ B')]) {
        await repo.save(
          _book(item.$1, 'Truyện ${item.$1}').copyWith(
            collection: item.$2,
            chapters: const [
              BookChapter(
                id: 'a',
                title: 'Chương chưa đọc trước tiến độ',
                index: 0,
                read: false,
              ),
              BookChapter(
                id: 'b',
                title: 'Chương đã đọc sau tiến độ',
                index: 1,
                read: true,
              ),
            ],
          ),
        );
      }
      await _show(
        tester,
        await SharedPreferences.getInstance(),
        repo,
        const UpdatesScreen(),
      );
      await tester.tap(find.byTooltip('Tùy chọn cập nhật'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.ancestor(
          of: find.text('Xem cả chương chưa đọc đã có'),
          matching: find.byType(CheckedPopupMenuItem<String>),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Chương chưa đọc trước tiến độ'), findsNWidgets(2));
      expect(find.text('Chương đã đọc sau tiến độ'), findsNothing);
      await tester.tap(find.byTooltip('Tùy chọn cập nhật'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.widgetWithText(CheckedPopupMenuItem<String>, 'Kệ A'),
      );
      await tester.pumpAndSettle();
      expect(find.text('Chương chưa đọc trước tiến độ'), findsOneWidget);
      expect(find.text('Truyện first'), findsOneWidget);
      expect(find.text('Truyện second'), findsNothing);
      expect(find.text('Chương chưa đọc · Kệ A'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'history searches real books and removes one history entry without changing progress or cache',
    (tester) async {
      final repo = MemoryLibraryRepository();
      final first = _book('first', 'Sách tìm thấy');
      final other = _book('other', 'Một sách khác');
      await repo.save(first);
      await repo.save(other);
      await repo.saveChapter(
        first.id,
        1,
        ReaderContent(kind: 'novel', html: '<p>Keep offline content</p>'),
      );
      final prefs = await SharedPreferences.getInstance();
      await _show(tester, prefs, repo, const HistoryScreen());
      await tester.tap(find.byTooltip('Tìm lịch sử'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byType(CupertinoSearchTextField),
        'Sách tìm thấy',
      );
      await tester.pumpAndSettle();
      expect(
        find.byWidgetPredicate(
          (widget) => widget is Text && widget.data == first.title,
        ),
        findsOneWidget,
      );
      expect(find.text(other.title), findsNothing);
      await tester.tap(find.byTooltip('Xóa lịch sử ${first.title}'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Xóa lịch sử'));
      await tester.pumpAndSettle();
      final saved = (await repo.find(first.id))!;
      expect(saved.lastRead, isNull);
      expect(saved.currentChapter, first.currentChapter);
      expect(saved.progress, first.progress);
      expect(saved.bookmarks, first.bookmarks);
      expect(
        [
          for (var index = 0; index < saved.chapters.length; index++)
            chapterIsRead(saved, index),
        ],
        [
          for (var index = 0; index < first.chapters.length; index++)
            chapterIsRead(first, index),
        ],
      );
      expect(
        saved.chapters
            .map((chapter) => chapter.toJson()..remove('read'))
            .toList(),
        first.chapters
            .map((chapter) => chapter.toJson()..remove('read'))
            .toList(),
      );
      expect(
        (await repo.readChapter(first.id, 1))!.html,
        '<p>Keep offline content</p>',
      );
      expect((await repo.find(other.id))!.toJson(), other.toJson());
      expect(find.text('Không tìm thấy lịch sử'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'download concurrency control persists the selected setting and recent page lists actual cached chapter flags',
    (tester) async {
      final repo = MemoryLibraryRepository();
      await repo.save(_book('first', 'Sách đã tải'));
      final prefs = await SharedPreferences.getInstance();
      await _show(tester, prefs, repo, const DownloadsScreen());
      await tester.tap(find.text('Tải xuống đồng thời:\n2'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('3'));
      await tester.pumpAndSettle();
      expect(prefs.getInt('downloadConcurrency'), 3);
      expect(find.text('Tải xuống đồng thời:\n3'), findsOneWidget);
      await tester.tap(find.text('Gần đây đã tải xuống'));
      await tester.pumpAndSettle();
      expect(find.byType(RecentDownloadsScreen), findsOneWidget);
      expect(find.text('Chương cuối'), findsOneWidget);
      expect(find.text('Chương giữa'), findsNothing);
      expect(find.text('Sách đã tải'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}

LibraryBook _book(String id, String title) => LibraryBook(
  id: id,
  title: title,
  engine: 'vbook',
  currentChapter: 1,
  progress: .5,
  lastRead: DateTime.now().subtract(const Duration(days: 2)),
  bookmarks: const ['1:0.5000'],
  chapters: [
    BookChapter(
      id: 'first',
      title: 'Chương đầu',
      index: 7,
      discoveredAt: DateTime(2026, 10, 10),
    ),
    BookChapter(
      id: 'second',
      title: 'Chương giữa',
      index: 8,
      discoveredAt: DateTime(2026, 10, 10),
    ),
    BookChapter(
      id: 'third',
      title: 'Chương cuối',
      index: 9,
      downloaded: true,
      discoveredAt: DateTime(2026, 10, 10),
    ),
  ],
);

Future<void> _show(
  WidgetTester tester,
  SharedPreferences prefs,
  MemoryLibraryRepository repo,
  Widget screen,
) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        preferencesProvider.overrideWithValue(prefs),
        libraryRepositoryProvider.overrideWithValue(repo),
      ],
      child: MaterialApp(theme: appTheme(Brightness.dark), home: screen),
    ),
  );
  await tester.pumpAndSettle();
}
