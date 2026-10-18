import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tachi_books/features/library/presentation/library_view_model.dart';
import 'package:tachi_books/features/settings/settings_controller.dart';
import 'package:tachi_books/features/sources/data/on_device_source_repository.dart';
import 'package:tachi_books/features/sources/domain/catalogue.dart';
import 'package:tachi_books/features/sources/domain/native_source_engine.dart';
import 'package:tachi_books/features/sources/presentation/browse_screen.dart';

// Actual registry files and the native adapters are covered separately by
// empty_native_inventory_restore_test. Here keep IO outside the widget clock.
class _EmptyRuntime
    implements NativeSourceEngine, NativeInstalledExtensionInventory {
  int vmCalls = 0;
  @override
  Future<bool> hasInstalledExtensions() async => false;
  @override
  Future<List<CatalogueSource>> listSources() async {
    vmCalls++;
    throw StateError('An empty installation must not start a VM');
  }

  @override
  Future<List<CatalogueExtension>> extensions() async {
    vmCalls++;
    throw StateError('An empty installation must not start a VM');
  }

  @override
  void dispose() {}
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

void main() {
  testWidgets(
    'Browse renders an empty inventory and keeps extension controls usable without starting a VM',
    (tester) async {
      final tachi = _EmptyRuntime(), vbook = _EmptyRuntime();
      final repository = OnDeviceSourceRepository(
        tachimangaUrl: '',
        vbookUrl: '',
        runtimes: {SourceEngine.tachimanga: tachi, SourceEngine.vbook: vbook},
      );
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      try {
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              preferencesProvider.overrideWithValue(preferences),
              sourceRepositoryProvider.overrideWithValue(repository),
            ],
            child: MaterialApp(
              theme: ThemeData.dark(),
              home: const BrowseScreen(),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          find.text('Chưa có nguồn. Mở Tiện ích để cài extension.'),
          findsOneWidget,
        );
        expect(find.text('Mở Tiện ích'), findsOneWidget);
        expect(tachi.vmCalls, 0);
        expect(vbook.vmCalls, 0);
        expect(tester.takeException(), isNull);
        await tester.tap(find.text('Mở Tiện ích'));
        await tester.pumpAndSettle();
        expect(tachi.vmCalls, 0);
        expect(vbook.vmCalls, 0);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        repository.dispose();
      }
    },
  );
}
