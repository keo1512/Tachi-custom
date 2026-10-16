import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tachi_books/app.dart';
import 'package:tachi_books/core/platform/native_tabs.dart';
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

  for (final id in [
    'Sách / 100% ? # tiếng Việt 📚',
    'literal%2Fid?#value',
    '.',
    '..',
  ]) {
    testWidgets(
      'library tile, detail resume and chapter row preserve opaque ID $id',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(320, 700);
        addTearDown(tester.view.reset);
        final repo = MemoryLibraryRepository();
        final book = LibraryBook(
          id: id,
          title: 'Truyện trong bản khôi phục',
          engine: 'local',
          kind: 'novel',
          currentChapter: 1,
          progress: .5,
          lastRead: DateTime(2026, 10, 10),
          chapters: const [
            BookChapter(
              id: 'https://source.test/chương/a?part=1&lang=vi#đầu',
              title: 'Chương đầu',
              index: 0,
              read: false,
              downloaded: true,
            ),
            BookChapter(
              id: 'literal%2Fchương/khác?x=1#vị trí',
              title: 'Chương tiếp tục',
              index: 1,
              read: false,
              downloaded: true,
            ),
          ],
        );
        await repo.save(book);
        for (var index = 0; index < 2; index++) {
          await repo.saveChapter(
            id,
            index,
            ReaderContent(
              kind: 'novel',
              html: '<p>Nội dung chương $index được giữ</p>',
            ),
          );
        }
        final tabs = NativeTabs(onSelect: (_) {});
        final router = createRouter(tabs: tabs, onNavigation: () {});
        final container = ProviderContainer(
          overrides: [
            libraryRepositoryProvider.overrideWithValue(repo),
            preferencesProvider.overrideWithValue(
              await SharedPreferences.getInstance(),
            ),
          ],
        );
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp.router(
              routerConfig: router,
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(textScaler: const TextScaler.linear(1.5)),
                child: child!,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(ValueKey('library-book-$id')));
        await tester.pumpAndSettle();
        expect(
          tester.widget<BookDetailScreen>(find.byType(BookDetailScreen)).id,
          id,
        );
        await tester.ensureVisible(
          find.byKey(const ValueKey('book-detail-resume')),
        );
        await tester.tap(find.byKey(const ValueKey('book-detail-resume')));
        await tester.pumpAndSettle();
        final resumed = tester.widget<ReaderScreen>(find.byType(ReaderScreen));
        expect(resumed.id, id);
        expect(resumed.chapter, 1);
        expect(resumed.chapterId, book.chapters[1].id);
        expect(
          find.text('Nội dung chương 1 được giữ', findRichText: true),
          findsOneWidget,
        );
        router.pop();
        await tester.pumpAndSettle();
        final chapterRow = find.widgetWithText(ListTile, 'Chương đầu');
        await tester.scrollUntilVisible(chapterRow, 180);
        await tester.ensureVisible(chapterRow);
        await tester.pumpAndSettle();
        // Capture the real rendered row callback, then reorder the repository
        // before navigation. Its stable chapter ID must beat its old row index.
        final openChapter = tester.widget<ListTile>(chapterRow).onTap!;
        final latest = (await repo.find(id))!;
        await repo.replaceChapterOrder(
          latest.copyWith(chapters: [latest.chapters[1], latest.chapters[0]]),
          [1, 0],
        );
        openChapter();
        await tester.pumpAndSettle();
        final opened = tester.widget<ReaderScreen>(find.byType(ReaderScreen));
        expect(opened.id, id);
        expect(opened.chapter, 0);
        expect(opened.chapterId, book.chapters[0].id);
        expect(
          find.text('Nội dung chương 0 được giữ', findRichText: true),
          findsOneWidget,
        );
        final saved = (await repo.find(id))!;
        expect(saved.currentChapter, 1);
        expect(saved.chapters[saved.currentChapter].id, book.chapters[0].id);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        router.dispose();
        tabs.dispose();
        container.dispose();
      },
    );
  }
}
