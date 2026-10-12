import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tachi_books/features/library/application/backup_service_provider.dart';
import 'package:tachi_books/features/library/application/extension_recovery_controller.dart';
import 'package:tachi_books/features/library/data/library_repository.dart';
import 'package:tachi_books/features/library/presentation/library_view_model.dart';
import 'package:tachi_books/features/privacy/application/app_lock_controller.dart';
import 'package:tachi_books/features/settings/settings_controller.dart';
import 'package:tachi_books/features/sources/application/native_runtime_provider.dart';
import 'package:tachi_books/features/sources/data/on_device_source_repository.dart';
import 'package:tachi_books/features/sources/domain/catalogue.dart';
import 'package:tachi_books/features/sources/domain/extension_backup.dart';
import 'package:tachi_books/features/sources/domain/native_source_engine.dart';

class _Unlocked extends AppLockController {
  @override
  AppLockState build() => const AppLockState(initialized: true);
  @override
  Future<void> initialize() async {}
}

class _Recovered extends ExtensionRecoveryController {
  @override
  Future<void> build() async {}
}

class _Runtime implements NativeSourceEngine, NativeExtensionBackupEngine {
  _Runtime(this.engine);
  final SourceEngine engine;
  int disposals = 0, captures = 0;

  void _checkAlive() {
    if (disposals != 0) throw StateError('Runtime client already closed.');
  }

  @override
  Future<Map<String, dynamic>> health() async {
    _checkAlive();
    return {'engine': engine.name};
  }

  @override
  Future<ExtensionBackup> captureExtensionBackup() async {
    _checkAlive();
    captures++;
    return ExtensionBackup([
      ExtensionBackupPackage.create(
        engine: engine,
        id: engine == SourceEngine.tachimanga
            ? 'eu.kanade.tachiyomi.extension.vi.fixture'
            : 'vb-0123456789abcdef01234567',
        name: engine.name,
        bytes: Uint8List.fromList([0x50, 0x4b, 3, 4]),
      ),
    ]);
  }

  @override
  Future<void> validateExtensionBackup(ExtensionBackup backup) async =>
      _checkAlive();
  @override
  Future<void> restoreExtensionBackup(ExtensionBackup backup) async =>
      _checkAlive();
  @override
  void dispose() => disposals++;
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final initiallyExternal in [false, true]) {
    test(
      'URL routing switches retain both backup runtimes; starts external=$initiallyExternal',
      () async {
        SharedPreferences.setMockInitialValues({
          if (initiallyExternal) 'tachimangaUrl': 'https://tachi.example',
          if (initiallyExternal) 'vbookUrl': 'https://vbook.example',
        });
        final preferences = await SharedPreferences.getInstance();
        final tachi = _Runtime(SourceEngine.tachimanga);
        final vbook = _Runtime(SourceEngine.vbook);
        var tachiConstructions = 0, vbookConstructions = 0;
        final container = ProviderContainer(
          overrides: [
            preferencesProvider.overrideWithValue(preferences),
            libraryRepositoryProvider.overrideWithValue(
              MemoryLibraryRepository(),
            ),
            appLockProvider.overrideWith(_Unlocked.new),
            extensionRecoveryProvider.overrideWith(_Recovered.new),
            nativeRuntimeFactoriesProvider.overrideWithValue({
              SourceEngine.tachimanga: () {
                tachiConstructions++;
                return tachi;
              },
              SourceEngine.vbook: () {
                vbookConstructions++;
                return vbook;
              },
            }),
          ],
        );
        var disposed = false;
        addTearDown(() {
          if (!disposed) container.dispose();
        });
        final backup = container.read(backupServiceProvider);
        final firstRoute = container.read(sourceRepositoryProvider);
        expect(
          firstRoute.requiresExternalConnection(SourceEngine.tachimanga),
          initiallyExternal,
        );

        Future<void> assertBothPackages() async {
          final value = jsonDecode(utf8.decode(await backup.export()));
          final packages = ExtensionBackup.fromJson(value['extensions']);
          expect(packages.packages.map((value) => value.engine).toSet(), {
            SourceEngine.tachimanga,
            SourceEngine.vbook,
          });
          expect(tachi.disposals, 0);
          expect(vbook.disposals, 0);
        }

        await assertBothPackages();
        await container
            .read(settingsProvider.notifier)
            .update(
              tachimangaUrl: 'https://next-tachi.example',
              vbookUrl: 'https://next-vbook.example',
            );
        final externalRoute = container.read(sourceRepositoryProvider);
        expect(externalRoute, isNot(same(firstRoute)));
        expect(
          externalRoute.requiresExternalConnection(SourceEngine.tachimanga),
          true,
        );
        expect(
          externalRoute.requiresExternalConnection(SourceEngine.vbook),
          true,
        );
        expect(container.read(backupServiceProvider), same(backup));
        await assertBothPackages();

        await container
            .read(settingsProvider.notifier)
            .update(tachimangaUrl: '', vbookUrl: '');
        final nativeRoute = container.read(sourceRepositoryProvider);
        expect(await nativeRoute.health(SourceEngine.tachimanga), {
          'engine': 'tachimanga',
        });
        expect(await nativeRoute.health(SourceEngine.vbook), {
          'engine': 'vbook',
        });
        await assertBothPackages();
        expect(tachiConstructions, 1);
        expect(vbookConstructions, 1);
        expect(tachi.captures, 3);
        expect(vbook.captures, 3);
        container.dispose();
        disposed = true;
        expect(tachi.disposals, 1);
        expect(vbook.disposals, 1);
      },
    );
  }

  test('standalone repository retains default ownership and disposes once', () {
    final runtime = _Runtime(SourceEngine.tachimanga);
    final repository = OnDeviceSourceRepository(
      tachimangaUrl: '',
      vbookUrl: '',
      runtimes: {SourceEngine.tachimanga: runtime},
    );
    repository.dispose();
    repository.dispose();
    expect(runtime.disposals, 1);
  });
}
