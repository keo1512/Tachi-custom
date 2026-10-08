import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tachi_books/app.dart';
import 'package:tachi_books/core/widgets/book_cover.dart';
import 'package:tachi_books/features/downloads/presentation/downloads_screen.dart';
import 'package:tachi_books/features/library/presentation/activity_screens.dart';
import 'package:tachi_books/features/library/data/library_repository.dart';
import 'package:tachi_books/features/library/domain/library_book.dart';
import 'package:tachi_books/features/library/presentation/library_filter_sheet.dart';
import 'package:tachi_books/features/library/presentation/library_screen.dart';
import 'package:tachi_books/features/library/presentation/library_view_model.dart';
import 'package:tachi_books/features/settings/presentation/more_screen.dart';
import 'package:tachi_books/features/settings/settings_controller.dart';
import 'package:tachi_books/features/sources/presentation/browse_screen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('flutter_tts'),
          (_) async => 1,
        );
  });

  for (final viewport in <({String name, Size size, bool tablet})>[
    (name: 'small iPhone', size: const Size(320, 568), tablet: false),
    (name: 'landscape iPhone', size: const Size(844, 390), tablet: false),
    (name: 'iPad', size: const Size(1024, 768), tablet: true),
  ]) {
    testWidgets(
      '${viewport.name} keeps adaptive navigation and library controls usable',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = viewport.size;
        final landscape = viewport.name == 'landscape iPhone';
        if (landscape) {
          tester.view.padding = const FakeViewPadding(
            left: 44,
            right: 44,
            bottom: 21,
          );
          tester.view.viewPadding = const FakeViewPadding(
            left: 44,
            right: 44,
            bottom: 21,
          );
        }
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
          tester.view.resetPadding();
          tester.view.resetViewPadding();
        });
        final prefs = await SharedPreferences.getInstance();
        final repository = MemoryLibraryRepository();
        final books = <LibraryBook>[
          LibraryBook(
            id: 'zeta',
            title:
                'Zeta — Một tựa truyện rất dài để kiểm tra bố cục màn hình nhỏ',
            favorite: true,
            kind: 'manga',
            collection: 'Mặc định',
            chapters: const [BookChapter(id: 'z1', title: 'Một', index: 0)],
          ),
          LibraryBook(
            id: 'alpha',
            title: 'Alpha — Sách yêu thích',
            favorite: true,
            collection: 'Mặc định',
            chapters: const [BookChapter(id: 'a1', title: 'Một', index: 0)],
          ),
          LibraryBook(
            id: 'nonfavorite',
            title: 'Không yêu thích',
            collection: 'Mặc định',
            chapters: const [BookChapter(id: 'n1', title: 'Một', index: 0)],
          ),
        ];
        for (final book in books) {
          await repository.save(book);
        }
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              preferencesProvider.overrideWithValue(prefs),
              libraryRepositoryProvider.overrideWithValue(repository),
            ],
            child: const TachiBooksApp(),
          ),
        );
        await tester.pumpAndSettle();

        final sidebar = find.byKey(const ValueKey('tablet-navigation'));
        final tabs = find.byType(CupertinoTabBar);
        // Widget hosts cannot render UIKit. Their six-tab footer exercises the
        // same routes without asserting native appearance or device behavior.
        expect(sidebar, findsNothing);
        expect(tabs, findsOneWidget);
        expect(tester.widget<CupertinoTabBar>(tabs).items.length, 6);
        expect(find.byType(BookCover), findsNWidgets(3));
        if (landscape) {
          final cover = tester.getRect(find.byType(BookCover).first);
          expect(cover.left, greaterThanOrEqualTo(44));
          expect(cover.right, lessThanOrEqualTo(viewport.size.width - 44));
        }
        expect(
          tester.takeException(),
          isNull,
          reason: 'Initial populated library must fit ${viewport.size}.',
        );
        final navigation = tabs;
        for (final destination in <({String label, Type screen, int index})>[
          (label: 'Cập nhật', screen: UpdatesScreen, index: 1),
          (label: 'Duyệt', screen: BrowseScreen, index: 2),
          (label: 'Tải xuống', screen: DownloadsScreen, index: 3),
          (label: 'Lịch sử', screen: HistoryScreen, index: 4),
          (label: 'Thêm', screen: MoreScreen, index: 5),
        ]) {
          await tester.tap(
            find.descendant(
              of: navigation,
              matching: find.text(destination.label),
            ),
          );
          await tester.pumpAndSettle();
          expect(find.byType(destination.screen), findsOneWidget);
          expect(
            tester.widget<CupertinoTabBar>(tabs).currentIndex,
            destination.index,
          );
          expect(
            tester.takeException(),
            isNull,
            reason: '${destination.label} must fit ${viewport.size}.',
          );
        }
        expect(find.byTooltip('Lọc thư viện'), findsNothing);
        expect(
          tester.takeException(),
          isNull,
          reason: 'More screen must fit the viewport.',
        );
        await tester.tap(
          find.descendant(of: navigation, matching: find.text('Thư viện')),
        );
        await tester.pumpAndSettle();
        expect(find.byType(LibraryScreen), findsOneWidget);
        expect(tester.widget<CupertinoTabBar>(tabs).currentIndex, 0);
        expect(find.byTooltip('Lọc thư viện'), findsOneWidget);

        // This checks actionable controls and bounded layout. It does not assert
        // pixel equality with the original Tachimanga app or native device behavior.
        await tester.tap(find.byTooltip('Lọc thư viện'));
        await tester.pumpAndSettle();
        expect(find.text('Lọc'), findsOneWidget);
        expect(find.text('Sắp xếp'), findsOneWidget);
        expect(find.text('Hiển thị'), findsOneWidget);
        expect(
          tester.takeException(),
          isNull,
          reason: 'Filter sheet must fit the viewport.',
        );

        final filterList = find
            .descendant(
              of: find.byType(LibraryFilterSheet),
              matching: find.byType(ListView),
            )
            .first;
        await tester.scrollUntilVisible(
          find.text('Yêu thích').hitTestable(),
          100,
          scrollable: find
              .descendant(of: filterList, matching: find.byType(Scrollable))
              .first,
        );
        await tester.tap(find.text('Yêu thích'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Sắp xếp'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Tên'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Hiển thị'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Lưới nhỏ'));
        await tester.pumpAndSettle();
        expect(
          tester.takeException(),
          isNull,
          reason: 'Filter, sort and compact-grid changes must remain usable.',
        );
        await tester.tap(find.byTooltip('Đóng bộ lọc'));
        await tester.pumpAndSettle();
        final shown = tester
            .widgetList<BookCover>(find.byType(BookCover))
            .map((cover) => cover.title)
            .toList();
        expect(
          shown,
          [books[1].title, books[0].title],
          reason:
              'Favorite selection and title sort must change actual results.',
        );
        expect(
          tester.takeException(),
          isNull,
          reason: 'Compact populated grid must fit the viewport.',
        );

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        expect((await repository.list()).length, books.length);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
