import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tachi_books/app.dart';
import 'package:tachi_books/core/widgets/book_cover.dart';
import 'package:tachi_books/features/library/data/library_repository.dart';
import 'package:tachi_books/features/library/domain/library_book.dart';
import 'package:tachi_books/features/library/domain/book_reading_times.dart';
import 'package:tachi_books/features/library/application/reading_statistics_controller.dart';
import 'package:tachi_books/features/library/presentation/library_view_model.dart';
import 'package:tachi_books/features/reader/presentation/reader_screen.dart';
import 'package:tachi_books/features/settings/settings_controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('flutter_tts'),
          (_) async => 1,
        );
  });

  testWidgets(
    'per-book time splits midnight, pauses in background and counts resumed sessions once',
    (tester) async {
      var clock = DateTime(2030, 1, 1, 23, 59, 55);
      final fixture = await _open(tester, false, clock: () => clock);
      clock = clock.add(const Duration(seconds: 12));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pumpAndSettle();
      expect(
        BookReadingTimes.decode(
          fixture.preferences.getString(BookReadingTimes.preferenceKey),
        ).of(fixture.book.id),
        12,
      );
      expect(fixture.preferences.getInt('readSeconds:2030-1-1'), 5);
      expect(fixture.preferences.getInt('readSeconds:2030-1-2'), 7);
      clock = clock.add(const Duration(minutes: 10));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      clock = clock.add(const Duration(seconds: 8));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pumpAndSettle();
      expect(
        BookReadingTimes.decode(
          fixture.preferences.getString(BookReadingTimes.preferenceKey),
        ).of(fixture.book.id),
        20,
      );
      expect(fixture.preferences.getInt('readSeconds:2030-1-2'), 15);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      await _dispose(tester, fixture.container);
    },
  );

  testWidgets(
    'restore invalidates time from a reader opened on the old library',
    (tester) async {
      var clock = DateTime(2030, 1, 1, 10);
      final fixture = await _open(tester, false, clock: () => clock);
      final snapshot = await fixture.repo.snapshot();
      await fixture.repo.replaceSnapshot(
        snapshot,
        expectedFingerprint: snapshot.fingerprint,
      );
      clock = clock.add(const Duration(minutes: 5));
      await _dispose(tester, fixture.container);
      expect(
        fixture.preferences.getString(BookReadingTimes.preferenceKey),
        isNull,
      );
      expect(_readSeconds(fixture.preferences), fixture.seconds);
    },
  );

  for (final private in [false, true]) {
    testWidgets(
      '${private ? 'incognito' : 'normal'} reader preserves privacy policy through chapter changes and reopening',
      (tester) async {
        final fixture = await _open(tester, private);
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 1100)),
        );
        await tester.tap(find.byTooltip('Chương tiếp theo'));
        await tester.pumpAndSettle();
        expect(
          find.text('Nội dung chương thứ hai', findRichText: true),
          findsOneWidget,
        );
        await tester.tap(find.byTooltip('Quay lại'));
        await tester.pumpAndSettle();
        final saved = (await fixture.repo.find(fixture.book.id))!;
        if (private) {
          expect(
            saved.toJson(),
            fixture.book.toJson(),
            reason:
                'Private auto-save must preserve all prior reading metadata.',
          );
          expect(_readSeconds(fixture.preferences), fixture.seconds);
          expect(
            fixture.preferences.getString(BookReadingTimes.preferenceKey),
            isNull,
          );
        } else {
          expect(saved.currentChapter, 1);
          expect(
            BookReadingTimes.decode(
              fixture.preferences.getString(BookReadingTimes.preferenceKey),
            ).of(fixture.book.id),
            greaterThan(0),
          );
          expect(saved.progress, .5);
          expect(saved.lastRead!.isAfter(fixture.book.lastRead!), true);
          expect(
            _readSeconds(fixture.preferences),
            greaterThan(fixture.seconds),
          );
        }
        expect(saved.bookmarks, fixture.book.bookmarks);
        expect(
          (await fixture.repo.find(fixture.other.id))!.toJson(),
          fixture.other.toJson(),
        );
        for (var index = 0; index < 2; index++) {
          expect(
            (await fixture.repo.readChapter(fixture.book.id, index))!.html,
            fixture.contents[index],
          );
        }
        await tester.tap(find.text('Đọc tiếp'));
        await tester.pumpAndSettle();
        expect(
          tester.widget<ReaderScreen>(find.byType(ReaderScreen)).chapter,
          private ? 0 : 1,
        );
        expect(
          find.text(
            private ? 'Nội dung chương thứ nhất' : 'Nội dung chương thứ hai',
            findRichText: true,
          ),
          findsOneWidget,
        );
        await _dispose(tester, fixture.container);
        if (private) {
          expect(
            (await fixture.repo.find(fixture.book.id))!.toJson(),
            fixture.book.toJson(),
          );
          expect(_readSeconds(fixture.preferences), fixture.seconds);
        }
      },
    );
  }

  testWidgets(
    'private session keeps its policy after setting changes and explicit bookmarks remain deliberate saves',
    (tester) async {
      final fixture = await _open(tester, true);
      await fixture.container
          .read(settingsProvider.notifier)
          .update(incognitoMode: false);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Đánh dấu trang'));
      await tester.pumpAndSettle();
      final marked = (await fixture.repo.find(fixture.book.id))!;
      expect(marked.bookmarks, contains('0:0.5000'));
      expect(marked.currentChapter, fixture.book.currentChapter);
      expect(marked.progress, fixture.book.progress);
      expect(marked.lastRead, fixture.book.lastRead);
      await tester.tap(find.byTooltip('Chương tiếp theo'));
      await tester.pumpAndSettle();
      expect(
        (await fixture.repo.find(fixture.book.id))!.currentChapter,
        0,
        reason: 'Turning off the setting cannot make an already private session write progress.',
      );
      await tester.tap(find.byTooltip('Quay lại'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Đọc tiếp'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Chương tiếp theo'));
      await tester.pumpAndSettle();
      expect(
        (await fixture.repo.find(fixture.book.id))!.currentChapter,
        1,
        reason: 'The newly opened session uses the updated normal mode.',
      );
      expect(
        (await fixture.repo.find(fixture.book.id))!.bookmarks,
        marked.bookmarks,
      );
      await _dispose(tester, fixture.container);
    },
  );

  testWidgets(
    'history glasses toggles persisted incognito mode and keeps previous history visible',
    (tester) async {
      final fixture = await _open(tester, false);
      await tester.tap(find.byTooltip('Quay lại'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Quay lại'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Lịch sử').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Bật chế độ ẩn danh'));
      await tester.pumpAndSettle();
      expect(fixture.preferences.getBool('incognitoMode'), true);
      expect(find.byTooltip('Tắt chế độ ẩn danh'), findsOneWidget);
      expect(
        find.textContaining('Phiên đọc mở mới không lưu tiến độ'),
        findsOneWidget,
      );
      expect(find.text(fixture.book.title), findsOneWidget);
      expect((await fixture.repo.find(fixture.book.id))!.lastRead, isNotNull);
      final restart = ProviderContainer(
        overrides: [preferencesProvider.overrideWithValue(fixture.preferences)],
      );
      expect(restart.read(settingsProvider).incognitoMode, true);
      restart.dispose();
      await tester.tap(find.byTooltip('Tắt chế độ ẩn danh'));
      await tester.pumpAndSettle();
      expect(fixture.preferences.getBool('incognitoMode'), false);
      expect(
        find.textContaining('Phiên đọc mở mới không lưu tiến độ'),
        findsNothing,
      );
      await _dispose(tester, fixture.container);
    },
  );
}

