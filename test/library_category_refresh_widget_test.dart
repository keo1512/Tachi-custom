import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tachi_books/core/theme/app_theme.dart';
import 'package:tachi_books/features/library/data/library_repository.dart';
import 'package:tachi_books/features/library/domain/library_book.dart';
import 'package:tachi_books/features/library/presentation/library_screen.dart';
import 'package:tachi_books/features/library/presentation/library_view_model.dart';
import 'package:tachi_books/features/settings/settings_controller.dart';
import 'package:tachi_books/features/sources/data/source_repository.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final size in const [Size(320, 568), Size(430, 932)]) {
    testWidgets(
      'pulling a short manga shelf refreshes only its remote book at $size',
      (tester) async {
        final first = _manga('first', '42', 'manga');
        final local = first.copyWith(
          id: 'local',
          title: 'EPUB trên máy',
          engine: 'local',
          kind: 'novel',
        );
        final outside = _manga('outside', '99', '...');
        final fixture = await _mount(tester, size, [first, local, outside]);
        await _selectManga(tester);
        expect(
          find.byKey(const ValueKey('library-book-outside')),
          findsNothing,
        );
        expect(
          find.byKey(const ValueKey('library-book-local')),
          findsOneWidget,
        );
        final scrollable = tester.state<ScrollableState>(
          find.descendant(
            of: find.byType(GridView),
            matching: find.byType(Scrollable),
          ),
        );
        expect(
          scrollable.position.maxScrollExtent,
          0,
          reason: 'A two-book shelf still accepts a pull gesture.',
        );
        await _pull(tester, find.byType(GridView));
        await tester.pumpAndSettle();
        expect(fixture.requests.map((request) => request.url.path), [
          '/prefix/api/v1/manga/42',
          '/prefix/api/v1/manga/42/chapters',
        ]);
        expect(
          fixture.requests.last.url.queryParameters['onlineFetch'],
          'true',
        );
        expect(
          find.text('Đã kiểm tra 1 truyện, thêm 1 chương mới.'),
          findsOneWidget,
        );
        final saved = (await fixture.repository.find(first.id))!;
        expect(saved.chapters.map((chapter) => chapter.id), [
          '/c/a',
          '/c/b',
          '/c/new',
        ]);
        expect(saved.chapters.map((chapter) => chapter.read), [
          true,
          false,
          false,
        ]);
        expect(saved.chapters.map((chapter) => chapter.downloaded), [
          true,
          true,
          false,
        ]);
        expect(saved.currentChapter, 1);
        expect(saved.progress, .5);
        expect(saved.bookmarks, first.bookmarks);
        expect(saved.lastRead, first.lastRead);
        expect(saved.notes, first.notes);
        expect(saved.favorite, first.favorite);
        expect(
          (await fixture.repository.readChapter(first.id, 0))!.html,
          'cache-/c/a',
        );
        expect(
          (await fixture.repository.readChapter(first.id, 1))!.html,
          'cache-/c/b',
        );
        expect(await fixture.repository.readChapter(first.id, 2), isNull);
        expect(
          (await fixture.repository.find(local.id))!.toJson(),
          local.toJson(),
        );
        expect(
          (await fixture.repository.find(outside.id))!.toJson(),
          outside.toJson(),
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      },
    );
  }

  testWidgets(
    'pull refresh reports a source failure while updating healthy books',
    (tester) async {
      final healthy = _manga('first', '42', 'manga');
      final broken = healthy.copyWith(
        id: 'broken',
        title: 'Truyện chữ nguồn lỗi',
        engine: 'vbook',
        kind: 'novel',
        sourceId: 'broken-source',
        sourceRef: '/broken',
      );
      final outside = _manga('outside', '99', '...');
      final fixture = await _mount(tester, const Size(320, 568), [
        healthy,
        broken,
        outside,
      ]);
      await _selectManga(tester);
      await _pull(tester, find.byType(GridView));
      await tester.pump(const Duration(seconds: 1));
      expect(find.byType(CupertinoAlertDialog), findsOneWidget);
      expect(find.text('Kết quả cập nhật'), findsOneWidget);
      expect(
        find.textContaining('Đã kiểm tra 1 truyện, thêm 1 chương mới.'),
        findsOneWidget,
      );
      expect(
        find.textContaining('1 truyện chưa cập nhật được.'),
        findsOneWidget,
      );
      expect(
        find.textContaining('Nguồn tạm thời không truy cập được'),
        findsOneWidget,
      );
      expect(
        (await fixture.repository.find(healthy.id))!.chapters,
        hasLength(3),
      );
      expect(
        (await fixture.repository.find(broken.id))!.toJson(),
        broken.toJson(),
      );
      expect(
        (await fixture.repository.readChapter(broken.id, 1))!.html,
        'cache-/c/b',
      );
      expect(
        fixture.requests.where((request) => request.url.path.contains('/99')),
        isEmpty,
      );
      expect(
        fixture.requests.where(
          (request) => request.url.path.endsWith('/broken-source/chapters'),
        ),
        hasLength(1),
      );
      await tester.tap(find.text('Đóng'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );

  for (final size in const [Size(320, 568), Size(430, 932)]) {
    testWidgets(
      'an empty library accepts a real pull gesture without source requests at $size',
      (tester) async {
        final fixture = await _mount(tester, size, []);
        expect(find.text('Tủ sách của bạn'), findsOneWidget);
        await _pull(tester, find.byType(CustomScrollView));
        await tester.pumpAndSettle();
        expect(
          find.text('Không có truyện từ nguồn trực tuyến trong mục này.'),
          findsOneWidget,
        );
        expect(fixture.requests, isEmpty);
        expect(await fixture.repository.list(), isEmpty);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      },
    );
  }

  testWidgets(
    'an empty search result can be pulled without refreshing hidden books',
    (tester) async {
      final first = _manga('first', '42', 'manga');
      final fixture = await _mount(tester, const Size(320, 568), [first]);
      await tester.tap(find.byTooltip('Tìm trong thư viện'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'ZZZ_NO_MATCH');
      await tester.pumpAndSettle();
      expect(find.text('Không có kết quả tìm kiếm'), findsOneWidget);
      await _pull(tester, find.byType(CustomScrollView));
      await tester.pumpAndSettle();
      expect(
        find.text('Không có truyện từ nguồn trực tuyến trong mục này.'),
        findsOneWidget,
      );
      expect(fixture.requests, isEmpty);
      expect(
        (await fixture.repository.find(first.id))!.toJson(),
        first.toJson(),
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'the update menu applies both the current shelf and title search',
    (tester) async {
      final first = _manga('first', '42', 'manga');
      final sameShelf = _manga('other', '98', 'manga');
      final outside = _manga('outside', '99', '...');
      final fixture = await _mount(tester, const Size(430, 932), [
        first,
        sameShelf,
        outside,
      ]);
      await _selectManga(tester);
      await tester.tap(find.byTooltip('Tìm trong thư viện'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'title:"Truyện first"');
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('library-book-other')), findsNothing);
      await tester.tap(find.byTooltip('Thao tác thư viện'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Cập nhật chương mới'));
      await tester.tap(find.text('Cập nhật chương mới'));
      await tester.pumpAndSettle();
      expect(fixture.requests.map((request) => request.url.path), [
        '/prefix/api/v1/manga/42',
        '/prefix/api/v1/manga/42/chapters',
      ]);
      expect(
        (await fixture.repository.find(sameShelf.id))!.toJson(),
        sameShelf.toJson(),
      );
      expect(
        (await fixture.repository.find(outside.id))!.toJson(),
        outside.toJson(),
      );
      expect(
        find.text('Đã kiểm tra 1 truyện, thêm 1 chương mới.'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );
}

Future<void> _selectManga(WidgetTester tester) async {
  final tab = find.byKey(const ValueKey('library-group-value:manga'));
  await tester.ensureVisible(tab);
  await tester.pumpAndSettle();
  await tester.tap(tab);
  await tester.pumpAndSettle();
}

Future<void> _pull(WidgetTester tester, Finder scrollView) async {
  await tester.drag(scrollView, const Offset(0, 500));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

LibraryBook _manga(String id, String sourceRef, String collection) =>
    LibraryBook(
      id: id,
      title: 'Truyện $id',
      engine: 'tachimanga',
      kind: 'manga',
      sourceId: '123',
      sourceRef: sourceRef,
      collection: collection,
      currentChapter: 1,
      progress: .75,
      lastRead: DateTime(2026, 10, 10),
      favorite: true,
      notes: 'Giữ ghi chú',
      bookmarks: const ['0:0.2500', '1:0.5000'],
      chapters: const [
        BookChapter(
          id: '/c/a',
          title: 'Chương a',
          index: 0,
          downloaded: true,
          read: true,
        ),
        BookChapter(
          id: '/c/b',
          title: 'Chương b',
          index: 1,
          downloaded: true,
          read: false,
        ),
      ],
    );

Future<({MemoryLibraryRepository repository, List<http.Request> requests})>
_mount(WidgetTester tester, Size size, List<LibraryBook> books) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);
  final preferences = await SharedPreferences.getInstance();
  final repository = MemoryLibraryRepository();
  for (final book in books) {
    await repository.save(book);
    for (final chapter in book.chapters) {
      await repository.saveChapter(
        book.id,
        chapter.index,
        ReaderContent(kind: book.kind, html: 'cache-${chapter.id}'),
      );
    }
  }
  final requests = <http.Request>[];
  final client = MockClient((request) async {
    requests.add(request);
    if (request.url.path == '/prefix/api/v1/manga/42') {
      return _json({'id': 42, 'sourceId': '123', 'url': '/book/first'});
    }
    if (request.url.path == '/prefix/api/v1/manga/42/chapters') {
      return _json([
        {'url': '/c/new', 'name': 'Chương mới', 'index': 2},
        {'url': '/c/b', 'name': 'Chương b', 'index': 1},
        {'url': '/c/a', 'name': 'Chương a', 'index': 0},
      ]);
    }
    if (request.url.path.endsWith('/broken-source/chapters')) {
      expect(request.url.queryParameters['ref'], '/broken');
      return _json({
        'error': {'message': 'Nguồn tạm thời không truy cập được'},
      }, status: 503);
    }
    fail(
      'Unexpected request outside the captured visible books: ${request.url}',
    );
  });
  final source = SourceRepository(
    tachimangaUrl: 'http://localhost:4567/prefix',
    vbookUrl: 'http://localhost:4570',
    client: client,
  );
  addTearDown(client.close);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        preferencesProvider.overrideWithValue(preferences),
        libraryRepositoryProvider.overrideWithValue(repository),
        sourceRepositoryProvider.overrideWithValue(source),
      ],
      child: MaterialApp(
        theme: appTheme(Brightness.dark),
        home: const LibraryScreen(),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return (repository: repository, requests: requests);
}

http.Response _json(Object value, {int status = 200}) => http.Response(
  jsonEncode(value),
  status,
  headers: {'content-type': 'application/json'},
);
