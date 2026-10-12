import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tachi_books/features/library/application/reading_statistics_controller.dart';
import 'package:tachi_books/features/library/data/library_repository.dart';
import 'package:tachi_books/features/library/data/library_snapshot.dart';
import 'package:tachi_books/features/library/domain/library_book.dart';
import 'package:tachi_books/features/library/presentation/library_view_model.dart';
import 'package:tachi_books/features/settings/presentation/reading_info_screen.dart';
import 'package:tachi_books/features/settings/presentation/reading_statistics_book_list.dart';
import 'package:tachi_books/features/settings/settings_controller.dart';

void main() {
  for (final width in [320.0, 430.0]) {
    testWidgets(
      'statistics chart and details fit ${width.toInt()}px with 150 percent text',
      (tester) async {
        final fixture = await _mount(tester, width: width, scale: 1.5);
        expect(find.text('Thông tin Đọc'), findsOneWidget);
        await tester.scrollUntilVisible(find.text('30 ngày'), 160);
        await tester.tap(find.text('30 ngày'));
        await tester.pumpAndSettle();
        await _scrollTo(
          tester,
          find.byKey(const ValueKey('statistics-manage-books')),
        );
        await tester.tap(find.byKey(const ValueKey('statistics-manage-books')));
        await tester.pumpAndSettle();
        expect(find.text('Thống kê từng truyện'), findsOneWidget);
        expect(find.textContaining('1 chương offline'), findsOneWidget);
        expect(find.text('Tạm dừng'), findsOneWidget);
        expect(find.text('8.0/10 · Đổi đánh giá'), findsOneWidget);
        expect(tester.takeException(), isNull);
        expect((await fixture.repository.find('book'))!.readingState, 'paused');
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets(
    'user status and rating edits persist; cancel leaves stored rating unchanged',
    (tester) async {
      final fixture = await _mount(tester, direct: true);
      await tester.tap(find.byKey(const ValueKey('statistics-state-book')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('statistics-state-reading')));
      await tester.pumpAndSettle();
      expect((await fixture.repository.find('book'))!.readingState, 'reading');
      await tester.tap(find.byKey(const ValueKey('statistics-rating-book')));
      await tester.pumpAndSettle();
      final slider = tester.widget<CupertinoSlider>(
        find.byKey(const ValueKey('statistics-rating-slider')),
      );
      slider.onChanged!(6.5);
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('statistics-rating-save')));
      await tester.pumpAndSettle();
      expect((await fixture.repository.find('book'))!.rating, 6.5);
      await tester.tap(find.byKey(const ValueKey('statistics-rating-book')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Hủy'));
      await tester.pumpAndSettle();
      expect((await fixture.repository.find('book'))!.rating, 6.5);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'an open status choice cannot change library replaced after preview',
    (tester) async {
      final fixture = await _mount(tester, direct: true);
      await tester.tap(find.byKey(const ValueKey('statistics-state-book')));
      await tester.pumpAndSettle();
      final current = await fixture.repository.snapshot();
      await fixture.repository.replaceSnapshot(
        LibrarySnapshot([
          LibrarySnapshotEntry(
            current.entries.single.book.copyWith(
              readingState: 'planned',
              rating: 4,
            ),
            current.entries.single.contents,
          ),
        ]),
        expectedFingerprint: current.fingerprint,
      );
      await tester.tap(
        find.byKey(const ValueKey('statistics-state-completed')),
      );
      await tester.pumpAndSettle();
      final book = (await fixture.repository.find('book'))!;
      expect(book.readingState, 'planned');
      expect(book.completed, false);
      expect(book.rating, 4);
      expect(find.byType(SnackBar), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}

class _Fixture {
  _Fixture(this.repository);
  final MemoryLibraryRepository repository;
}

Future<void> _scrollTo(WidgetTester tester, Finder target) async {
  for (var count = 0; count < 30; count++) {
    if (target.evaluate().isNotEmpty) {
      final point = tester.getCenter(target);
      if (point.dy > 100 && point.dy < 820) return;
    }
    await tester.drag(find.byType(ListView).first, const Offset(0, -300));
    await tester.pumpAndSettle();
  }
  throw StateError('Cannot scroll to statistics action.');
}

Future<_Fixture> _mount(
  WidgetTester tester, {
  double width = 430,
  double scale = 1,
  bool direct = false,
}) async {
  tester.view.physicalSize = Size(width, 932);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  SharedPreferences.setMockInitialValues({
    'readSeconds:2026-10-12': 120,
    'readSeconds:2026-10-11': 60,
  });
  final preferences = await SharedPreferences.getInstance();
  final repository = MemoryLibraryRepository();
  await repository.save(
    LibraryBook(
      id: 'book',
      title: 'Một truyện kiểm tra có tiêu đề dài',
      readingState: 'paused',
      rating: 8,
      chapters: const [
        BookChapter(
          id: 'chapter',
          title: 'Một',
          index: 0,
          downloaded: true,
          read: true,
        ),
      ],
    ),
  );
  await repository.saveChapter(
    'book',
    0,
    ReaderContent(kind: 'novel', html: '<p>Nội dung offline.</p>'),
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        preferencesProvider.overrideWithValue(preferences),
        libraryRepositoryProvider.overrideWithValue(repository),
        readingStatisticsClockProvider.overrideWithValue(
          () => DateTime(2026, 10, 12, 17),
        ),
      ],
      child: MaterialApp(
        theme: ThemeData(
          brightness: Brightness.dark,
          platform: TargetPlatform.iOS,
        ),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: direct
            ? const ReadingStatisticsBookList()
            : const ReadingInfoScreen(),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return _Fixture(repository);
}
