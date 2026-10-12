import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tachi_books/app.dart';
import 'package:tachi_books/core/platform/native_tabs.dart';
import 'package:tachi_books/features/deep_links/application/deep_link_queue.dart';
import 'package:tachi_books/features/deep_links/domain/app_deep_link.dart';
import 'package:tachi_books/features/library/data/library_repository.dart';
import 'package:tachi_books/features/library/data/library_mutation.dart';
import 'package:tachi_books/features/library/domain/library_book.dart';
import 'package:tachi_books/features/library/presentation/book_detail_screen.dart';
import 'package:tachi_books/features/library/presentation/library_view_model.dart';
import 'package:tachi_books/features/reader/presentation/reader_screen.dart';
import 'package:tachi_books/features/settings/settings_controller.dart';

const targetChapter = 'https://source.test/chương/a?part=1&lang=vi';
const targetText = 'Nội dung chương cần mở từ liên kết';
const otherText = 'Chương khác không được mở nhầm';

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

  for (final id in ['Sách / 100% tiếng Việt', '.', '..']) {
    testWidgets(
      'real router preserves $id and stable chapter after TOC reorders',
      (tester) async {
        final repo = MemoryLibraryRepository();
        final book = await seed(repo, id);
        final prefs = await SharedPreferences.getInstance();
        final request = PendingDeepLink(
          LibraryDeepLink(id, reader: true, chapterId: targetChapter),
          repo,
          prefs,
        );
        final route = await request.libraryRoute();
        // Resolving the external link happened against [target, other]. The
        // actual reader is created only after the source reorders that TOC.
        await repo.replaceChapterOrder(
          book.copyWith(
            chapters: [
              book.chapters[1].copyWith(index: 0),
              book.chapters[0].copyWith(index: 1),
            ],
          ),
          [1, 0],
        );
        expect(repo.replacementRevision, request.revision);
        final fixture = await mount(tester, repo, prefs);
        final detail = PendingDeepLink(LibraryDeepLink(id), repo, prefs);
        fixture.router.go(
          await detail.libraryRoute(),
          extra: LibraryLinkHandoff(detail.revision),
        );
        await tester.pumpAndSettle();
        expect(
          tester.widget<BookDetailScreen>(find.byType(BookDetailScreen)).id,
          id,
        );
        expect(find.text(book.title), findsWidgets);
        fixture.router.go(route, extra: LibraryLinkHandoff(request.revision));
        await tester.pumpAndSettle();
        final reader = tester.widget<ReaderScreen>(find.byType(ReaderScreen));
        expect(reader.id, id);
        expect(reader.chapterId, targetChapter);
        expect(reader.expectedRevision, request.revision);
        expect(find.text(targetText, findRichText: true), findsOneWidget);
        expect(find.text(otherText, findRichText: true), findsNothing);
        final saved = (await repo.find(id))!;
        expect(saved.chapters[saved.currentChapter].id, targetChapter);
        expect(saved.currentChapter, 1);
        expect(saved.progress, .5);
        expect(saved.chapters[0].read, isFalse);
        expect((await repo.readChapter(id, 0))!.html, '<p>$otherText</p>');
        expect((await repo.readChapter(id, 1))!.html, '<p>$targetText</p>');
        expect(tester.takeException(), isNull);
        await dispose(tester, fixture);
      },
    );
  }

  for (final reader in [false, true]) {
    testWidgets(
      'handoff revision rejects same-ID restore before ${reader ? 'reader' : 'detail'} build',
      (tester) async {
        final repo = MemoryLibraryRepository();
        await seed(repo, 'same');
        final prefs = await SharedPreferences.getInstance();
        final request = PendingDeepLink(
          LibraryDeepLink(
            'same',
            reader: reader,
            chapterId: reader ? targetChapter : null,
          ),
          repo,
          prefs,
        );
        final route = await request.libraryRoute();
        final fixture = await mount(tester, repo, prefs);
        fixture.router.go(route, extra: LibraryLinkHandoff(request.revision));
        // The URL has been handed to the router, but its widget has not built.
        await repo.clear();
        await seed(repo, 'same', title: 'Sách mới sau khôi phục');
        final before = (await repo.find('same'))!.toJson();
        fixture.container.invalidate(libraryProvider);
        await tester.pumpAndSettle();
        expect(find.textContaining('Thư viện đã'), findsWidgets);
        expect(find.text(targetText, findRichText: true), findsNothing);
        expect((await repo.find('same'))!.toJson(), before);
        if (!reader) {
          expect(
            tester
                .widget<BookDetailScreen>(find.byType(BookDetailScreen))
                .expectedRevision,
            request.revision,
          );
          expect(find.text('Sách mới sau khôi phục'), findsNothing);
        }
        expect(tester.takeException(), isNull);
        await dispose(tester, fixture);
      },
    );
  }

  testWidgets(
    'reader rejects a missing stable chapter instead of numeric fallback',
    (tester) async {
      final repo = MemoryLibraryRepository();
      final book = await seed(repo, 'missing');
      final prefs = await SharedPreferences.getInstance();
      final request = PendingDeepLink(
        const LibraryDeepLink(
          'missing',
          reader: true,
          chapterId: targetChapter,
        ),
        repo,
        prefs,
      );
      final route = await request.libraryRoute();
      await repo.replaceChapterOrder(
        book.copyWith(chapters: [book.chapters[1].copyWith(index: 0)]),
        [1],
      );
      final before = (await repo.find(book.id))!.toJson();
      final fixture = await mount(tester, repo, prefs);
      fixture.router.go(route, extra: LibraryLinkHandoff(request.revision));
      await tester.pumpAndSettle();
      expect(find.textContaining('Chương không còn'), findsWidgets);
      expect(find.text(otherText, findRichText: true), findsNothing);
      expect((await repo.find(book.id))!.toJson(), before);
      await dispose(tester, fixture);
    },
  );

  testWidgets(
    'restore during reader find cannot publish or fetch replacement content',
    (tester) async {
      final repo = DelayedFindRepository();
      await seed(repo, 'waiting');
      final prefs = await SharedPreferences.getInstance();
      final request = PendingDeepLink(
        const LibraryDeepLink(
          'waiting',
          reader: true,
          chapterId: targetChapter,
        ),
        repo,
        prefs,
      );
      final route = await request.libraryRoute();
      final fixture = await mount(tester, repo, prefs);
      repo.delay = Completer<void>();
      fixture.router.go(route, extra: LibraryLinkHandoff(request.revision));
      await tester.pump();
      await tester.pump();
      expect(repo.waitingFinds, greaterThan(0));
      await repo.clear();
      await seed(repo, 'waiting', title: 'Thay thế trong lúc mở');
      repo.delay!.complete();
      repo.delay = null;
      final before = (await repo.find('waiting'))!.toJson();
      await tester.pumpAndSettle();
      expect(find.textContaining('Thư viện đã'), findsWidgets);
      expect(find.text(targetText, findRichText: true), findsNothing);
      expect((await repo.find('waiting'))!.toJson(), before);
      expect(repo.openedChapters, 0);
      await dispose(tester, fixture);
    },
  );

  testWidgets('detail blocks stale asynchronous library result after restore', (
    tester,
  ) async {
    final repo = DelayedListRepository();
    await seed(repo, 'detail');
    final prefs = await SharedPreferences.getInstance();
    final request = PendingDeepLink(
      const LibraryDeepLink('detail'),
      repo,
      prefs,
    );
    final route = await request.libraryRoute();
    final fixture = await mount(tester, repo, prefs);
    repo.delay = Completer<void>();
    fixture.container.invalidate(libraryProvider);
    fixture.router.go(route, extra: LibraryLinkHandoff(request.revision));
    await tester.pump();
    await tester.pump();
    expect(repo.waitingLists, greaterThan(0));
    await repo.clear();
    await seed(repo, 'detail', title: 'Thông tin thay thế');
    repo.delay!.complete();
    repo.delay = null;
    await tester.pumpAndSettle();
    expect(find.textContaining('Thư viện đã đổi'), findsOneWidget);
    expect(find.text('Thông tin thay thế'), findsNothing);
    await dispose(tester, fixture);
  });

  testWidgets('ordinary numeric reader routes remain usable', (tester) async {
    final repo = MemoryLibraryRepository();
    await seed(repo, 'legacy');
    final fixture = await mount(
      tester,
      repo,
      await SharedPreferences.getInstance(),
    );
    fixture.router.go('/read/legacy?chapter=1');
    await tester.pumpAndSettle();
    expect(find.text(otherText, findRichText: true), findsOneWidget);
    expect((await repo.find('legacy'))!.currentChapter, 1);
    await dispose(tester, fixture);
  });
}

