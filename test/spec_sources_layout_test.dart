import 'package:flutter/material.dart';
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
import 'package:tachi_books/features/sources/presentation/browse_screen.dart';
import 'package:tachi_books/features/sources/presentation/local_source_screen.dart';
import 'package:tachi_books/features/sources/presentation/source_migration_library_screen.dart';
import 'package:tachi_books/features/sources/presentation/source_search_screen.dart';
import 'package:tachi_books/features/sources/domain/source_languages.dart';

const _source = CatalogueSource(
  id: '2553532324170433933',
  name: 'TruyenQQ',
  lang: 'vi',
  baseUrl: 'https://source.test',
  kind: ContentKind.manga,
  engine: SourceEngine.tachimanga,
);
const _other = CatalogueSource(
  id: '8689080191405841403',
  name: 'MoeTruyen',
  lang: 'vi',
  baseUrl: 'https://other.test',
  kind: ContentKind.manga,
  engine: SourceEngine.tachimanga,
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  testWidgets('empty source language filter offers a working reset action', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'sourceLanguagesV1': const SourceLanguages({}).encode(),
    });
    final fixture = await _mount(
      tester,
      const Size(320, 568),
      const BrowseScreen(),
      MemoryLibraryRepository(),
    );
    expect(find.text('TruyenQQ'), findsNothing);
    expect(find.text('Hiện tất cả nguồn'), findsOneWidget);
    await tester.tap(find.text('Hiện tất cả nguồn'));
    await tester.pumpAndSettle();
    expect(find.text('TruyenQQ'), findsOneWidget);
    expect(find.text('MoeTruyen'), findsOneWidget);
    expect(find.text('Hiện tất cả nguồn'), findsNothing);
    expect(tester.takeException(), isNull);
    await _dispose(tester, fixture);
  });
  testWidgets('empty source list opens the existing extension sub-tab', (
    tester,
  ) async {
    final repository = _Sources()..empty = true;
    final fixture = await _mount(
      tester,
      const Size(320, 568),
      const BrowseScreen(),
      MemoryLibraryRepository(),
      sources: repository,
    );
    expect(find.text('Mở Tiện ích'), findsOneWidget);
    await tester.tap(find.text('Mở Tiện ích'));
    await tester.pumpAndSettle();
    expect(find.text('Có sẵn trong kho'), findsOneWidget);
    expect(find.text('Mở Tiện ích'), findsNothing);
    expect(tester.takeException(), isNull);
    await _dispose(tester, fixture);
  });
  for (final id in ['sách /%?# kỳ', '.', '..']) {
    testWidgets(
      'local source opens opaque imported ID $id without changing identity',
      (tester) async {
        final library = MemoryLibraryRepository();
        await library.save(LibraryBook(id: id, title: 'Sách cục bộ'));
        final fixture = await _mount(
          tester,
          const Size(430, 932),
          const LocalSourceScreen(),
          library,
        );
        await tester.tap(find.byKey(ValueKey('local-source-$id')));
        await tester.pumpAndSettle();
        expect(find.text('Book route: $id'), findsOneWidget);
        expect(await library.find(id), isNotNull);
        expect(tester.takeException(), isNull);
        await _dispose(tester, fixture);
      },
    );
  }
  testWidgets(
    'failed pull refresh retains loaded covers and retry repeats first page',
    (tester) async {
      final repository = _Sources();
      final fixture = await _mount(
        tester,
        const Size(430, 932),
        const SourceSearchScreen(source: _source),
        MemoryLibraryRepository(),
        sources: repository,
      );
      final result = find.byKey(
        const ValueKey('source-result-tachimanga:2553532324170433933:/title'),
      );
      expect(result, findsOneWidget);
      repository.failBrowse = true;
      await tester.drag(find.byType(CustomScrollView), const Offset(0, 350));
      await tester.pumpAndSettle();
      expect(repository.requestedPages, [1, 1]);
      expect(result, findsOneWidget);
      expect(find.text('Không có kết quả'), findsNothing);
      repository.failBrowse = false;
      await tester.tap(find.text('Thử lại'));
      await tester.pumpAndSettle();
      expect(repository.requestedPages, [1, 1, 1]);
      expect(result, findsOneWidget);
      expect(tester.takeException(), isNull);
      await _dispose(tester, fixture);
    },
  );
  for (final size in const [Size(320, 568), Size(430, 932)]) {
    testWidgets(
      'discovery uses two source sub-tabs and preserves migration tools at $size / 150%',
      (tester) async {
        final fixture = await _mount(
          tester,
          size,
          const BrowseScreen(),
          MemoryLibraryRepository(),
        );
        expect(find.text('Khám phá'), findsOneWidget);
        expect(find.text('Nguồn truyện'), findsOneWidget);
        expect(find.text('Tiện ích'), findsOneWidget);
        expect(find.text('Di chuyển'), findsNothing);
        expect(find.text('TruyenQQ'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.tap(find.text('Tiện ích'));
        await tester.pumpAndSettle();
        expect(find.text('Có sẵn trong kho'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.tap(find.byTooltip('Công cụ nguồn'));
        await tester.pumpAndSettle();
        expect(find.text('Chuyển nguồn'), findsOneWidget);
        expect(find.text('Kho tiện ích mở rộng'), findsWidgets);
        expect(tester.takeException(), isNull);
        await _dispose(tester, fixture);
      },
    );
    testWidgets(
      'local source shows real imported chapters and opens existing identity at $size / 150%',
      (tester) async {
        final library = MemoryLibraryRepository();
        await library.save(
          LibraryBook(
            id: 'local',
            title: 'Truyện đã nhập từ Files',
            kind: 'manga',
            chapters: const [
              BookChapter(id: 'one', title: 'Chương một', index: 0),
              BookChapter(id: 'two', title: 'Chương hai', index: 1),
            ],
          ),
        );
        await library.save(
          LibraryBook(
            id: 'online',
            title: 'Truyện online',
            engine: 'tachimanga',
            sourceId: _source.id,
          ),
        );
        final before = (await library.snapshot()).encode();
        final fixture = await _mount(
          tester,
          size,
          const LocalSourceScreen(),
          library,
        );
        expect(
          find.byKey(const ValueKey('local-source-local')),
          findsOneWidget,
        );
        expect(find.text('2 chương'), findsOneWidget);
        expect(find.text('Truyện online'), findsNothing);
        expect(find.text('Nhập truyện từ Files'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.tap(find.byKey(const ValueKey('local-source-local')));
        await tester.pumpAndSettle();
        expect(find.text('Book route: local'), findsOneWidget);
        expect((await library.snapshot()).encode(), before);
        await _dispose(tester, fixture);
      },
    );

    testWidgets(
      'migration picks exact old source then covered titles without data mutation at $size / 150%',
      (tester) async {
        final library = MemoryLibraryRepository();
        for (final (id, source) in [
          ('one', _source),
          ('two', _source),
          ('three', _other),
        ]) {
          await library.save(
            LibraryBook(
              id: id,
              title: 'Truyện $id',
              kind: 'manga',
              engine: source.engine.name,
              sourceId: source.id,
              sourceName: source.name,
              sourceRef: '/$id',
            ),
          );
        }
        final before = (await library.snapshot()).encode();
        final fixture = await _mount(
          tester,
          size,
          const SourceMigrationLibraryScreen(),
          library,
        );
        expect(find.text('TruyenQQ'), findsOneWidget);
        expect(find.text('2 truyện'), findsOneWidget);
        expect(find.text('MoeTruyen'), findsOneWidget);
        expect(find.textContaining('2553532324170433933'), findsNothing);
        await tester.tap(
          find.byKey(
            const ValueKey('migration-origin-tachimanga:2553532324170433933'),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('migration-book-one')),
          findsOneWidget,
        );
        await tester.scrollUntilVisible(
          find.byKey(const ValueKey('migration-book-two')),
          80,
        );
        expect(
          find.byKey(const ValueKey('migration-book-two')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('migration-book-three')),
          findsNothing,
        );
        expect(find.text('Chuyển nguồn hàng loạt'), findsOneWidget);
        expect(tester.takeException(), isNull);
        expect((await library.snapshot()).encode(), before);
        await _dispose(tester, fixture);
      },
    );

    testWidgets(
      'catalogue failure has error and retry instead of false empty results at $size / 150%',
      (tester) async {
        final repository = _Sources()..failBrowse = true;
        final fixture = await _mount(
          tester,
          size,
          const SourceSearchScreen(source: _source),
          MemoryLibraryRepository(),
          sources: repository,
        );
        expect(find.text('Chưa tải được truyện'), findsOneWidget);
        expect(find.text('Không có kết quả'), findsNothing);
        expect(tester.takeException(), isNull);
        repository.failBrowse = false;
        await tester.tap(find.text('Thử lại'));
        await tester.pumpAndSettle();
        expect(find.text('Chưa tải được truyện'), findsNothing);
        expect(
          find.byKey(
            const ValueKey(
              'source-result-tachimanga:2553532324170433933:/title',
            ),
          ),
          findsOneWidget,
        );
        expect(repository.browseCalls, 2);
        expect(tester.takeException(), isNull);
        await _dispose(tester, fixture);
      },
    );
  }
}

typedef _Fixture = ({GoRouter router, _Sources repository});
Future<_Fixture> _mount(
  WidgetTester tester,
  Size size,
  Widget screen,
  MemoryLibraryRepository library, {
  _Sources? sources,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);
  final prefs = await SharedPreferences.getInstance();
  final repository = sources ?? _Sources();
  final router = GoRouter(
    routes: [
      GoRoute(path: '/', builder: (_, _) => screen),
      GoRoute(
        path: '/book/:id',
        builder: (_, state) => Scaffold(
          body: Text(
            'Book route: ${state.uri.queryParameters['bookId'] ?? state.pathParameters['id']}',
          ),
        ),
      ),
    ],
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        preferencesProvider.overrideWithValue(prefs),
        libraryRepositoryProvider.overrideWithValue(library),
        sourceRepositoryProvider.overrideWithValue(repository),
      ],
      child: MaterialApp.router(
        theme: appTheme(Brightness.dark),
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
  return (router: router, repository: repository);
}

Future<void> _dispose(WidgetTester tester, _Fixture fixture) async {
  await tester.pumpWidget(const SizedBox.shrink());
  fixture.router.dispose();
  fixture.repository.dispose();
}

class _Sources extends SourceRepository {
  _Sources() : super(tachimangaUrl: '', vbookUrl: '');
  bool failBrowse = false;
  bool empty = false;
  int browseCalls = 0;
  final requestedPages = <int>[];
  @override
  bool requiresExternalConnection(SourceEngine engine) => false;
  @override
  Future<List<CatalogueExtension>> extensions(SourceEngine engine) async => [];
  @override
  Future<List<CatalogueSource>> listSources(SourceEngine engine) async =>
      engine == SourceEngine.tachimanga && !empty ? [_source, _other] : [];
  @override
  bool supportsCatalogueBrowsing(SourceEngine engine) => true;
  @override
  Future<List<CatalogueBook>> browse(
    CatalogueSource source, {
    required SourceBrowseMode mode,
    int page = 1,
  }) async {
    browseCalls++;
    requestedPages.add(page);
    if (failBrowse) throw const ApiException('Nguồn tạm thời chưa phản hồi.');
    return [
      CatalogueBook(
        ref: '/title',
        title: 'Truyện trong nguồn',
        sourceId: source.id,
        kind: source.kind,
        engine: source.engine,
      ),
    ];
  }
}
