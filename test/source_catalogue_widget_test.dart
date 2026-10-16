import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/cupertino.dart';
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
import 'package:tachi_books/features/sources/data/extension_index.dart';
import 'package:tachi_books/features/sources/data/source_repository.dart';
import 'package:tachi_books/features/sources/domain/catalogue.dart';
import 'package:tachi_books/features/sources/presentation/browse_screen.dart';
import 'package:tachi_books/features/sources/presentation/extension_catalogue_controller.dart';
import 'package:tachi_books/features/sources/presentation/extension_file_import.dart';
import 'package:tachi_books/features/sources/presentation/global_search_screen.dart';
import 'package:tachi_books/features/sources/presentation/source_result_tile.dart';
import 'package:tachi_books/features/sources/presentation/source_search_screen.dart';

const _source = CatalogueSource(
  id: '9223372036854775806',
  name: 'Source A',
  lang: 'vi',
  baseUrl: 'https://example.test',
  kind: ContentKind.manga,
  engine: SourceEngine.tachimanga,
);
const _book = CatalogueBook(
  ref: '/original',
  title: 'Existing book',
  sourceId: '9223372036854775806',
  kind: ContentKind.manga,
  engine: SourceEngine.tachimanga,
);
CatalogueExtension _package(String id, String version) => CatalogueExtension(
  id: id,
  name: 'Package $id',
  engine: SourceEngine.tachimanga,
  version: version,
  installed: true,
  packageUrl: 'https://packages.test/$id.apk',
  lang: 'vi',
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  testWidgets(
    'APK selected from Files uses the on-device installer and exposes confirmed package metadata',
    (tester) async {
      final repo = _Repository();
      final input = Uint8List.fromList([0x50, 0x4b, 3, 4]);
      final fixture = await _mount(
        tester,
        repo,
        const BrowseScreen(),
        picker: () async => input,
      );
      await tester.tap(find.text('Tiện ích'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Nhập extension APK từ Files'));
      await tester.pumpAndSettle();
      expect(repo.fileInstalls, 1);
      expect(repo.importedBytes, input);
      expect(repo.installs, isEmpty);
      expect(find.textContaining('Đã cài Package c 1.6.25'), findsOneWidget);
      await tester.ensureVisible(find.text('Package c'));
      await tester.longPress(find.text('Package c'));
      await tester.pumpAndSettle();
      expect(find.textContaining('tachimanga:c'), findsNothing);
      expect(find.textContaining('Đã cài và nạp nguồn'), findsOneWidget);
      await tester.tap(find.text('Đóng'));
      await tester.pumpAndSettle();
      await _dispose(tester, fixture, repo);
    },
  );

  testWidgets(
    'cancelled Files selection and rejected installation cannot publish a package',
    (tester) async {
      final repo = _Repository()..rejectFiles = true;
      var selections = 0;
      final fixture = await _mount(
        tester,
        repo,
        const BrowseScreen(),
        picker: () async =>
            selections++ == 0 ? null : Uint8List.fromList([0x50, 0x4b, 3, 4]),
      );
      await tester.tap(find.text('Tiện ích'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Nhập extension APK từ Files'));
      await tester.pumpAndSettle();
      expect(repo.fileInstalls, 0);
      expect(find.textContaining('Đã cài Package c'), findsNothing);
      await tester.tap(find.text('Nhập extension APK từ Files'));
      await tester.pumpAndSettle();
      expect(repo.fileInstalls, 1);
      expect(find.textContaining('Thao tác chưa hoàn tất.'), findsOneWidget);
      expect(find.textContaining('APK factory failed'), findsNothing);
      expect(find.text('Package c'), findsNothing);
      await _dispose(tester, fixture, repo);
    },
  );

  testWidgets('an older catalogue release does not offer a misleading update', (
    tester,
  ) async {
    final repo = _Repository()..versions['a'] = '3';
    final fixture = await _mount(
      tester,
      repo,
      const BrowseScreen(),
      packages: [_package('a', '2')],
    );
    await tester.tap(find.text('Tiện ích'));
    await tester.pumpAndSettle();
    expect(find.text('Đã cài bản mới hơn'), findsOneWidget);
    expect(find.text('Cập nhật'), findsNothing);
    expect(find.textContaining('Cập nhật tất cả'), findsNothing);
    await _dispose(tester, fixture, repo);
  });
  testWidgets(
    'source popular/list/grid/refresh and existing-library navigation use real callbacks',
    (tester) async {
      final repo = _Repository();
      final fixture = await _mount(
        tester,
        repo,
        const SourceSearchScreen(source: _source),
      );
      expect(repo.browsed, [SourceBrowseMode.popular]);
      expect(
        tester
            .widget<SourceResultTile>(find.byType(SourceResultTile))
            .inLibrary,
        true,
      );
      await tester.tap(find.byTooltip('Hiển thị truyện'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Danh sách'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<SourceResultTile>(find.byType(SourceResultTile)).list,
        true,
      );
      expect(fixture.prefs.getString('sourceCatalogueLayoutV1'), 'list');
      await tester.drag(find.byType(CustomScrollView), const Offset(0, 300));
      await tester.pumpAndSettle();
      expect(repo.browsed.length, 2);
      await tester.tap(find.text('Mới nhất'));
      await tester.pumpAndSettle();
      expect(repo.browsed.last, SourceBrowseMode.latest);
      await tester.tap(find.byType(SourceResultTile));
      await tester.pumpAndSettle();
      expect(find.text('Book route: original-library-id'), findsOneWidget);
      expect(
        repo.detailLoads,
        0,
        reason: 'An existing book opens without adding another copy.',
      );
      await _dispose(tester, fixture, repo);
    },
  );

  testWidgets(
    'global search renders a fast source while another is pending, and opens existing results',
    (tester) async {
      final slow = Completer<List<CatalogueBook>>();
      final repo = _Repository()..slowSearch = slow;
      const second = CatalogueSource(
        id: 'slow',
        name: 'Slow source',
        lang: 'en',
        baseUrl: 'https://slow.test',
        kind: ContentKind.manga,
        engine: SourceEngine.tachimanga,
      );
      final fixture = await _mount(
        tester,
        repo,
        const GlobalSearchScreen(sources: [_source, second]),
      );
      await tester.enterText(find.byType(CupertinoSearchTextField), 'story');
      await tester.tap(find.text('Tìm'));
      await tester.pump();
      await tester.pump();
      expect(find.byType(SourceResultTile), findsOneWidget);
      expect(find.byType(CupertinoActivityIndicator), findsOneWidget);
      slow.complete([]);
      await tester.pumpAndSettle();
      expect(find.text('Không có kết quả ở nguồn này.'), findsOneWidget);
      await tester.tap(find.byType(SourceResultTile));
      await tester.pumpAndSettle();
      expect(find.text('Book route: original-library-id'), findsOneWidget);
      await _dispose(tester, fixture, repo);
    },
  );

  testWidgets(
    'update all is serial, shows queued state, retains failed package and confirms successful version',
    (tester) async {
      final gate = Completer<void>();
      final repo = _Repository()
        ..firstInstallGate = gate
        ..rejectSecond = true;
      final fixture = await _mount(
        tester,
        repo,
        const BrowseScreen(),
        packages: [_package('a', '2'), _package('b', '2')],
      );
      await tester.tap(find.text('Tiện ích'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cập nhật tất cả (2)'));
      await tester.pump();
      await tester.pump();
      expect(repo.installs, ['https://packages.test/a.apk']);
      expect(find.text('Đang chờ'), findsOneWidget);
      gate.complete();
      await tester.pumpAndSettle();
      expect(repo.installs, [
        'https://packages.test/a.apk',
        'https://packages.test/b.apk',
      ]);
      expect(repo.versions, {'a': '2', 'b': '1'});
      expect(find.textContaining('Thao tác chưa hoàn tất.'), findsOneWidget);
      expect(find.textContaining('install rejected'), findsNothing);
      expect(find.text('Cập nhật tất cả (1)'), findsOneWidget);
      expect(
        find.textContaining('Đã cập nhật 1 extension, 1 extension lỗi.'),
        findsOneWidget,
      );
      await _dispose(tester, fixture, repo);
    },
  );

  testWidgets(
    'uninstall is confirmed and preserves the original library book',
    (tester) async {
      final repo = _Repository();
      final fixture = await _mount(
        tester,
        repo,
        const BrowseScreen(),
        packages: [_package('a', '1')],
      );
      await tester.tap(find.text('Tiện ích'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byTooltip('Gỡ Package a'));
      await tester.tap(find.byTooltip('Gỡ Package a'));
      await tester.pumpAndSettle();
      expect(repo.removed, isEmpty);
      await tester.tap(find.text('Gỡ'));
      await tester.pumpAndSettle();
      expect(repo.removed, ['a']);
      expect(
        (await fixture.library.find('original-library-id'))!.title,
        'Existing book',
      );
      await _dispose(tester, fixture, repo);
    },
  );
}

typedef _Fixture = ({
  GoRouter router,
  SharedPreferences prefs,
  MemoryLibraryRepository library,
});
Future<_Fixture> _mount(
  WidgetTester tester,
  _Repository repo,
  Widget screen, {
  List<CatalogueExtension> packages = const [],
  Future<Uint8List?> Function()? picker,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(430, 932);
  addTearDown(tester.view.reset);
  final prefs = await SharedPreferences.getInstance(),
      library = MemoryLibraryRepository();
  await library.save(
    LibraryBook(
      id: 'original-library-id',
      title: 'Existing book',
      kind: 'manga',
      engine: 'tachimanga',
      sourceId: _source.id,
      sourceRef: _book.ref,
    ),
  );
  final router = GoRouter(
    routes: [
      GoRoute(path: '/', builder: (_, _) => screen),
      GoRoute(
        path: '/book/:id',
        builder: (_, state) =>
            Scaffold(body: Text('Book route: ${state.pathParameters['id']}')),
      ),
    ],
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        preferencesProvider.overrideWithValue(prefs),
        libraryRepositoryProvider.overrideWithValue(library),
        sourceRepositoryProvider.overrideWithValue(repo),
        extensionCatalogueProvider.overrideWith(() => _Catalogue(packages)),
        if (picker != null)
          extensionPackagePickerProvider.overrideWithValue(picker),
      ],
      child: MaterialApp.router(
        theme: appTheme(Brightness.dark),
        routerConfig: router,
      ),
    ),
  );
  await tester.pumpAndSettle();
  return (router: router, prefs: prefs, library: library);
}

Future<void> _dispose(
  WidgetTester tester,
  _Fixture fixture,
  _Repository repo,
) async {
  expect(tester.takeException(), isNull);
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pumpAndSettle();
  fixture.router.dispose();
  repo.dispose();
}

class _Catalogue extends ExtensionCatalogueController {
  _Catalogue(this.packages);
  final List<CatalogueExtension> packages;
  @override
  Future<List<ExtensionIndex>> build() async => packages.isEmpty
      ? []
      : [
          ExtensionIndex(
            'https://packages.test/index.pb',
            SourceEngine.tachimanga,
            packages,
          ),
        ];
}

class _Repository extends SourceRepository {
  _Repository() : super(tachimangaUrl: '', vbookUrl: '');
  final browsed = <SourceBrowseMode>[];
  final installs = <String>[], removed = <String>[];
  final versions = {'a': '1', 'b': '1'};
  Completer<List<CatalogueBook>>? slowSearch;
  Completer<void>? firstInstallGate;
  bool rejectSecond = false;
  bool rejectFiles = false;
  int fileInstalls = 0;
  Uint8List? importedBytes;
  int detailLoads = 0;
  @override
  bool requiresExternalConnection(SourceEngine engine) => false;
  @override
  bool supportsCatalogueBrowsing(SourceEngine engine) => true;
  @override
  bool supportsExtensionRemoval(SourceEngine engine) => true;
  @override
  bool supportsExtensionFileImport(SourceEngine engine) =>
      engine == SourceEngine.tachimanga;
  @override
  Future<CatalogueExtension> installExtensionBytes(
    SourceEngine engine,
    Uint8List bytes,
  ) async {
    expect(engine, SourceEngine.tachimanga);
    fileInstalls++;
    importedBytes = bytes;
    if (rejectFiles) throw const ApiException('APK factory failed');
    versions['c'] = '1.6.25';
    return _package('c', '1.6.25');
  }

  @override
  Future<List<CatalogueSource>> listSources(SourceEngine engine) async =>
      engine == SourceEngine.tachimanga ? [_source] : [];
  @override
  Future<List<CatalogueBook>> browse(
    CatalogueSource source, {
    required SourceBrowseMode mode,
    int page = 1,
  }) async {
    browsed.add(mode);
    return [_book];
  }

  @override
  Future<List<CatalogueBook>> search(
    CatalogueSource source,
    String query, {
    int page = 1,
  }) async => source.id == 'slow' ? slowSearch!.future : [_book];
  @override
  Future<CatalogueBook> detail(CatalogueBook book) async {
    detailLoads++;
    return book;
  }

  @override
  Future<List<CatalogueExtension>> extensions(SourceEngine engine) async =>
      engine == SourceEngine.tachimanga
      ? versions.entries.map((item) => _package(item.key, item.value)).toList()
      : [];
  @override
  Future<void> installExtension(SourceEngine engine, String url) async {
    installs.add(url);
    if (url.endsWith('/a.apk')) {
      await firstInstallGate?.future;
      versions['a'] = '2';
    } else {
      if (rejectSecond) throw const ApiException('install rejected');
      versions['b'] = '2';
    }
  }

  @override
  Future<void> uninstallExtension(SourceEngine engine, String id) async {
    removed.add(id);
    versions.remove(id);
  }
}