Future<LibraryBook> seed(
  MemoryLibraryRepository repo,
  String id, {
  String title = 'Truyện thử',
}) async {
  final book = LibraryBook(
    id: id,
    title: title,
    kind: 'novel',
    engine: 'local',
    chapters: const [
      BookChapter(
        id: targetChapter,
        title: 'Chương A',
        index: 0,
        read: false,
        downloaded: true,
      ),
      BookChapter(
        id: '/chap/b',
        title: 'Chương B',
        index: 1,
        read: false,
        downloaded: true,
      ),
    ],
  );
  await repo.save(book);
  await repo.saveChapter(
    id,
    0,
    ReaderContent(kind: 'novel', html: '<p>$targetText</p>'),
  );
  await repo.saveChapter(
    id,
    1,
    ReaderContent(kind: 'novel', html: '<p>$otherText</p>'),
  );
  return book;
}

typedef Fixture = ({
  GoRouter router,
  ProviderContainer container,
  NativeTabs tabs,
});

Future<Fixture> mount(
  WidgetTester tester,
  MemoryLibraryRepository repo,
  SharedPreferences prefs,
) async {
  final tabs = NativeTabs(onSelect: (_) {});
  final router = createRouter(tabs: tabs, onNavigation: () {});
  final container = ProviderContainer(
    overrides: [
      preferencesProvider.overrideWithValue(prefs),
      libraryRepositoryProvider.overrideWithValue(repo),
    ],
  );
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
  return (router: router, container: container, tabs: tabs);
}

Future<void> dispose(WidgetTester tester, Fixture fixture) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pumpAndSettle();
  fixture.router.dispose();
  fixture.tabs.dispose();
  fixture.container.dispose();
  expect(tester.takeException(), isNull);
}

class DelayedFindRepository extends MemoryLibraryRepository {
  Completer<void>? delay;
  int waitingFinds = 0, openedChapters = 0;
  @override
  Future<LibraryBook?> find(String id) async {
    if (delay != null) {
      waitingFinds++;
      await delay!.future;
    }
    return super.find(id);
  }

  @override
  Future<LibraryChapterRead?> openChapter(String bookId, String chapterId) {
    openedChapters++;
    return super.openChapter(bookId, chapterId);
  }
}

class DelayedListRepository extends MemoryLibraryRepository {
  Completer<void>? delay;
  int waitingLists = 0;
  @override
  Future<List<LibraryBook>> list() async {
    final captured = await super.list();
    if (delay != null) {
      waitingLists++;
      await delay!.future;
    }
    return captured;
  }
}
