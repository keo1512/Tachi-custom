import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tachi_books/core/theme/app_theme.dart';
import 'package:tachi_books/features/library/data/library_repository.dart';
import 'package:tachi_books/features/library/domain/library_book.dart';
import 'package:tachi_books/features/library/presentation/library_view_model.dart';
import 'package:tachi_books/features/settings/settings_controller.dart';
import 'package:tachi_books/features/sources/data/source_repository.dart';
import 'package:tachi_books/features/sources/domain/catalogue.dart';
import 'package:tachi_books/features/sources/presentation/source_bulk_migration_screen.dart';
import 'package:tachi_books/features/sources/presentation/migration_source_selection.dart';

const targets = [
  CatalogueSource(
    id: '1',
    name: 'Nguồn 1',
    lang: 'vi',
    baseUrl: '',
    kind: ContentKind.manga,
    engine: SourceEngine.tachimanga,
  ),
  CatalogueSource(
    id: '2',
    name: 'Nguồn 2',
    lang: 'vi',
    baseUrl: '',
    kind: ContentKind.manga,
    engine: SourceEngine.tachimanga,
  ),
];

class Sources extends SourceRepository {
  Sources() : super(tachimangaUrl: '', vbookUrl: '');
  Completer<List<CatalogueBook>>? pending;
  @override
  Future<List<CatalogueBook>> search(
    CatalogueSource source,
    String query, {
    int page = 1,
  }) async =>
      pending?.future ??
      CataloguePage([
        CatalogueBook(
          ref: '/new',
          title: query,
          sourceId: source.id,
          kind: ContentKind.manga,
          engine: source.engine,
        ),
      ], hasNextPage: false);
  @override
  Future<CatalogueBook> detail(CatalogueBook book) async => book;
  @override
  Future<List<CatalogueChapter>> chapters(CatalogueBook book) async => [
    for (var i = 0; i < 3; i++)
      CatalogueChapter(
        ref: '/$i',
        title: 'Chương ${i + 1}',
        index: i,
        number: i + 1,
      ),
  ];
}

Future<void> begin(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('migration-batch-start')));
  await tester.pumpAndSettle();
  await tester.tap(find.widgetWithText(CheckboxListTile, 'Nguồn 1'));
  await tester.pump();
  await tester.tap(find.byKey(const ValueKey('migration-sources-continue')));
  await tester.pumpAndSettle();
  await tester.ensureVisible(
    find.byKey(const ValueKey('migration-settings-start')),
  );
  await tester.tap(find.byKey(const ValueKey('migration-settings-start')));
}

