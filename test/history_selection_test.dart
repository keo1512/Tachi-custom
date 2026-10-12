import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tachi_books/core/theme/app_theme.dart';
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
      'filtered multi-history cancel and clear retain offline data at $width',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = Size(width, 932);
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });
        final repository = MemoryLibraryRepository();
        final first = _book('a', 'Nhóm A');
        final second = _book('b', 'Nhóm B');
        final outside = _book('c', 'Khác');
        for (final book in [first, second, outside]) {
          await repository.save(book);
          await repository.saveChapter(
            book.id,
            0,
            ReaderContent(kind: 'novel', html: '<p>Nội dung ${book.id}</p>'),
          );
        }
        await _show(tester, repository);
        await tester.tap(find.byTooltip('Tìm lịch sử'));
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(CupertinoSearchTextField), 'Nhóm');
        await tester.pumpAndSettle();
        expect(find.text(outside.title), findsNothing);
        await tester.longPress(find.text(first.title));
        await tester.pumpAndSettle();
        expect(find.text('1 đã chọn'), findsOneWidget);
        expect(find.byTooltip('Xóa lịch sử đọc'), findsNothing);
        await tester.tap(find.byTooltip('Chọn tất cả lịch sử đang hiển thị'));
        await tester.pumpAndSettle();
        expect(find.text('2 đã chọn'), findsOneWidget);
        await tester.tap(find.byTooltip('Xóa lịch sử đã chọn'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Hủy'));
        await tester.pumpAndSettle();
        expect((await repository.find(first.id))!.lastRead, first.lastRead);
        expect(find.text('2 đã chọn'), findsOneWidget);
        await tester.tap(find.byTooltip('Xóa lịch sử đã chọn'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Xóa lịch sử'));
        await tester.pumpAndSettle();
        for (final book in [first, second]) {
          final saved = (await repository.find(book.id))!;
          expect(saved.toJson(), book.copyWith(clearLastRead: true).toJson());
          expect(
            (await repository.readChapter(book.id, 0))!.html,
            '<p>Nội dung ${book.id}</p>',
          );
        }
        expect((await repository.find(outside.id))!.toJson(), outside.toJson());
        expect(find.text('Không tìm thấy lịch sử'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      },
    );
  }

  testWidgets(
    'confirmation created before restore cannot clear restored history',
    (tester) async {
      final repository = MemoryLibraryRepository();
      final original = _book('same', 'Truyện trước khôi phục');
      await repository.save(original);
      await _show(tester, repository);
      await tester.longPress(find.text(original.title));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Xóa lịch sử đã chọn'));
      await tester.pumpAndSettle();
      await repository.clear();
      final restored = original.copyWith(
        title: 'Truyện khôi phục',
        notes: 'Giữ nguyên',
      );
      await repository.save(restored);
      await tester.tap(find.text('Xóa lịch sử'));
      await tester.pumpAndSettle();
      expect((await repository.find(original.id))!.toJson(), restored.toJson());
      expect(find.text('Truyện khôi phục'), findsOneWidget);
      expect(find.textContaining('khôi phục'), findsWidgets);
      expect(find.byTooltip('Xóa lịch sử đã chọn'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}

LibraryBook _book(String id, String title) => LibraryBook(
  id: id,
  title: title,
  engine: 'local',
  currentChapter: 0,
  progress: .3,
  lastRead: DateTime(2026, 10, 10),
  bookmarks: const ['0:0.2000'],
  notes: 'Ghi chú được giữ',
  chapters: const [
    BookChapter(
      id: 'one',
      title: 'Chương một',
      index: 0,
      read: false,
      downloaded: true,
    ),
  ],
);

Future<void> _show(
  WidgetTester tester,
  MemoryLibraryRepository repository,
) async {
  final preferences = await SharedPreferences.getInstance();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        preferencesProvider.overrideWithValue(preferences),
        libraryRepositoryProvider.overrideWithValue(repository),
      ],
      child: MaterialApp(
        theme: appTheme(Brightness.dark),
        home: const HistoryScreen(),
      ),
    ),
  );
  await tester.pumpAndSettle();
}
