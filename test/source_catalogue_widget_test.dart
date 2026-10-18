import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:tachi_books/core/theme/app_theme.dart';
import 'package:tachi_books/features/library/data/library_repository.dart';
import 'package:tachi_books/features/library/data/backup_configuration.dart';
import 'package:tachi_books/features/library/data/coordinated_preferences.dart';
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
  testWidgets(
    'failed source layout persistence does not publish or retain a RAM-only choice',
    (tester) async {
      SharedPreferencesStorePlatform.instance = _FailingLayoutStore();
      final repo = _Repository();
      final fixture = await _mount(
        tester,
        repo,
        const SourceSearchScreen(source: _source),
      );
      await tester.tap(find.byTooltip('Hiển thị truyện'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Danh sách'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<SourceResultTile>(find.byType(SourceResultTile)).list,
        isFalse,
      );
      expect(fixture.prefs.getString('sourceCatalogueLayoutV1'), isNull);
      await _dispose(tester, fixture, repo);
    },
  );

  testWidgets(
    'source layout popup opened before restore cannot overwrite restored choice',
    (tester) async {
      final raw = await SharedPreferences.getInstance();
      final prefs = await CoordinatedPreferences.open(
        raw,
        MemoryLibraryRepository(),
      );
      final repo = _Repository();
      final fixture = await _mount(
        tester,
        repo,
        const SourceSearchScreen(source: _source),
        preferences: prefs,
      );
      await tester.tap(find.byTooltip('Hiển thị truyện'));
      await tester.pumpAndSettle();
      final before = BackupConfiguration.capture(prefs);
      final image = await fixture.library.snapshot();
      final restored = BackupConfiguration.fromJson({
        'version': 1,
        'preferences': {...before.values, 'sourceCatalogueLayoutV1': 'list'},
      });
      await prefs.exclusive(
        () => prefs.restoreLocked(
          incoming: restored,
          expectedFingerprint: before.fingerprint,
          oldLibraryFingerprint: image.fingerprint,
          newLibraryFingerprint: image.fingerprint,
          commit: (publish) => publish(),
        ),
      );
      await tester.tap(find.text('Lưới lớn'));
      await tester.pumpAndSettle();
      expect(prefs.getString('sourceCatalogueLayoutV1'), 'list');
      expect(
        tester.widget<SourceResultTile>(find.byType(SourceResultTile)).list,
        isFalse,
      );
      await _dispose(tester, fixture, repo);
    },
  );

  testWidgets(
    'source reference header and five-column shelf keep identity badges',
    (tester) async {
      final repo = _Repository()
        ..catalogueBooks = [
          _book,
          for (var i = 1; i < 12; i++)
            CatalogueBook(
              ref: '/title-$i',
              title: 'Truyện $i',
              sourceId: _source.id,
              kind: _source.kind,
              engine: _source.engine,
            ),
        ];
      final fixture = await _mount(
        tester,
        repo,
        const SourceSearchScreen(source: _source),
      );
      expect(find.text('Source A (VI)'), findsOneWidget);
      expect(find.text(_source.baseUrl), findsOneWidget);
      expect(find.byType(CupertinoSearchTextField), findsNothing);
      expect(find.text('Trong thư viện'), findsOneWidget);
      final tiles = find.byType(SourceResultTile);
      final firstRowY = tester.getTopLeft(tiles.at(0)).dy;
      for (var i = 1; i < 5; i++) {
        expect(tester.getTopLeft(tiles.at(i)).dy, firstRowY);
      }
      expect(tester.getTopLeft(tiles.at(5)).dy, greaterThan(firstRowY));
      expect(tester.getSize(tiles.first).width, lessThan(85));
      await tester.tap(find.byTooltip('Tìm'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(CupertinoSearchTextField), 'Tên mới');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();
      expect(repo.searched, ['Tên mới']);
      await tester.tap(find.text('Mới nhất'));
      await tester.pumpAndSettle();
      expect(repo.browsed.last, SourceBrowseMode.latest);
      await _dispose(tester, fixture, repo);
    },
  );

  for (final size in const [Size(320, 568), Size(430, 932)]) {
    testWidgets('source controls remain reachable at $size and large text', (
      tester,
    ) async {
      final repo = _Repository();
      final fixture = await _mount(
        tester,
        repo,
        const SourceSearchScreen(source: _source),
        size: size,
        scale: 1.5,
      );
      expect(tester.takeException(), isNull);
      expect(find.text(_source.baseUrl), findsOneWidget);
      final toolbar = find.byType(SingleChildScrollView).first;
      await tester.drag(toolbar, const Offset(-500, 0));
      await tester.pumpAndSettle();
      expect(find.byTooltip('Bộ lọc của nguồn').hitTestable(), findsOneWidget);
      await tester.tap(find.byTooltip('Hiển thị truyện'));
      await tester.pumpAndSettle();
      expect(find.text('Lưới nhỏ gọn'), findsOneWidget);
      await tester.tap(find.text('Hủy'));
      await tester.pumpAndSettle();
      await _dispose(tester, fixture, repo);
    });
  }

  testWidgets(
    'nonempty final source page stops pagination from the actual flag',
    (tester) async {
      final repo = _Repository()..finalPage = true;
      final fixture = await _mount(
        tester,
        repo,
        const SourceSearchScreen(source: _source),
      );
      expect(find.byType(SourceResultTile), findsOneWidget);
      expect(find.text('Tải thêm kết quả'), findsNothing);
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -1500));
      await tester.pumpAndSettle();
      expect(repo.browsed, [SourceBrowseMode.popular]);
      await _dispose(tester, fixture, repo);
    },
  );

  testWidgets(
    'unsupported latest capability keeps popular without a latest control',
    (tester) async {
      const source = CatalogueSource(
        id: 'no-latest',
        name: 'Popular only',
        lang: 'vi',
        baseUrl: 'https://source.test',
        kind: ContentKind.manga,
        engine: SourceEngine.tachimanga,
        supportsLatest: false,
      );
      final repo = _Repository();
      final fixture = await _mount(
        tester,
        repo,
        const SourceSearchScreen(source: source),
      );
      expect(find.text('Mới nhất'), findsNothing);
      expect(repo.browsed, [SourceBrowseMode.popular]);
      expect(find.byType(SourceResultTile), findsOneWidget);
      await _dispose(tester, fixture, repo);
    },
  );
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
  Size size = const Size(430, 932),
  double scale = 1,
  SharedPreferences? preferences,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);
  final prefs = preferences ?? await SharedPreferences.getInstance(),
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
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
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

