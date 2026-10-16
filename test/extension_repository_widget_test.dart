import 'dart:async';
import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tachi_books/core/theme/app_theme.dart';
import 'package:tachi_books/features/library/data/library_repository.dart';
import 'package:tachi_books/features/library/presentation/library_view_model.dart';
import 'package:tachi_books/features/settings/settings_controller.dart';
import 'package:tachi_books/features/sources/data/extension_index.dart';
import 'package:tachi_books/features/sources/data/on_device_source_repository.dart';
import 'package:tachi_books/features/sources/domain/catalogue.dart';
import 'package:tachi_books/features/sources/domain/native_source_engine.dart';
import 'package:tachi_books/features/sources/presentation/browse_screen.dart';
import 'package:tachi_books/features/sources/presentation/browse_widgets.dart';
import 'package:tachi_books/features/sources/presentation/extension_catalogue_controller.dart';
import 'package:tachi_books/features/sources/presentation/extension_repository_screen.dart';
import 'package:tachi_books/features/sync/presentation/sync_screen.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final size in const [Size(320, 568), Size(430, 932)]) {
    testWidgets(
      'repository add/copy/install/remove uses native engines without server URLs at $size',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = size;
        addTearDown(tester.view.reset);
        final prefs = await SharedPreferences.getInstance();
        final tachi = _NativeFixture(SourceEngine.tachimanga)..installed = true;
        final vbook = _NativeFixture(SourceEngine.vbook);
        final requests = <String>[];
        final router = await _mount(tester, prefs, tachi, vbook, requests);
        expect(tachi.sourceLoads, 1);
        expect(vbook.sourceLoads, 1);
        expect(find.text('Manga fixture'), findsOneWidget);
        _noConnectionPrompt();

        await tester.tap(find.byTooltip('Công cụ nguồn'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Kho tiện ích mở rộng'));
        await tester.pumpAndSettle();
        expect(
          router.routerDelegate.currentConfiguration.last.matchedLocation,
          '/repositories',
        );
        expect(find.byType(ExtensionRepositoryScreen), findsOneWidget);
        await _openAdd(tester, 'vBook');
        await tester.tap(find.text('Dùng kho vBook / Darkrai9x'));
        await tester.pump();
        expect(
          tester.widget<TextField>(find.byType(TextField)).controller!.text,
          'https://raw.githubusercontent.com/Darkrai9x/vbook-extensions/master/plugin.json',
        );
        await tester.enterText(
          find.byType(TextField),
          'https://fixture.test/plugin.json',
        );
        await tester.tap(find.text('Thêm'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Xác nhận'));
        await _waitForSave(tester, prefs);
        await tester.pumpAndSettle();
        expect(requests, ['https://fixture.test/plugin.json']);
        expect(vbook.installs, isEmpty);
        expect(find.text('1 tiện ích mở rộng'), findsOneWidget);
        expect(jsonDecode(prefs.getString('extensionRepositoriesV1')!), [
          {'url': 'https://fixture.test/plugin.json', 'engine': 'vbook'},
        ]);

        String? copied;
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          (call) async {
            if (call.method == 'Clipboard.setData') {
              copied = (call.arguments as Map)['text'] as String;
            }
            return null;
          },
        );
        addTearDown(
          () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            SystemChannels.platform,
            null,
          ),
        );
        await tester.tap(find.byTooltip('Sao chép link kho'));
        await tester.pumpAndSettle();
        expect(copied, 'https://fixture.test/plugin.json');
        expect(tester.takeException(), isNull);

        router.pop();
        await tester.pumpAndSettle();
        await tester.tap(find.text('Tiện ích'));
        await tester.pumpAndSettle();
        expect(find.text('Novel fixture'), findsOneWidget);
        expect(find.text('Cài'), findsOneWidget);
        final pendingInstall = Completer<void>();
        vbook.pendingInstall = pendingInstall;
        // Add and copy each queue a confirmation. Let both dismiss before
        // tapping the last package near the bottom on a 320 px screen.
        for (var notice = 0; notice < 2; notice++) {
          await tester.pump(const Duration(seconds: 5));
          await tester.pumpAndSettle();
        }
        await tester.ensureVisible(find.text('Cài'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Cài'));
        await tester.pump();
        expect(vbook.installs, ['https://fixture.test/plugin.zip']);
        expect(vbook.installed, isFalse);
        // Only the existing manga engine package is installed at this point.
        expect(find.text('Đã cài'), findsOneWidget);
        expect(find.byType(CupertinoActivityIndicator), findsOneWidget);
        pendingInstall.complete();
        await tester.pumpAndSettle();
        expect(vbook.installed, isTrue);
        expect(find.text('Đã cài'), findsWidgets);
        expect(find.text('Cài'), findsNothing);

        await tester.ensureVisible(find.text('Kho tiện ích mở rộng'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Kho tiện ích mở rộng'));
        await tester.pumpAndSettle();
        expect(find.byType(ExtensionRepositoryScreen), findsOneWidget);
        await tester.tap(find.byTooltip('Gỡ kho khỏi danh sách'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Gỡ kho'));
        await tester.pumpAndSettle();
        expect(
          jsonDecode(prefs.getString('extensionRepositoriesV1')!),
          isEmpty,
        );
        expect(
          find.textContaining('Chưa có kho tiện ích mở rộng.'),
          findsOneWidget,
        );
        expect(vbook.installed, isTrue);
        router.pop();
        await tester.pumpAndSettle();
        await tester.tap(find.text('Nguồn truyện'));
        await tester.pumpAndSettle();
        expect(find.text('Manga fixture'), findsOneWidget);
        expect(find.text('Novel fixture'), findsOneWidget);
        expect(find.byType(SourceBrowseRow), findsNWidgets(2));
        expect(prefs.getString('tachimangaUrl'), isNull);
        expect(prefs.getString('vbookUrl'), isNull);
        _noConnectionPrompt();
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        router.dispose();
      },
    );

    testWidgets('cloud opens SyncScreen and Keiyoushi preset at $size', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = size;
      addTearDown(tester.view.reset);
      final prefs = await SharedPreferences.getInstance();
      final requests = <String>[];
      final router = await _mount(
        tester,
        prefs,
        _NativeFixture(SourceEngine.tachimanga),
        _NativeFixture(SourceEngine.vbook),
        requests,
      );
      await tester.tap(find.byTooltip('Đồng bộ'));
      await tester.pumpAndSettle();
      expect(find.byType(SyncScreen), findsOneWidget);
      expect(find.text('Đồng bộ'), findsOneWidget);
      _noConnectionPrompt();
      Navigator.of(tester.element(find.byType(SyncScreen))).pop();
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Công cụ nguồn'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Kho tiện ích mở rộng'));
      await tester.pumpAndSettle();
      await _openAdd(tester, 'Tachimanga');
      await tester.tap(find.text('Dùng kho Keiyoushi'));
      await tester.pump();
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'https://github.com/keiyoushi/extensions',
      );
      await tester.tap(find.text('Hủy'));
      await tester.pumpAndSettle();
      expect(requests, isEmpty);
      expect(prefs.getString('extensionRepositoriesV1'), isNull);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      router.dispose();
    });
    testWidgets('repository custom name is reachable and saved at $size', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = size;
      addTearDown(tester.view.reset);
      SharedPreferences.setMockInitialValues({
        'extensionRepositoriesV1': jsonEncode([
          {'url': 'https://fixture.test/plugin.json', 'engine': 'vbook'},
        ]),
      });
      final prefs = await SharedPreferences.getInstance();
      final router = await _mount(
        tester,
        prefs,
        _NativeFixture(SourceEngine.tachimanga),
        _NativeFixture(SourceEngine.vbook),
        [],
      );
      final container = ProviderScope.containerOf(
        tester.element(find.byType(BrowseScreen)),
      );
      await tester.runAsync(
        () => container.read(extensionCatalogueProvider.future),
      );
      await tester.tap(find.byTooltip('Công cụ nguồn'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Kho tiện ích mở rộng'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Đổi tên kho'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Kho của tôi');
      await tester.tap(find.text('Lưu'));
      await tester.runAsync(() async {
        final deadline = DateTime.now().add(const Duration(seconds: 3));
        while ((jsonDecode(
              prefs.getString('extensionRepositoriesV1')!,
            ) as List).single['name'] !=
            'Kho của tôi') {
          if (DateTime.now().isAfter(deadline)) {
            throw StateError(
              'Repository rename was not saved: ${container.read(extensionCatalogueProvider)}',
            );
          }
          await Future<void>.delayed(const Duration(milliseconds: 1));
        }
      });
      await tester.pumpAndSettle();
      expect(find.text('Kho của tôi'), findsOneWidget);
      expect(
        (jsonDecode(
          prefs.getString('extensionRepositoriesV1')!,
        ) as List).single['name'],
        'Kho của tôi',
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      router.dispose();
    });
  }

  testWidgets(
    'failed native install keeps catalogue available without false installed state',
    (tester) async {
      SharedPreferences.setMockInitialValues({
        'extensionRepositoriesV1': jsonEncode([
          {'url': 'https://fixture.test/plugin.json', 'engine': 'vbook'},
        ]),
      });
      final prefs = await SharedPreferences.getInstance();
      final native = _NativeFixture(SourceEngine.vbook)
        ..installFailure = const ApiException('Gói extension không hợp lệ.');
      final router = await _mount(
        tester,
        prefs,
        _NativeFixture(SourceEngine.tachimanga),
        native,
        [],
      );
      await tester.tap(find.text('Tiện ích'));
      final container = ProviderScope.containerOf(
        tester.element(find.byType(BrowseScreen)),
      );
      await tester.runAsync(
        () => container.read(extensionCatalogueProvider.future),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cài'));
      await tester.pumpAndSettle();
      expect(native.installed, isFalse);
      expect(find.textContaining('Gói extension không hợp lệ.'), findsWidgets);
      expect(find.text('Đã cài'), findsNothing);
      expect(find.text('Cài'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      router.dispose();
    },
  );
}

void _noConnectionPrompt() {
  expect(find.textContaining('Kết nối nguồn'), findsNothing);
  expect(find.textContaining('Kết nối Tachimanga'), findsNothing);
  expect(find.textContaining('Kết nối vBook'), findsNothing);
}

Future<void> _openAdd(WidgetTester tester, String engine) async {
  await tester.tap(find.byTooltip('Thêm kho tiện ích mở rộng'));
  await tester.pumpAndSettle();
  await tester.tap(find.text(engine).last);
  await tester.pumpAndSettle();
}

Future<void> _waitForSave(WidgetTester tester, SharedPreferences prefs) =>
    tester.runAsync(() async {
      final deadline = DateTime.now().add(const Duration(seconds: 3));
      while (prefs.getString('extensionRepositoriesV1') == null) {
        if (DateTime.now().isAfter(deadline)) {
          throw StateError('Repository was not saved.');
        }
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
    });

Future<GoRouter> _mount(
  WidgetTester tester,
  SharedPreferences prefs,
  _NativeFixture tachi,
  _NativeFixture vbook,
  List<String> requests,
) async {
  final sourceRepository = OnDeviceSourceRepository(
    tachimangaUrl: '',
    vbookUrl: '',
    runtimes: {SourceEngine.tachimanga: tachi, SourceEngine.vbook: vbook},
  );
  addTearDown(sourceRepository.dispose);
  final router = GoRouter(
    routes: [
      GoRoute(path: '/', builder: (_, _) => const BrowseScreen()),
      GoRoute(
        path: '/repositories',
        builder: (_, _) => const ExtensionRepositoryScreen(),
      ),
    ],
  );
  final client = MockClient((request) async {
    requests.add(request.url.toString());
    return http.Response(
      jsonEncode({
        'data': [
          {
            'name': 'Novel fixture',
            'path': 'plugin.zip',
            'version': 1,
            'locale': 'vi',
          },
        ],
      }),
      200,
    );
  });
  addTearDown(client.close);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        preferencesProvider.overrideWithValue(prefs),
        sourceRepositoryProvider.overrideWithValue(sourceRepository),
        extensionIndexRepositoryProvider.overrideWithValue(
          ExtensionIndexRepository(client),
        ),
        libraryRepositoryProvider.overrideWithValue(MemoryLibraryRepository()),
      ],
      child: MaterialApp.router(
        theme: appTheme(Brightness.dark),
        routerConfig: router,
      ),
    ),
  );
  await tester.pumpAndSettle();
  return router;
}

// This fixture proves UI dispatch through the on-device repository contract;
// it does not execute JavaScriptCore or APK bytecode in a host widget test.
class _NativeFixture implements NativeSourceEngine {
  _NativeFixture(this.engine);
  final SourceEngine engine;
  bool installed = false;
  int sourceLoads = 0;
  Completer<void>? pendingInstall;
  ApiException? installFailure;
  final installs = <String>[];
  String get name =>
      engine == SourceEngine.vbook ? 'Novel fixture' : 'Manga fixture';

  @override
  Future<List<CatalogueSource>> listSources() async {
    sourceLoads++;
    return [
      if (installed)
        CatalogueSource(
          id: 'fixture-${engine.name}',
          name: name,
          lang: 'vi',
          baseUrl: 'https://source.test',
          engine: engine,
          kind: engine == SourceEngine.vbook
              ? ContentKind.novel
              : ContentKind.manga,
        ),
    ];
  }

  @override
  Future<List<CatalogueExtension>> extensions() async => [
    if (installed)
      CatalogueExtension(
        id: 'fixture-${engine.name}',
        name: name,
        version: '1',
        engine: engine,
        installed: true,
        packageUrl: 'https://fixture.test/plugin.zip',
      ),
  ];

  @override
  Future<void> installExtension(String packageUrl) async {
    installs.add(packageUrl);
    if (installFailure != null) throw installFailure!;
    if (pendingInstall != null) await pendingInstall!.future;
    installed = true;
  }

  @override
  void dispose() {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
