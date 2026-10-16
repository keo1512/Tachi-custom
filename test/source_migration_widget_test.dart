import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:tachi_books/features/library/data/library_repository.dart';
import 'package:tachi_books/features/library/domain/library_book.dart';
import 'package:tachi_books/features/library/presentation/library_view_model.dart';
import 'package:tachi_books/features/sources/data/source_repository.dart';
import 'package:tachi_books/features/sources/domain/catalogue.dart';
import 'package:tachi_books/features/sources/presentation/source_migration_screen.dart';
import 'package:tachi_books/features/sources/presentation/source_bulk_migration_screen.dart';
import 'package:tachi_books/core/widgets/book_cover.dart';
import 'package:tachi_books/core/theme/app_theme.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    for (final family in [
      'NotoSans',
      'CupertinoSystemText',
      'CupertinoSystemDisplay',
    ]) {
      await (FontLoader(
        family,
      )..addFont(rootBundle.load('assets/fonts/notosans.ttf'))).load();
    }
  });
  for (final selectionOnly in [false, true]) {
    testWidgets(
      'same-byte restore while reviewing a ${selectionOnly ? 'bulk target' : 'single migration'} rejects confirmation',
      (tester) async {
        final repository = MemoryLibraryRepository();
        await repository.save(
          LibraryBook(
            id: 'old',
            title: 'Old title',
            engine: 'vbook',
            sourceId: 'old-source',
            sourceRef: '/old',
            chapters: const [
              BookChapter(id: '/c', title: 'One', index: 0, number: 1),
            ],
          ),
        );
        final before = await repository.snapshot();
        final sources = _Sources();
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              libraryRepositoryProvider.overrideWithValue(repository),
              sourceRepositoryProvider.overrideWithValue(sources),
            ],
            child: MaterialApp(
              home: SourceMigrationScreen(
                bookId: 'old',
                source: _source,
                selectionOnly: selectionOnly,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(ListTile, 'New title').first);
        await tester.pumpAndSettle();
        await repository.replaceSnapshot(
          before,
          expectedFingerprint: before.fingerprint,
        );
        final action = find.text(
          selectionOnly ? 'Dùng kết quả này' : 'Chuyển và giữ truyện cũ',
        );
        await tester.ensureVisible(action);
        await tester.tap(action);
        await tester.pumpAndSettle();
        expect((await repository.snapshot()).fingerprint, before.fingerprint);
        expect(
          find.textContaining('Thư viện đã được thay đổi hoặc khôi phục'),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        sources.dispose();
      },
    );
  }
  testWidgets(
    'restore while confirming bulk migration invalidates a same-byte preview',
    (tester) async {
      final repository = MemoryLibraryRepository();
      await repository.save(
        LibraryBook(
          id: 'old',
          title: 'Old title',
          engine: 'vbook',
          sourceId: 'old-source',
          sourceRef: '/old',
          chapters: const [
            BookChapter(id: '/c', title: 'One', index: 0, number: 1),
          ],
        ),
      );
      final before = await repository.snapshot();
      final sources = _Sources();
      final router = GoRouter(
        routes: [
          GoRoute(
            path: '/',
            builder: (_, _) =>
                const BulkSourceMigrationScreen(sources: [_source]),
          ),
          GoRoute(
            path: '/migrate',
            builder: (_, _) => const SourceMigrationScreen(
              bookId: 'old',
              source: _source,
              selectionOnly: true,
            ),
          ),
        ],
      );
      late ProviderContainer container;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            libraryRepositoryProvider.overrideWithValue(repository),
            sourceRepositoryProvider.overrideWithValue(sources),
          ],
          child: Builder(
            builder: (context) {
              container = ProviderScope.containerOf(context);
              return MaterialApp.router(routerConfig: router);
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('migration-bulk-book-old')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('New source · vi'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ListTile, 'New title').first);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Dùng kết quả này'));
      await tester.tap(find.text('Dùng kết quả này'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Xem lại và chuyển 1 truyện'));
      await tester.pumpAndSettle();
      await repository.replaceSnapshot(
        before,
        expectedFingerprint: before.fingerprint,
      );
      await container.read(libraryProvider.notifier).refresh();
      await tester.pumpAndSettle();
      await tester.tap(find.text('Chuyển và giữ truyện cũ'));
      await tester.pumpAndSettle();
      expect((await repository.snapshot()).fingerprint, before.fingerprint);
      expect(find.text('Xem lại và chuyển 0 truyện'), findsOneWidget);
      expect(
        find.textContaining('Hãy chọn và xem trước kết quả lại'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      router.dispose();
      sources.dispose();
    },
  );
  testWidgets('bulk migration keeps distant covers lazy for a large library', (
    tester,
  ) async {
    final repository = MemoryLibraryRepository();
    for (var i = 0; i < 200; i++) {
      await repository.save(
        LibraryBook(
          id: 'book-$i',
          title: 'Truyện $i',
          engine: 'vbook',
          sourceId: 'old-source',
          sourceRef: '/$i',
        ),
      );
    }
    final sources = _Sources();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          libraryRepositoryProvider.overrideWithValue(repository),
          sourceRepositoryProvider.overrideWithValue(sources),
        ],
        child: const MaterialApp(
          home: BulkSourceMigrationScreen(sources: [_source]),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('migration-bulk-book-book-199')),
      findsNothing,
    );
    expect(find.byType(BookCover).evaluate().length, lessThan(15));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    sources.dispose();
  });
  testWidgets(
    'bulk review selects target without writing, then commits default keep-old action',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(320, 568);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final repository = MemoryLibraryRepository();
      await repository.save(
        LibraryBook(
          id: 'old',
          title: 'Old title',
          engine: 'vbook',
          sourceId: 'old-source',
          sourceRef: '/old',
          chapters: const [
            BookChapter(
              id: '/old-chapter',
              title: 'Chapter 1',
              index: 0,
              number: 1,
              read: true,
            ),
          ],
        ),
      );
      final before = await repository.snapshot();
      final sources = _Sources();
      final router = GoRouter(
        routes: [
          GoRoute(
            path: '/',
            builder: (_, _) =>
                const BulkSourceMigrationScreen(sources: [_source]),
          ),
          GoRoute(
            path: '/migrate',
            builder: (_, state) {
              final extra = state.extra! as Map<String, Object>;
              return SourceMigrationScreen(
                bookId: extra['bookId']! as String,
                source: extra['source']! as CatalogueSource,
                selectionOnly: extra['selectionOnly'] == true,
              );
            },
          ),
        ],
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            libraryRepositoryProvider.overrideWithValue(repository),
            sourceRepositoryProvider.overrideWithValue(sources),
          ],
          child: MaterialApp.router(
            theme: appTheme(Brightness.dark),
            routerConfig: router,
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: const TextScaler.linear(1.5)),
              child: RepaintBoundary(
                key: const ValueKey('migration-preview-capture'),
                child: child!,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('migration-bulk-book-old')),
        140,
        scrollable: find.byType(Scrollable).first,
      );
      await Scrollable.ensureVisible(
        tester.element(find.byKey(const ValueKey('migration-bulk-book-old'))),
        alignment: .5,
      );
      await tester.pumpAndSettle();
      expect(find.byType(BookCover), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('migration-bulk-book-old')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('New source · vi'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ListTile, 'New title').first);
      await tester.pumpAndSettle();
      expect(find.byType(CheckboxListTile), findsNothing);
      expect(find.text('Truyện gốc'), findsOneWidget);
      expect(find.text('Truyện ở nguồn mới'), findsOneWidget);
      expect(find.text('1 chương'), findsNWidgets(2));
      expect(find.text('Tìm lại kết quả'), findsOneWidget);
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(const ValueKey('migration-preview-capture')),
      );
      await tester.runAsync(() async {
        final image = await boundary.toImage(pixelRatio: 1);
        try {
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await File('artifacts/ui-spec-migration-preview-320.png')
              .writeAsBytes(bytes!.buffer.asUint8List());
        } finally {
          image.dispose();
        }
      });
      await tester.ensureVisible(find.text('Dùng kết quả này'));
      await tester.tap(find.text('Dùng kết quả này'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Đã xem trước 1/1'), findsOneWidget);
      expect((await repository.snapshot()).fingerprint, before.fingerprint);
      await tester.tap(find.text('Xem lại và chuyển 1 truyện'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Chuyển và giữ truyện cũ'));
      await tester.pumpAndSettle();
      expect((await repository.list()).length, 2);
      expect(
        find.textContaining('Hãy chọn và xem trước kết quả lại'),
        findsNothing,
      );
      expect(await repository.find('old'), isNotNull);
      expect(find.text('Đã chuyển 1 truyện.'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      router.dispose();
      sources.dispose();
    },
  );
  testWidgets(
    'migration search preview can be cancelled, then explicitly keeps old offline book',
    (tester) async {
      final repository = MemoryLibraryRepository();
      await repository.save(
        LibraryBook(
          id: 'old',
          title: 'Old title',
          engine: 'vbook',
          sourceId: 'old-source',
          sourceRef: '/old',
          chapters: const [
            BookChapter(
              id: '/old-chapter',
              title: 'Chapter 1',
              index: 0,
              number: 1,
              downloaded: true,
              read: true,
            ),
          ],
          bookmarks: ['0:0.5'],
          notes: 'keep note',
        ),
      );
      await repository.saveChapter(
        'old',
        0,
        ReaderContent(kind: 'novel', html: '<p>old offline</p>'),
      );
      final before = await repository.snapshot();
      final sources = _Sources();
      final router = GoRouter(
        routes: [
          GoRoute(
            path: '/',
            builder: (_, _) =>
                const SourceMigrationScreen(bookId: 'old', source: _source),
          ),
          GoRoute(
            path: '/book/:id',
            builder: (_, state) =>
                Scaffold(body: Text('Saved ${state.pathParameters['id']}')),
          ),
        ],
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            libraryRepositoryProvider.overrideWithValue(repository),
            sourceRepositoryProvider.overrideWithValue(sources),
          ],
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await tester.pumpAndSettle();
      expect(sources.queries, ['Old title']);
      await tester.tap(find.widgetWithText(ListTile, 'New title').first);
      await tester.pumpAndSettle();
      expect(find.text('Xem trước chuyển nguồn'), findsOneWidget);
      expect(find.byType(BookCover), findsNWidgets(3));
      expect(
        tester.widget<CheckboxListTile>(find.byType(CheckboxListTile)).value,
        isFalse,
      );
      expect((await repository.snapshot()).fingerprint, before.fingerprint);
      await tester.ensureVisible(find.text('Hủy'));
      await tester.tap(find.text('Hủy'));
      await tester.pumpAndSettle();
      expect((await repository.snapshot()).fingerprint, before.fingerprint);
      await tester.tap(find.widgetWithText(ListTile, 'New title').first);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Chuyển và giữ truyện cũ'));
      await tester.tap(find.text('Chuyển và giữ truyện cũ'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Saved '), findsOneWidget);
      expect((await repository.list()).length, 2);
      expect(
        (await repository.readChapter('old', 0))!.html,
        '<p>old offline</p>',
      );
      final migrated = (await repository.list()).singleWhere(
        (b) => b.id != 'old',
      );
      expect(migrated.notes, 'keep note');
      expect(migrated.bookmarks, ['0:0.0000']);
      expect(migrated.chapters.single.read, isTrue);
      expect(migrated.chapters.single.downloaded, isFalse);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      router.dispose();
      sources.dispose();
    },
  );
}

const _source = CatalogueSource(
  id: 'new-source',
  name: 'New source',
  lang: 'vi',
  baseUrl: 'https://example.org',
  kind: ContentKind.novel,
  engine: SourceEngine.vbook,
);
const _target = CatalogueBook(
  ref: '/new',
  title: 'New title',
  sourceId: 'new-source',
  kind: ContentKind.novel,
  engine: SourceEngine.vbook,
);

class _Sources extends SourceRepository {
  _Sources() : super(tachimangaUrl: '', vbookUrl: '');
  final queries = <String>[];
  @override
  Future<List<CatalogueBook>> search(
    CatalogueSource source,
    String query, {
    int page = 1,
  }) async {
    queries.add(query);
    return [_target];
  }

  @override
  Future<CatalogueBook> detail(CatalogueBook book) async => _target;
  @override
  Future<List<CatalogueChapter>> chapters(CatalogueBook book) async => [
    const CatalogueChapter(
      ref: '/new-chapter',
      title: 'Chapter one',
      index: 0,
      number: 1,
    ),
  ];
}
