import 'dart:async';

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tachi_books/core/theme/app_theme.dart';
import 'package:tachi_books/features/downloads/data/cbz_export_service.dart';
import 'package:tachi_books/features/downloads/data/download_queue_repository.dart';
import 'package:tachi_books/features/downloads/presentation/download_actions.dart';
import 'package:tachi_books/features/downloads/presentation/download_queue_controller.dart';
import 'package:tachi_books/features/downloads/presentation/downloads_screen.dart';
import 'package:tachi_books/features/library/data/library_repository.dart';
import 'package:tachi_books/features/library/domain/library_book.dart';
import 'package:tachi_books/features/library/presentation/library_view_model.dart';
import 'package:tachi_books/features/settings/settings_controller.dart';

LibraryBook _book(String id, {int count = 3}) => LibraryBook(
  id: id,
  title: 'Truyện $id',
  engine: 'vbook',
  sourceRef: id,
  sourceId: 'source',
  chapters: List.generate(
    count,
    (i) => BookChapter(id: '$i', title: '$id chương $i', index: i, read: false),
  ),
);
Future<void> _show(
  WidgetTester tester,
  ProviderContainer container,
  Widget screen,
  double width,
) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = Size(width, 850);
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(theme: appTheme(Brightness.dark), home: screen),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _dragBook(
  WidgetTester tester,
  String from,
  String to, {
  required bool up,
}) async {
  final start = tester.getCenter(find.byKey(ValueKey('download-drag-$from')));
  final destination =
      tester.getCenter(find.byKey(ValueKey('download-drag-$to'))) +
      Offset(0, up ? -25 : 25);
  final pointer = await tester.startGesture(start);
  await pointer.moveBy(Offset(0, up ? -20 : 20));
  await tester.pump(const Duration(milliseconds: 100));
  for (var step = 1; step <= 12; step++) {
    await pointer.moveTo(Offset.lerp(start, destination, step / 12)!);
    await tester.pump(const Duration(milliseconds: 40));
  }
  await tester.pump(const Duration(milliseconds: 600));
  await pointer.up();
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(
    () => SharedPreferences.setMockInitialValues({'downloadConcurrency': 1}),
  );
  for (final width in [320.0, 430.0]) {
    testWidgets(
      'actual book drags reorder both directions, persist/restart and cancel at $width',
      (tester) async {
        final prefs = await SharedPreferences.getInstance(),
            repo = MemoryLibraryRepository();
        for (final id in ['a', 'b', 'c']) {
          await repo.save(_book(id));
        }
        final before = (await repo.snapshot()).encode();
        final container = ProviderContainer(
          overrides: [
            preferencesProvider.overrideWithValue(prefs),
            libraryRepositoryProvider.overrideWithValue(repo),
          ],
        );
        addTearDown(container.dispose);
        final queue = container.read(downloadQueueProvider.notifier);
        await queue.enqueue('a', ['0', '1']);
        await queue.enqueue('b', ['0', '1']);
        await queue.enqueue('c', ['0']);
        await _show(tester, container, const DownloadsScreen(), width);
        await _dragBook(tester, 'c', 'a', up: true);
        expect(
          DownloadQueueRepository(prefs)
              .load()
              .map((task) => task.bookId)
              .toSet()
              .toList(),
          ['c', 'a', 'b'],
        );
        expect(
          tester.getTopLeft(find.byKey(const ValueKey('download-book-c'))).dy,
          lessThan(
            tester.getTopLeft(find.byKey(const ValueKey('download-book-a'))).dy,
          ),
        );
        await _dragBook(tester, 'c', 'b', up: false);
        expect(
          DownloadQueueRepository(prefs)
              .load()
              .map((task) => task.bookId)
              .toSet()
              .toList(),
          ['a', 'b', 'c'],
        );
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
        final restarted = ProviderContainer(
          overrides: [
            preferencesProvider.overrideWithValue(prefs),
            libraryRepositoryProvider.overrideWithValue(repo),
          ],
        );
        addTearDown(restarted.dispose);
        await _show(tester, restarted, const DownloadsScreen(), width);
        expect(
          restarted
              .read(downloadQueueProvider)
              .tasks
              .map((task) => task.bookId)
              .toSet()
              .toList(),
          ['a', 'b', 'c'],
        );
        await tester.tap(find.byTooltip('Tùy chọn tải Truyện a'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Hủy tải truyện'));
        await tester.pumpAndSettle();
        expect(
          DownloadQueueRepository(prefs)
              .load()
              .map((task) => task.bookId)
              .toSet(),
          {'b', 'c'},
        );
        await tester.tap(find.text('Truyện b'));
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Tùy chọn chương 0'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Hủy tải chương'));
        await tester.pumpAndSettle();
        expect(
          DownloadQueueRepository(prefs)
              .load()
              .map((task) => '${task.bookId}/${task.chapterId}'),
          ['b/1', 'c/0'],
        );
        await tester.tap(find.byTooltip('Hủy tất cả tải xuống'));
        await tester.pumpAndSettle();
        expect(find.text('Không có tải xuống'), findsOneWidget);
        expect(DownloadQueueRepository(prefs).load(), isEmpty);
        expect((await repo.snapshot()).encode(), before);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'book Download now menu starts the promoted book and preserves other queued work',
    (tester) async {
      final prefs = await SharedPreferences.getInstance(),
          repo = MemoryLibraryRepository();
      for (final id in ['a', 'b']) {
        await repo.save(_book(id));
      }
      final release = Completer<void>();
      final calls = <String>[];
      final container = ProviderContainer(
        overrides: [
          preferencesProvider.overrideWithValue(prefs),
          libraryRepositoryProvider.overrideWithValue(repo),
          downloadJobExecutorProvider.overrideWithValue((book, index) {
            calls.add('${book.id}/${book.chapters[index].id}');
            return release.future;
          }),
        ],
      );
      addTearDown(container.dispose);
      final queue = container.read(downloadQueueProvider.notifier);
      await queue.enqueue('a', ['0']);
      await queue.enqueue('b', ['0', '1']);
      await _show(tester, container, const DownloadsScreen(), 320);
      await tester.tap(find.byTooltip('Tùy chọn tải Truyện b'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Tải ngay'));
      // Active indicators animate continuously; bounded pumps inspect dispatch.
      for (var i = 0; i < 10 && calls.isEmpty; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(calls, ['b/0']);
      queue.pause();
      release.complete();
      await tester.pumpAndSettle();
      expect(
        DownloadQueueRepository(prefs)
            .load()
            .map((task) => '${task.bookId}/${task.chapterId}'),
        ['b/1', 'a/0'],
      );
      expect(tester.takeException(), isNull);
    },
  );

  for (final restore in [false, true]) {
    testWidgets(
      'next N picker ${restore ? 'rejects stale restore' : 'queues fresh chapters'}',
      (tester) async {
        final prefs = await SharedPreferences.getInstance(),
            repo = MemoryLibraryRepository();
        final book = _book('a', count: 8).copyWith(currentChapter: 2);
        await repo.save(book);
        final container = ProviderContainer(
          overrides: [
            preferencesProvider.overrideWithValue(prefs),
            libraryRepositoryProvider.overrideWithValue(repo),
          ],
        );
        addTearDown(container.dispose);
        await container.read(downloadQueueProvider.notifier).enqueue('a', [
          '0',
        ]);
        await _show(tester, container, const DownloadsScreen(), 320);
        await tester.tap(find.byTooltip('Tùy chọn tải Truyện a'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Tải chương tiếp theo'));
        await tester.pumpAndSettle();
        if (restore) {
          await repo.clear();
          await repo.save(book.copyWith(title: 'Restored'));
        }
        await tester.tap(find.text('5 chương'));
        await tester.pumpAndSettle();
        expect(
          DownloadQueueRepository(prefs).load().map((task) => task.chapterId),
          restore ? ['0'] : ['0', '2', '3', '4', '5', '6'],
        );
        expect(
          find.textContaining(restore ? 'khôi phục' : 'Đã thêm 5'),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'recent downloaded chapter export passes actual CBZ bytes to the file chooser',
    (tester) async {
      final prefs = await SharedPreferences.getInstance(),
          repo = MemoryLibraryRepository();
      final image =
          'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jf1kAAAAASUVORK5CYII=';
      final book = _book('a', count: 2).copyWith(
        kind: 'manga',
        chapters: const [
          BookChapter(
            id: '0',
            title: 'Offline chapter',
            index: 0,
            downloaded: true,
          ),
          BookChapter(id: '1', title: 'Remote chapter', index: 1),
        ],
      );
      await repo.save(book);
      await repo.saveChapter(
        book.id,
        0,
        ReaderContent(kind: 'manga', images: [image, image]),
      );
      final saved = <CbzExport>[];
      final container = ProviderContainer(
        overrides: [
          preferencesProvider.overrideWithValue(prefs),
          libraryRepositoryProvider.overrideWithValue(repo),
          cbzSaveFileProvider.overrideWithValue((export) async {
            saved.add(export);
            return true;
          }),
        ],
      );
      addTearDown(container.dispose);
      await _show(tester, container, const RecentDownloadsScreen(), 320);
      expect(find.text('Remote chapter'), findsNothing);
      await tester.tap(find.byTooltip('Xuất CBZ Offline chapter'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Xuất chương này thành CBZ'));
      await tester.pumpAndSettle();
      expect(saved, hasLength(1));
      expect(saved.single.fileName, 'Truyện a.cbz');
      final archive = ZipDecoder().decodeBytes(
        saved.single.bytes,
        verify: true,
      );
      expect(archive.files.map((file) => file.content).toList(), [
        UriData.parse(image).contentAsBytes(),
        UriData.parse(image).contentAsBytes(),
      ]);
      expect(find.text('Đã xuất 1 chương, 2 trang CBZ'), findsOneWidget);
      expect((await repo.find(book.id))!.chapters.last.downloaded, isFalse);
      expect(tester.takeException(), isNull);
    },
  );
}
