import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tachi_books/core/theme/app_theme.dart';
import 'package:tachi_books/features/downloads/presentation/download_deletion_controller.dart';
import 'package:tachi_books/features/downloads/presentation/download_settings_screen.dart';
import 'package:tachi_books/features/downloads/presentation/downloads_screen.dart';
import 'package:tachi_books/features/library/data/library_repository.dart';
import 'package:tachi_books/features/library/domain/library_book.dart';
import 'package:tachi_books/features/library/presentation/library_view_model.dart';
import 'package:tachi_books/features/settings/settings_controller.dart';

const _image =
    'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jf1kAAAAASUVORK5CYII=';
LibraryBook _book() => LibraryBook(
  id: 'book',
  title: 'Truyện tải',
  kind: 'manga',
  engine: 'tachimanga',
  sourceId: 'source',
  sourceRef: 'book',
  currentChapter: 1,
  progress: .5,
  bookmarks: ['1:.5'],
  chapters: const [
    BookChapter(
      id: 'one',
      title: 'Unprotected',
      index: 7,
      downloaded: true,
      read: true,
    ),
    BookChapter(
      id: 'two',
      title: 'Protected',
      index: 5,
      downloaded: true,
      read: false,
    ),
  ],
);
Future<void> _show(
  WidgetTester tester,
  SharedPreferences prefs,
  LibraryRepository repo,
  Widget screen,
  double width,
) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = Size(width, 750);
  addTearDown(tester.view.reset);
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  for (final width in [320.0, 430.0]) {
    testWidgets(
      'download policies change persistently, manual delete protects bookmarks and local originals at $width',
      (tester) async {
        final prefs = await SharedPreferences.getInstance(),
            repo = MemoryLibraryRepository(),
            book = _book();
        final local = book.copyWith(
          id: 'local',
          title: 'Imported CBZ',
          engine: 'local',
        );
        for (final item in [book, local]) {
          await repo.save(item);
          for (var i = 0; i < 2; i++) {
            await repo.saveChapter(
              item.id,
              i,
              ReaderContent(kind: 'manga', images: [_image]),
            );
          }
        }
        await _show(tester, prefs, repo, const DownloadsScreen(), width);
        await tester.tap(find.byTooltip('Thiết lập tải xuống'));
        await tester.pumpAndSettle();
        expect(find.byType(DownloadSettingsScreen), findsOneWidget);
        await tester.tap(find.text('Tự xóa sau khi đọc'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Xóa khi đánh dấu đã đọc'));
        await tester.pumpAndSettle();
        expect(
          prefs.getString(DownloadDeletionController.preferenceKey),
          contains('"afterReading":true'),
        );
        expect(
          prefs.getString(DownloadDeletionController.preferenceKey),
          contains('"afterManualRead":true'),
        );
        expect(
          prefs.getString(DownloadDeletionController.preferenceKey),
          contains('"protectBookmarks":true'),
        );
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
        await _show(tester, prefs, repo, const RecentDownloadsScreen(), width);
        await tester.tap(find.byTooltip('Xuất CBZ Unprotected').first);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Xóa các chương đã tải của truyện'));
        await tester.pumpAndSettle();
        expect(find.text('Xóa nội dung đã tải?'), findsOneWidget);
        await tester.tap(find.text('Hủy'));
        await tester.pumpAndSettle();
        expect((await repo.find(book.id))!.chapters.first.downloaded, true);
        await tester.tap(find.byTooltip('Xuất CBZ Unprotected').first);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Xóa các chương đã tải của truyện'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Xóa nội dung'));
        await tester.pumpAndSettle();
        expect(
          (await repo.find(book.id))!.chapters
              .map((chapter) => chapter.downloaded),
          [false, true],
        );
        expect(await repo.readChapter(book.id, 0), isNull);
        expect(await repo.readChapter(book.id, 1), isNotNull);
        expect((await repo.find(book.id))!.progress, book.progress);
        expect((await repo.find(book.id))!.bookmarks, book.bookmarks);
        expect(
          (await repo.find(local.id))!.chapters
              .every((chapter) => chapter.downloaded),
          isTrue,
        );
        // Imported manga still supports export, but no destructive menu action.
        await tester.tap(find.byTooltip('Xuất CBZ Unprotected'));
        await tester.pumpAndSettle();
        expect(find.text('Xuất chương này thành CBZ'), findsOneWidget);
        expect(find.text('Xóa nội dung tải của chương'), findsNothing);
        expect(find.text('Xóa các chương đã tải của truyện'), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'manual delete popup opened before restore cannot delete replacement cache',
    (tester) async {
      final prefs = await SharedPreferences.getInstance(),
          repo = MemoryLibraryRepository(),
          book = _book();
      await repo.save(book);
      await repo.saveChapter(
        book.id,
        0,
        ReaderContent(kind: 'manga', images: [_image]),
      );
      await _show(tester, prefs, repo, const RecentDownloadsScreen(), 320);
      await tester.tap(find.byTooltip('Xuất CBZ Unprotected'));
      await tester.pumpAndSettle();
      await repo.clear();
      await repo.save(book.copyWith(title: 'Restored'));
      await repo.saveChapter(
        book.id,
        0,
        ReaderContent(kind: 'manga', images: [_image]),
      );
      final restored = (await repo.snapshot()).encode();
      await tester.tap(find.text('Xóa nội dung tải của chương'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Xóa nội dung'));
      await tester.pumpAndSettle();
      expect((await repo.snapshot()).encode(), restored);
      expect(find.textContaining('khôi phục'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
