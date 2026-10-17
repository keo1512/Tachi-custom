import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tachi_books/features/library/application/reading_statistics_controller.dart';
import 'package:tachi_books/features/library/data/backup_configuration.dart';
import 'package:tachi_books/features/library/domain/book_reading_times.dart';
import 'package:tachi_books/features/library/domain/library_book.dart';
import 'package:tachi_books/features/library/domain/reading_statistics.dart';
import 'package:tachi_books/features/settings/presentation/reading_statistics_book_list.dart';

void main() {
  final stats = ReadingStatistics([
    LibraryBook(
      id: 'a',
      title: 'A',
      chapters: [const BookChapter(id: '1', title: '1', index: 0, read: true)],
    ),
    LibraryBook(id: 'b', title: 'B'),
    LibraryBook(id: 'c', title: 'C'),
  ], readingTimes: BookReadingTimes({'a': 60, 'b': 3661}));

  test('time sorts by measured seconds, keeps unrecorded books and never invents legacy attribution', () {
    expect(
      stats.sortedBooks(ReadingStatisticsOrder.duration).map((b) => b.id),
      ['b', 'a', 'c'],
    );
    expect(stats.sortedBooks(ReadingStatisticsOrder.title).map((b) => b.id), [
      'a',
      'b',
      'c',
    ]);
    expect(stats.sortedBooks(ReadingStatisticsOrder.chapters).first.id, 'a');
    expect(stats.readingSecondsOf(stats.books.last), 0);
    expect(stats.longestReadBooks.map((b) => b.id), ['b', 'a']);
    expect(readingDurationLabel(3661), '1 giờ 1 phút');
    expect(readingDurationLabel(0), 'Chưa ghi nhận');
    final config = BackupConfiguration.fromJson({
      'version': 1,
      'preferences': {
        'readSeconds:2026-10-17': 9999,
        BookReadingTimes.preferenceKey: stats.readingTimes.encode(),
      },
    });
    expect(
      BookReadingTimes.decode(
        config.values[BookReadingTimes.preferenceKey] as String,
      ).of('b'),
      3661,
    );
    for (final raw in ['[]', '{"b":-1}', '{"b":1.5}', '{"b":"10"}']) {
      expect(() => BookReadingTimes.decode(raw), throwsFormatException);
    }
  });

  testWidgets(
    'book statistics show time and allow sorting on a small screen with large text',
    (tester) async {
      tester.view.physicalSize = const Size(320, 932);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            readingStatisticsProvider.overrideWith((ref) async => stats),
          ],
          child: MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(1.5)),
              child: child!,
            ),
            home: const ReadingStatisticsBookList(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        tester.getTopLeft(find.text('B')).dy,
        lessThan(tester.getTopLeft(find.text('A')).dy),
      );
      expect(find.text('Thời lượng đọc: 1 giờ 1 phút'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('statistics-sort')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Tên truyện').last);
      await tester.pumpAndSettle();
      expect(
        tester.getTopLeft(find.text('A')).dy,
        lessThan(tester.getTopLeft(find.text('B')).dy),
      );
      expect(tester.takeException(), isNull);
    },
  );
}