int _readSeconds(SharedPreferences prefs) => prefs
    .getKeys()
    .where((key) => key.startsWith('readSeconds:'))
    .fold(0, (sum, key) => sum + (prefs.getInt(key) ?? 0));

typedef _Fixture = ({
  MemoryLibraryRepository repo,
  LibraryBook book,
  LibraryBook other,
  List<String> contents,
  SharedPreferences preferences,
  ProviderContainer container,
  int seconds,
});

Future<_Fixture> _open(
  WidgetTester tester,
  bool incognito, {
  DateTime Function()? clock,
}) async {
  final now = DateTime.now();
  SharedPreferences.setMockInitialValues({
    'incognitoMode': incognito,
    'readSeconds:${now.year}-${now.month}-${now.day}': 37,
    'readSeconds:2020-1-1': 11,
  });
  final preferences = await SharedPreferences.getInstance();
  final repo = MemoryLibraryRepository();
  final book = LibraryBook(
    id: 'privacy-reader',
    title: 'Sách kiểm tra ẩn danh',
    currentChapter: 0,
    progress: .25,
    lastRead: DateTime(2020, 1, 1),
    bookmarks: const ['1:0.1250'],
    chapters: const [
      BookChapter(
        id: 'first',
        title: 'Chương thứ nhất',
        index: 0,
        downloaded: true,
      ),
      BookChapter(
        id: 'second',
        title: 'Chương thứ hai',
        index: 1,
        downloaded: true,
      ),
    ],
  );
  final other = LibraryBook(
    id: 'other-private-book',
    title: 'Sách khác',
    progress: .75,
    lastRead: DateTime(2020, 1, 2),
    chapters: const [BookChapter(id: 'other', title: 'Khác', index: 0)],
  );
  final contents = [
    '<p>Nội dung chương thứ nhất</p>',
    '<p>Nội dung chương thứ hai</p>',
  ];
  await repo.save(book);
  await repo.save(other);
  for (var index = 0; index < contents.length; index++) {
    await repo.saveChapter(
      book.id,
      index,
      ReaderContent(kind: 'novel', html: contents[index]),
    );
  }
  final container = ProviderContainer(
    overrides: [
      if (clock != null)
        readingStatisticsClockProvider.overrideWithValue(clock),
      preferencesProvider.overrideWithValue(preferences),
      libraryRepositoryProvider.overrideWithValue(repo),
    ],
  );
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
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
  await tester.tap(find.text('Đọc tiếp'));
  await tester.pumpAndSettle();
  expect(find.byType(ReaderScreen), findsOneWidget);
  return (
    repo: repo,
    book: book,
    other: other,
    contents: contents,
    preferences: preferences,
    container: container,
    seconds: 48,
  );
}

Future<void> _dispose(WidgetTester tester, ProviderContainer container) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pumpAndSettle();
  container.dispose();
  expect(tester.takeException(), isNull);
}
