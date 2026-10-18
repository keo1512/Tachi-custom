import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tachi_books/core/theme/app_theme.dart';
import 'package:tachi_books/features/library/data/library_repository.dart';
import 'package:tachi_books/features/library/domain/library_book.dart';
import 'package:tachi_books/features/library/domain/reading_statistics.dart';
import 'package:tachi_books/features/library/presentation/book_detail_header.dart';
import 'package:tachi_books/features/library/presentation/library_view_model.dart';
import 'package:tachi_books/features/settings/settings_controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final action in ['metadata', 'chapter', 'chapters', 'many', 'reset']) {
    for (final status in ['', 'planned', 'reading', 'paused', 'completed']) {
      test(
        '$action uncomplete clears only the explicit completed status ($status)',
        () async {
          SharedPreferences.setMockInitialValues({});
          final preferences = await SharedPreferences.getInstance();
          final repository = MemoryLibraryRepository();
          final original = _book(
            readingState: status,
            completed: true,
            progress: .25,
          ).copyWith(notes: 'Giữ ghi chú', bookmarks: ['0:0.2000']);
          await repository.save(original);
          final content = ReaderContent(kind: 'novel', html: '<p>Đã tải</p>');
          await repository.saveChapter(original.id, 0, content);
          final container = ProviderContainer(
            overrides: [
              preferencesProvider.overrideWithValue(preferences),
              libraryRepositoryProvider.overrideWithValue(repository),
            ],
          );
          addTearDown(container.dispose);
          await container.read(libraryProvider.future);
          final vm = container.read(libraryProvider.notifier);
          switch (action) {
            case 'metadata':
              await vm.updateMetadata(original.id, completed: false);
            case 'chapter':
              await vm.markChapterRead(original.id, 'first', false);
            case 'chapters':
              await vm.markChaptersRead(original.id, ['first'], false);
            case 'many':
              await vm.markManyChaptersRead(
                {
                  original.id: ['first'],
                },
                false,
                expectedRevision: 0,
              );
            case 'reset':
              await vm.resetBookReading(original.id);
          }
          final after = (await repository.find(original.id))!;
          expect(after.completed, false);
          expect(after.readingState, status == 'completed' ? '' : status);
          expect(readingStateOf(after), isNot('completed'));
          expect(after.notes, original.notes);
          expect(after.bookmarks, original.bookmarks);
          expect(after.progress, action == 'reset' ? 0 : original.progress);
          expect(await repository.readChapter(original.id, 0), content);
        },
      );
    }
  }
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
