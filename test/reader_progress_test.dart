import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tachi_books/features/library/data/library_repository.dart';
import 'package:tachi_books/features/library/domain/library_book.dart';
import 'package:tachi_books/features/library/presentation/library_view_model.dart';
import 'package:tachi_books/features/reader/presentation/reader_screen.dart';
import 'package:tachi_books/features/settings/settings_controller.dart';

Future<MemoryLibraryRepository> novel() async {
  final repo = MemoryLibraryRepository();
  await repo.save(
    LibraryBook(
      id: 'novel',
      title: 'Novel',
      currentChapter: 0,
      progress: .65,
      chapters: const [
        BookChapter(
          id: 'first',
          title: 'Chapter 1',
          index: 0,
          downloaded: true,
        ),
      ],
    ),
  );
  await repo.saveChapter(
    'novel',
    0,
    ReaderContent(
      kind: 'novel',
      html: List.generate(
        100,
        (i) =>
            '<p>Đoạn $i. Một trang sách để kiểm tra vị trí đọc được phục hồi qua các thay đổi giao diện.</p>',
      ).join(),
    ),
  );
  return repo;
}

double fraction(WidgetTester tester) {
  final view = tester.widget<SingleChildScrollView>(
    find.byType(SingleChildScrollView).first,
  );
  return view.controller!.offset / view.controller!.position.maxScrollExtent;
}

Future<void> waitForReaderImages(WidgetTester tester) async {
  // Codec work is real asynchronous work; pumpAndSettle only observes scheduled frames.
  await tester.runAsync(() async {
    final pending = tester.widgetList<Image>(find.byType(Image)).map((image) {
      final completed = Completer<void>();
      final stream = image.image.resolve(ImageConfiguration.empty);
      late ImageStreamListener listener;
      listener = ImageStreamListener(
        (_, _) {
          stream.removeListener(listener);
          completed.complete();
        },
        onError: (Object error, StackTrace? stack) {
          stream.removeListener(listener);
          completed.completeError(error, stack);
        },
      );
      stream.addListener(listener);
      return completed.future;
    });
    await Future.wait(pending);
  });
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'manga restores image-relative position after asynchronous image sizing and retains one page controller',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      final images = <String>[];
      await tester.runAsync(() async {
        for (final height in [600, 1200, 900]) {
          final recorder = ui.PictureRecorder();
          final canvas = Canvas(recorder);
          canvas.drawRect(
            Rect.fromLTWH(0, 0, 20, height.toDouble()),
            Paint()..color = Colors.blue,
          );
          final picture = recorder.endRecording();
          final image = await picture.toImage(20, height);
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          images.add(
            'data:image/png;base64,${base64Encode(bytes!.buffer.asUint8List())}',
          );
          image.dispose();
          picture.dispose();
        }
      });
      final repo = MemoryLibraryRepository();
      await repo.save(
        LibraryBook(
          id: 'manga',
          title: 'Manga',
          kind: 'manga',
          progress: .5,
          chapters: const [
            BookChapter(
              id: 'first',
              title: 'Chapter 1',
              index: 0,
              downloaded: true,
            ),
          ],
        ),
      );
      await repo.saveChapter(
        'manga',
        0,
        ReaderContent(kind: 'manga', images: images),
      );
      final container = ProviderContainer(
        overrides: [
          libraryRepositoryProvider.overrideWithValue(repo),
          preferencesProvider.overrideWithValue(preferences),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: ReaderScreen(id: 'manga')),
        ),
      );
      await tester.pumpAndSettle();
      // 50% is halfway into image 2, regardless of its natural height.
      await waitForReaderImages(tester);
      final vertical = tester
          .widget<SingleChildScrollView>(find.byType(SingleChildScrollView))
          .controller!;
      expect(vertical.offset, closeTo(1200, 1));
      await container
          .read(settingsProvider.notifier)
          .update(mangaMode: 'paged');
      await tester.pumpAndSettle();
      final controller = tester
          .widget<PageView>(find.byType(PageView))
          .controller!;
      expect(controller.page, 1);
      await container
          .read(settingsProvider.notifier)
          .update(readerTheme: 'night');
      await tester.pumpAndSettle();
      expect(
        tester.widget<PageView>(find.byType(PageView)).controller,
        same(controller),
      );
      expect(controller.page, 1);
      await container
          .read(settingsProvider.notifier)
          .update(mangaMode: 'vertical');
      await tester.pumpAndSettle();
      await waitForReaderImages(tester);
      expect(
        tester
            .widget<SingleChildScrollView>(find.byType(SingleChildScrollView))
            .controller!
            .offset,
        closeTo(1200, 1),
      );
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      expect((await repo.find('manga'))!.progress, closeTo(.5, .001));
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'novel resumes and saves the same location through font and theme changes and disposal',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      final repo = await novel();
      final container = ProviderContainer(
        overrides: [
          libraryRepositoryProvider.overrideWithValue(repo),
          preferencesProvider.overrideWithValue(preferences),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: ReaderScreen(id: 'novel')),
        ),
      );
      await tester.pumpAndSettle();
      expect(fraction(tester), closeTo(.65, .001));
      await container
          .read(settingsProvider.notifier)
          .update(fontSize: 30, readerTheme: 'sepia');
      await tester.pumpAndSettle();
      expect(fraction(tester), closeTo(.65, .001));
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      expect((await repo.find('novel'))!.progress, closeTo(.65, .001));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('bookmark list returns to the saved chapter position', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    final repo = await novel();
    final container = ProviderContainer(
      overrides: [
        libraryRepositoryProvider.overrideWithValue(repo),
        preferencesProvider.overrideWithValue(preferences),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: ReaderScreen(id: 'novel')),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Đánh dấu trang'));
    await tester.pumpAndSettle();
    expect((await repo.find('novel'))!.bookmarks, ['0:0.6500']);
    tester
        .widget<SingleChildScrollView>(find.byType(SingleChildScrollView).first)
        .controller!
        .jumpTo(0);
    await tester.pump(const Duration(milliseconds: 600));
    await tester.tap(find.textContaining('Mục lục'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Dấu trang'));
    await tester.pumpAndSettle();
    expect(find.text('65% trong chương'), findsOneWidget);
    await tester.tap(find.text('65% trong chương'));
    await tester.pumpAndSettle();
    expect(fraction(tester), closeTo(.65, .001));
    expect((await repo.find('novel'))!.progress, closeTo(.65, .001));
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
