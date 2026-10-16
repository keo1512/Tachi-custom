import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tachi_books/app.dart';
import 'package:tachi_books/core/widgets/book_cover.dart';
import 'package:tachi_books/features/downloads/presentation/download_queue_controller.dart';
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
    'personal notes survive editing and can be cleared without changing chapters',
    (tester) async {
      final fixture = await _openDetail(tester);
      await tester.tap(find.byTooltip('Tùy chọn'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Ghi chú cá nhân'));
      await tester.tap(find.text('Ghi chú cá nhân'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byType(CupertinoTextField),
        'Đọc tiếp sau\nChương thứ hai',
      );
      await tester.tap(find.text('Lưu'));
      await tester.pumpAndSettle();
      var saved = (await fixture.repository.find(fixture.book.id))!;
      expect(saved.notes, 'Đọc tiếp sau\nChương thứ hai');
      expect(
        saved.chapters.map((c) => c.toJson()),
        fixture.book.chapters.map((c) => c.toJson()),
      );
      expect(saved.progress, fixture.book.progress);
      await tester.tap(find.byTooltip('Tùy chọn'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Ghi chú cá nhân').last);
      await tester.tap(find.text('Ghi chú cá nhân').last);
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(CupertinoTextField), '');
      await tester.tap(find.text('Lưu'));
      await tester.pumpAndSettle();
      saved = (await fixture.repository.find(fixture.book.id))!;
      expect(saved.notes, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'detail bulk download uses the durable queue and keeps reading metadata',
    (tester) async {
      final pending = Completer<void>();
      final executed = <String>[];
      final fixture = await _openDetail(
        tester,
        engine: 'vbook',
        executor: (book, index) async {
          executed.add(book.chapters[index].id);
          await pending.future;
        },
      );
      await tester.tap(find.byTooltip('Tải chương'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Tất cả chương chưa tải'));
      await tester.pumpAndSettle();
      final container = ProviderScope.containerOf(
        tester.element(find.byType(BookDetailScreen)),
      );
      final queue = container.read(downloadQueueProvider);
      expect(queue.running, isTrue);
      expect(queue.tasks.map((task) => task.chapterId), ['original-middle']);
      expect(executed, ['original-middle']);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('downloadQueueV1'), contains('original-middle'));
      expect(
        (await fixture.repository.find(fixture.book.id))!
            .copyWith(chapterListPreferences: const {})
            .toJson(),
        fixture.book.copyWith(chapterListPreferences: const {}).toJson(),
      );
      expect(
        (await fixture.repository.find(fixture.otherBook.id))!.toJson(),
        fixture.otherBook.toJson(),
      );
      pending.complete();
      await tester.pumpAndSettle();
      expect(container.read(downloadQueueProvider).tasks, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );

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
      await tester.ensureVisible(find.text('Giảm dần'));
      await tester.tap(find.text('Giảm dần'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Đóng'));
      await tester.pumpAndSettle();

      expect(_chapterTitles(tester), [
        'Chương ba: Kết thúc',
        'Chương một: Mở đầu',
      ]);
      expect(
        (await fixture.repository.find(fixture.book.id))!
            .copyWith(chapterListPreferences: const {})
            .toJson(),
        fixture.book.copyWith(chapterListPreferences: const {}).toJson(),
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
        (await fixture.repository.find(fixture.book.id))!
            .copyWith(chapterListPreferences: const {})
            .toJson(),
        fixture.book.copyWith(chapterListPreferences: const {}).toJson(),
        reason: 'Searching chapters must preserve stored progress and chapter order.',
      );
      await tester.tap(find.text('Chương hai: Bước ngoặt'));
      await tester.pumpAndSettle();
      await _expectOriginalChapter(tester, fixture, 1);
    },
  );

  testWidgets(
    'read filter respects imported per-chapter flags instead of sequential inference',
    (tester) async {
      final fixture = await _openDetail(tester);
      await fixture.repository.save(
        fixture.book.copyWith(
          currentChapter: 2,
          progress: .9,
          chapters: [
            fixture.book.chapters[0].copyWith(read: false),
            fixture.book.chapters[1].copyWith(read: true),
            fixture.book.chapters[2].copyWith(read: false),
          ],
        ),
      );
      final container = ProviderScope.containerOf(
        tester.element(find.byType(BookDetailScreen)),
      );
      await container.read(libraryProvider.notifier).refresh();
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Lọc và sắp xếp chương'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(
          of: find.byType(SegmentedButton<String>),
          matching: find.text('Đã đọc'),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Đóng'));
      await tester.pumpAndSettle();
      expect(_chapterTitles(tester), ['Chương hai: Bước ngoặt']);
      expect(
        (await fixture.repository.find(fixture.book.id))!.chapters
            .map((chapter) => chapter.read),
        [false, true, false],
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'chapter menu marks the original chapter under filtering and reverse sort',
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
      await tester.ensureVisible(find.text('Giảm dần'));
      await tester.tap(find.text('Giảm dần'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Đóng'));
      await tester.pumpAndSettle();
      expect(_chapterTitles(tester), [
        'Chương ba: Kết thúc',
        'Chương một: Mở đầu',
      ]);

      await tester.tap(find.byTooltip('Thao tác Chương ba: Kết thúc'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Hủy'));
      await tester.pumpAndSettle();
      expect(
        (await fixture.repository.find(fixture.book.id))!
            .copyWith(chapterListPreferences: const {})
            .toJson(),
        fixture.book.copyWith(chapterListPreferences: const {}).toJson(),
      );
      await tester.tap(find.byTooltip('Thao tác Chương ba: Kết thúc'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Đánh dấu đã đọc'));
      await tester.pumpAndSettle();
      await _expectReadAction(tester, fixture, 2, true);

      await tester.tap(find.byTooltip('Thao tác Chương ba: Kết thúc'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Đánh dấu chưa đọc'));
      await tester.pumpAndSettle();
      await _expectReadAction(tester, fixture, 2, false);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'mark unread updates the read filter without changing the resume position',
    (tester) async {
      final fixture = await _openDetail(tester);
      final saved = fixture.book.copyWith(
        currentChapter: 2,
        progress: .9,
        chapters: [
          fixture.book.chapters[0].copyWith(read: false),
          fixture.book.chapters[1].copyWith(read: true),
          fixture.book.chapters[2].copyWith(read: false),
        ],
      );
      await fixture.repository.save(saved);
      final container = ProviderScope.containerOf(
        tester.element(find.byType(BookDetailScreen)),
      );
      await container.read(libraryProvider.notifier).refresh();
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Lọc và sắp xếp chương'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(
          of: find.byType(SegmentedButton<String>),
          matching: find.text('Đã đọc'),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Đóng'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Thao tác Chương hai: Bước ngoặt'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Đánh dấu chưa đọc'));
      await tester.pumpAndSettle();
      expect(_chapterTitles(tester), isEmpty);
      expect(find.text('Không có chương phù hợp'), findsOneWidget);
      expect(
        (await fixture.repository.find(fixture.book.id))!
            .copyWith(chapterListPreferences: const {})
            .toJson(),
        saved
            .copyWith(
              chapters: [
                saved.chapters[0],
                saved.chapters[1].copyWith(read: false),
                saved.chapters[2],
              ],
            )
            .toJson(),
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'chapter action opened before a replacement cannot modify the new library',
    (tester) async {
      final fixture = await _openDetail(tester);
      await tester.tap(find.byTooltip('Thao tác Chương ba: Kết thúc'));
      await tester.pumpAndSettle();
      await fixture.repository.clear();
      final replacement = fixture.book.copyWith(
        title: 'Thư viện được khôi phục',
        notes: 'Dữ liệu từ thiết bị khác',
        chapters: [
          fixture.book.chapters[0].copyWith(read: true),
          fixture.book.chapters[1].copyWith(read: true),
          fixture.book.chapters[2].copyWith(read: false),
        ],
      );
      await fixture.repository.save(replacement);
      final container = ProviderScope.containerOf(
        tester.element(find.byType(BookDetailScreen)),
      );
      await container.read(libraryProvider.notifier).refresh();
      await tester.pumpAndSettle();
      await tester.tap(find.text('Đánh dấu đã đọc'));
      await tester.pumpAndSettle();
      expect(
        (await fixture.repository.find(fixture.book.id))!.toJson(),
        replacement.toJson(),
      );
      expect(find.byType(ReaderScreen), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );
}

Future<void> _expectReadAction(
  WidgetTester tester,
  _Fixture fixture,
  int index,
  bool read,
) async {
  final saved = (await fixture.repository.find(fixture.book.id))!;
  expect(
    saved.copyWith(chapterListPreferences: const {}).toJson(),
    fixture.book
        .copyWith(
          chapters: [
            for (var i = 0; i < fixture.book.chapters.length; i++)
              i == index
                  ? fixture.book.chapters[i].copyWith(read: read)
                  : fixture.book.chapters[i].copyWith(read: false),
          ],
        )
        .toJson(),
  );
  for (var i = 0; i < fixture.bodies.length; i++) {
    expect(
      (await fixture.repository.readChapter(fixture.book.id, i))!.html,
      '<p>${fixture.bodies[i]}</p>',
    );
  }
  expect(
    (await fixture.repository.find(fixture.otherBook.id))!.toJson(),
    fixture.otherBook.toJson(),
  );
  expect(find.byType(ReaderScreen), findsNothing);
  expect(tester.takeException(), isNull);
}

typedef _Fixture = ({
  MemoryLibraryRepository repository,
  LibraryBook book,
  LibraryBook otherBook,
  List<String> bodies,
});

Future<_Fixture> _openDetail(
  WidgetTester tester, {
  String engine = 'local',
  Future<void> Function(LibraryBook, int)? executor,
}) async {
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
    engine: engine,
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
        if (executor != null)
          downloadJobExecutorProvider.overrideWithValue(executor),
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
    fixture.book.chapters.indexed
        .map(
          (entry) => entry.$2
              .copyWith(
                downloaded: entry.$1 == index ? true : entry.$2.downloaded,
              )
              .toJson(),
        )
        .toList(),
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