class _FailingLayoutStore extends InMemorySharedPreferencesStore {
  _FailingLayoutStore() : super.withData({});
  @override
  Future<bool> setValue(String type, String key, Object value) async {
    if (key == 'flutter.sourceCatalogueLayoutV1') return false;
    return super.setValue(type, key, value);
  }
}

class _Repository extends SourceRepository {
  _Repository() : super(tachimangaUrl: '', vbookUrl: '');
  final browsed = <SourceBrowseMode>[];
  final searched = <String>[];
  List<CatalogueBook> catalogueBooks = [_book];
  final installs = <String>[], removed = <String>[];
  final versions = {'a': '1', 'b': '1'};
  Completer<List<CatalogueBook>>? slowSearch;
  Completer<void>? firstInstallGate;
  bool rejectSecond = false;
  bool rejectFiles = false;
  bool finalPage = false;
  int fileInstalls = 0;
  Uint8List? importedBytes;
  int detailLoads = 0;
  @override
  bool requiresExternalConnection(SourceEngine engine) => false;
  @override
  bool supportsCatalogueBrowsing(SourceEngine engine) => true;
  @override
  bool supportsSourceFilters(SourceEngine engine) => true;
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
    return finalPage
        ? CataloguePage(catalogueBooks, hasNextPage: false)
        : catalogueBooks;
  }

  @override
  Future<List<CatalogueBook>> search(
    CatalogueSource source,
    String query, {
    int page = 1,
  }) async {
    searched.add(query);
    return source.id == 'slow' ? slowSearch!.future : [_book];
  }

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
