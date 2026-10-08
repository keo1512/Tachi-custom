import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tachi_books/app.dart';
import 'package:tachi_books/core/widgets/book_cover.dart';
import 'package:tachi_books/features/library/data/library_repository.dart';
import 'package:tachi_books/features/library/domain/library_book.dart';
import 'package:tachi_books/features/library/presentation/book_detail_screen.dart';
import 'package:tachi_books/features/library/presentation/library_view_model.dart';
import 'package:tachi_books/features/reader/presentation/reader_screen.dart';
import 'package:tachi_books/features/settings/settings_controller.dart';

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

  testWidgets(
    'download filter and newest sort open the original chapter and save its progress',
    (tester) async {
      final fixture = await _openDetail(tester);
      await tester.tap(find.byTooltip('Lọc và sắp xếp chương'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(
          of: find.byType(SegmentedButton<String>),
          matching: find.text('Đã tải'),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Sắp xếp'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Chương mới trước'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Tùy chọn chương'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Đóng'));
      await tester.pumpAndSettle();

      expect(_chapterTitles(tester), [
        'Chương ba: Kết thúc',
        'Chương một: Mở đầu',
      ]);
      expect(
        (await fixture.repository.find(fixture.book.id))!.toJson(),
        fixture.book.toJson(),
        reason: 'Changing the visible chapter list must not write reading progress.',
      );
      await tester.tap(find.text('Chương ba: Kết thúc'));
      await tester.pumpAndSettle();
      await _expectOriginalChapter(tester, fixture, 2);
    },
  );

  testWidgets(
    'chapter title search opens the matching original index instead of filtered row zero',
    (tester) async {
      final fixture = await _openDetail(tester);
      await tester.tap(find.byTooltip('Tìm chương'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byType(CupertinoSearchTextField),
        'Bước ngoặt',
      );
      await tester.pumpAndSettle();

      expect(_chapterTitles(tester), ['Chương hai: Bước ngoặt']);
      expect(
        (await fixture.repository.find(fixture.book.id))!.toJson(),
        fixture.book.toJson(),
        reason: 'Searching chapters must preserve stored progress and chapter order.',
      );
      await tester.tap(find.text('Chương hai: Bước ngoặt'));
      await tester.pumpAndSettle();
      await _expectOriginalChapter(tester, fixture, 1);
    },
  );
}

typedef _Fixture = ({
  MemoryLibraryRepository repository,
  LibraryBook book,
  LibraryBook otherBook,
  List<String> bodies,
});

Future<_Fixture> _openDetail(WidgetTester tester) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(390, 844);
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
  final prefs = await SharedPreferences.getInstance();
  final repository = MemoryLibraryRepository();
  final book = LibraryBook(
    id: 'chapter-navigation',
    title: 'Kiểm tra điều hướng chương',
    author: 'Tác giả mẫu',
    currentChapter: 0,
    progress: .125,
    lastRead: DateTime(2026, 10, 7, 12),
    favorite: true,
    bookmarks: const ['0:0.3750', '2:0.2500'],
    chapters: const [
      BookChapter(
        id: 'original-first',
        title: 'Chương một: Mở đầu',
        index: 0,
        downloaded: true,
      ),
      BookChapter(
        id: 'original-middle',
        title: 'Chương hai: Bước ngoặt',
        index: 1,
      ),
      BookChapter(
        id: 'original-last',
        title: 'Chương ba: Kết thúc',
        index: 2,
        downloaded: true,
      ),
    ],
  );
  final otherBook = LibraryBook(
    id: 'other-book',
    title: 'Sách khác giữ nguyên tiến độ',
    currentChapter: 1,
    progress: .8,
    lastRead: DateTime(2026, 10, 6),
    bookmarks: const ['1:0.6000'],
    chapters: const [
      BookChapter(id: 'other-first', title: 'Một', index: 0),
      BookChapter(id: 'other-second', title: 'Hai', index: 1),
    ],
  );
  final bodies = [
    'Nội dung riêng chương đầu',
    'Nội dung riêng chương giữa',
    'Nội dung riêng chương cuối',
  ];
  await repository.save(book);
  await repository.save(otherBook);
  for (var index = 0; index < bodies.length; index++) {
    await repository.saveChapter(
      book.id,
      index,
      ReaderContent(kind: 'novel', html: '<p>${bodies[index]}</p>'),
    );
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
  await tester.tap(
    find.byWidgetPredicate(
      (widget) => widget is BookCover && widget.title == book.title,
    ),
  );
  await tester.pumpAndSettle();
  expect(find.byType(BookDetailScreen), findsOneWidget);
  expect(tester.takeException(), isNull);
  return (
    repository: repository,
    book: book,
    otherBook: otherBook,
    bodies: bodies,
  );
}

List<String> _chapterTitles(WidgetTester tester) => tester
    .widgetList<ListTile>(
      find.descendant(
        of: find.byType(BookDetailScreen),
        matching: find.byType(ListTile),
      ),
    )
    .map((tile) => (tile.title! as Text).data!)
    .toList();

Future<void> _expectOriginalChapter(
  WidgetTester tester,
  _Fixture fixture,
  int index,
) async {
  final reader = tester.widget<ReaderScreen>(find.byType(ReaderScreen));
  expect(reader.id, fixture.book.id);
  expect(reader.chapter, index);
  for (var chapter = 0; chapter < fixture.bodies.length; chapter++) {
    expect(
      find.text(fixture.bodies[chapter], findRichText: true),
      chapter == index ? findsOneWidget : findsNothing,
    );
    expect(
      (await fixture.repository.readChapter(fixture.book.id, chapter))!.html,
      '<p>${fixture.bodies[chapter]}</p>',
    );
  }
  final saved = (await fixture.repository.find(fixture.book.id))!;
  expect(saved.currentChapter, index);
  expect(
    saved.progress,
    closeTo(index / fixture.book.chapters.length, .000001),
  );
  expect(
    saved.chapters.map((chapter) => chapter.toJson()).toList(),
    fixture.book.chapters.map((chapter) => chapter.toJson()).toList(),
  );
  expect(
    saved.chapters[saved.currentChapter].id,
    fixture.book.chapters[index].id,
  );
  expect(saved.bookmarks, fixture.book.bookmarks);
  expect(saved.favorite, fixture.book.favorite);
  expect(saved.lastRead, isNotNull);
  expect(
    (await fixture.repository.find(fixture.otherBook.id))!.toJson(),
    fixture.otherBook.toJson(),
  );
  expect(tester.takeException(), isNull);
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pumpAndSettle();
  expect(tester.takeException(), isNull);
}
