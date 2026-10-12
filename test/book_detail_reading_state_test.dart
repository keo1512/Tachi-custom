import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tachi_books/core/theme/app_theme.dart';
import 'package:tachi_books/features/library/domain/library_book.dart';
import 'package:tachi_books/features/library/presentation/book_detail_header.dart';

void main() {
  final cases = <({String name, LibraryBook book, String label})>[
    (
      name: 'explicit planned keeps existing reading progress',
      book: _book(readingState: 'planned', progress: .25),
      label: 'Dự định đọc',
    ),
    (
      name: 'explicit reading before the first chapter',
      book: _book(readingState: 'reading'),
      label: 'Đang đọc',
    ),
    (
      name: 'explicit paused keeps existing reading progress',
      book: _book(readingState: 'paused', progress: .25),
      label: 'Tạm dừng',
    ),
    (
      name: 'explicit completed without the legacy completion flag',
      book: _book(readingState: 'completed'),
      label: 'Đã hoàn thành',
    ),
    (
      name: 'legacy unread falls back to planned',
      book: _book(),
      label: 'Dự định đọc',
    ),
    (
      name: 'legacy reading progress falls back to reading',
      book: _book(progress: .25),
      label: 'Đang đọc',
    ),
    (
      name: 'legacy completion takes precedence over a paused state',
      book: _book(readingState: 'paused', completed: true),
      label: 'Đã hoàn thành',
    ),
  ];
  for (final size in const [Size(320, 568), Size(430, 932)]) {
    for (final value in cases) {
      testWidgets('detail shows ${value.name} at $size', (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = size;
        addTearDown(tester.view.reset);
        final original = value.book.toJson();
        await tester.pumpWidget(
          MaterialApp(
            theme: appTheme(Brightness.dark),
            home: MediaQuery(
              data: MediaQueryData(
                size: size,
                textScaler: const TextScaler.linear(1.5),
              ),
              child: Scaffold(
                body: SingleChildScrollView(
                  child: BookDetailHeader(
                    book: value.book,
                    descriptionExpanded: false,
                    onToggleDescription: () {},
                    onFavorite: () {},
                    onEditNotes: () {},
                    onResume: () {},
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final state = find.byKey(const ValueKey('book-detail-reading-state'));
        await tester.ensureVisible(state);
        await tester.pumpAndSettle();
        expect(
          tester.widget<Text>(state).data,
          'Trạng thái đọc: ${value.label}',
        );
        expect(
          find.text(
            value.book.completed
                ? 'Đã đọc xong'
                : '${(value.book.progress * 100).round()}% đã đọc',
          ),
          findsOneWidget,
        );
        expect(value.book.toJson(), original);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      });
    }
  }
}

LibraryBook _book({
  String readingState = '',
  double progress = 0,
  bool completed = false,
}) => LibraryBook(
  id: 'reading-state',
  title: 'Một truyện có tên dài để kiểm tra thông tin trên màn hình nhỏ',
  author: 'Tác giả mẫu',
  artist: 'Họa sĩ mẫu',
  alternativeTitles: const ['Tên khác thứ nhất', 'Tên khác thứ hai'],
  readingState: readingState,
  progress: progress,
  completed: completed,
  chapters: const [BookChapter(id: 'first', title: 'Chương đầu', index: 0)],
);