Future<({MemoryLibraryRepository books, Sources sources, GoRouter router})>
open(WidgetTester tester, {bool held = false, double scale = 1}) async {
  SharedPreferences.setMockInitialValues({});
  final preferences = await SharedPreferences.getInstance();
  final books = MemoryLibraryRepository();
  await books.save(
    LibraryBook(
      id: 'old',
      title: 'Tên truyện',
      sourceName: 'Nguồn cũ',
      kind: 'manga',
      engine: 'tachimanga',
      sourceId: 'old',
      sourceRef: '/old',
      categories: const ['manga'],
      chapters: const [
        BookChapter(
          id: '/old/1',
          title: 'Chương 1',
          index: 0,
          number: 1,
          read: true,
        ),
      ],
    ),
  );
  final sources = Sources();
  if (held) sources.pending = Completer<List<CatalogueBook>>();
  final router = GoRouter(
    routes: [
      GoRoute(
        path: '/',
        builder: (_, _) => const RepaintBoundary(
          key: ValueKey('bulk-review-capture'),
          child: BulkSourceMigrationScreen(
            sources: targets,
            initialSource: 'tachimanga:old',
            initialBookIds: {'old'},
          ),
        ),
      ),
    ],
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        preferencesProvider.overrideWithValue(preferences),
        libraryRepositoryProvider.overrideWithValue(books),
        sourceRepositoryProvider.overrideWithValue(sources),
      ],
      child: MaterialApp.router(
        theme: appTheme(Brightness.dark).copyWith(
          appBarTheme: appTheme(Brightness.dark).appBarTheme.copyWith(
            titleTextStyle: appTheme(Brightness.dark)
                .appBarTheme
                .titleTextStyle!
                .copyWith(fontFamily: 'NotoSans'),
          ),
          textTheme: appTheme(Brightness.dark).textTheme
              .apply(fontFamily: 'NotoSans'),
        ),
        routerConfig: router,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return (books: books, sources: sources, router: router);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    for (final family in [
      'NotoSans',
      'CupertinoSystemText',
      'CupertinoSystemDisplay',
      'Roboto',
    ]) {
      await (FontLoader(
        family,
      )..addFont(rootBundle.load('assets/fonts/notosans.ttf'))).load();
    }
    await (FontLoader('packages/cupertino_icons/CupertinoIcons')..addFont(
          rootBundle.load('packages/cupertino_icons/assets/CupertinoIcons.ttf'),
        ))
        .load();
  });
  for (final (size, scale) in [
    (const Size(430, 932), 1.0),
    (const Size(320, 568), 1.5),
  ]) {
    testWidgets(
      'batch target/settings/search/review remains read-only until confirmation at $size/$scale',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = size;
        addTearDown(tester.view.reset);
        final fixture = await open(tester, scale: scale);
        final before = (await fixture.books.snapshot()).fingerprint;
        await begin(tester);
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('migration-bulk-result-old')),
          findsOneWidget,
        );
        expect(find.text('Nguồn cũ'), findsOneWidget);
        expect(find.text('Nguồn 1'), findsOneWidget);
        expect(find.text('Mới nhất: Chương 3'), findsOneWidget);
        expect(find.text('Xem lại và chuyển 1 truyện'), findsOneWidget);
        expect((await fixture.books.snapshot()).fingerprint, before);
        if (size.width == 430) {
          final boundary = tester.renderObject<RenderRepaintBoundary>(
            find.byKey(const ValueKey('bulk-review-capture')),
          );
          await tester.runAsync(() async {
            final image = await boundary.toImage(pixelRatio: 1);
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            await File('artifacts/bulk-migration-review-430.png')
                .writeAsBytes(bytes!.buffer.asUint8List());
            image.dispose();
          });
          await tester.tap(find.byTooltip('Sửa kết quả Tên truyện'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('Tìm và chọn kết quả khác'));
          await tester.pumpAndSettle();
          await tester.tap(find.widgetWithText(ListTile, 'Tên truyện').first);
          await tester.pumpAndSettle();
          await tester.ensureVisible(find.text('Dùng kết quả này'));
          await tester.tap(find.text('Dùng kết quả này'));
          await tester.pumpAndSettle();
          expect(
            find.byKey(const ValueKey('migration-bulk-result-old')),
            findsOneWidget,
          );
          expect((await fixture.books.snapshot()).fingerprint, before);
        }
        await tester.tap(find.text('Xem lại và chuyển 1 truyện'));
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text('Chuyển và giữ truyện cũ'));
        await tester.tap(find.text('Chuyển và giữ truyện cũ'));
        await tester.pumpAndSettle();
        expect((await fixture.books.list()).length, 2);
        expect(find.text('Đã chuyển 1 truyện.'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        fixture.router.dispose();
        fixture.sources.dispose();
      },
    );
  }
  testWidgets(
    'cancel batch before first result and skip result never mutates library',
    (tester) async {
      final fixture = await open(tester, held: true);
      final before = (await fixture.books.snapshot()).fingerprint;
      await begin(tester);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.text('Hủy tìm và ghép'), findsOneWidget);
      await tester.tap(find.text('Hủy tìm và ghép'));
      await tester.pumpAndSettle();
      fixture.sources.pending!.complete(CataloguePage([], hasNextPage: false));
      await tester.pumpAndSettle();
      expect(find.text('Xem lại và chuyển 0 truyện'), findsOneWidget);
      await tester.tap(find.byTooltip('Sửa kết quả Tên truyện'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Bỏ qua truyện này'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('migration-bulk-result-old')),
        findsNothing,
      );
      expect((await fixture.books.snapshot()).fingerprint, before);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      fixture.router.dispose();
      fixture.sources.dispose();
    },
  );
  testWidgets(
    'ordered source picker returns chosen priority rather than inventory order',
    (tester) async {
      List<CatalogueSource>? chosen;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async {
                  chosen = await selectMigrationSources(
                    context,
                    candidates: targets,
                    selected: {'tachimanga:2', 'tachimanga:1'},
                    ordered: true,
                  );
                },
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      final list = tester.widget<ReorderableListView>(
        find.byType(ReorderableListView),
      );
      list.onReorderItem!(0, 1);
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('migration-sources-continue')),
      );
      await tester.pumpAndSettle();
      expect(chosen!.map((s) => s.id), ['1', '2']);
      expect(tester.takeException(), isNull);
    },
  );
}
