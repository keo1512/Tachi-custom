import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tachi_books/features/library/application/backup_service_provider.dart';
import 'package:tachi_books/features/library/data/backup_configuration.dart';
import 'package:tachi_books/features/library/data/coordinated_preferences.dart';
import 'package:tachi_books/features/library/data/library_repository.dart';
import 'package:tachi_books/features/library/data/library_snapshot.dart';
import 'package:tachi_books/features/library/presentation/library_view_model.dart';
import 'package:tachi_books/features/settings/settings_controller.dart';
import 'package:tachi_books/features/sources/data/extension_index.dart';
import 'package:tachi_books/features/sources/domain/catalogue.dart';
import 'package:tachi_books/features/sources/presentation/extension_catalogue_controller.dart';

http.Response registry(String name) => http.Response(
  jsonEncode({
    'data': [
      {
        'name': name,
        'path': 'plugin.zip',
        'version': 1,
        'icon': 'icons/plugin.png',
      },
    ],
  }),
  200,
);

Future<ProviderContainer> mount(
  MockClient client, {
  Map<String, Object>? saved,
}) async {
  SharedPreferences.setMockInitialValues(saved ?? {});
  final prefs = await SharedPreferences.getInstance();
  return ProviderContainer(
    overrides: [
      preferencesProvider.overrideWithValue(prefs),
      extensionIndexRepositoryProvider.overrideWithValue(
        ExtensionIndexRepository(client),
      ),
    ],
  );
}

String _repositories(String host) => jsonEncode([
  {'url': 'https://$host/plugin.json', 'engine': 'vbook'},
]);

Future<void> _restoreRepositories(
  ProviderContainer container,
  LibraryRepository repository,
  CoordinatedPreferences preferences,
  String host,
) async {
  final before = LibrarySnapshot(
    (await repository.snapshot()).entries,
    configuration: BackupConfiguration.capture(preferences),
  );
  final incoming = LibrarySnapshot(
    before.entries,
    configuration: BackupConfiguration.fromJson({
      'version': 1,
      'preferences': {
        ExtensionCatalogueController.preferenceKey: _repositories(host),
      },
    }),
  );
  // Use the production service and its controller invalidation callback.
  await container
      .read(backupServiceProvider)
      .replace(incoming.encode(), expectedFingerprint: before.fingerprint);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final action in ['add', 'rename', 'remove', 'refresh']) {
    for (final httpFailure in [false, true]) {
      test(
        'restore rejects pending $action after delayed HTTP ${httpFailure ? 'error' : 'success'}',
        () async {
          SharedPreferences.setMockInitialValues({
            ExtensionCatalogueController.preferenceKey: _repositories(
              'old.test',
            ),
          });
          final repository = MemoryLibraryRepository();
          final preferences = await CoordinatedPreferences.open(
            await SharedPreferences.getInstance(),
            repository,
          );
          final entered = Completer<void>(),
              response = Completer<http.Response>();
          // Rename/remove can await the initial catalogue fetch. Refresh waits
          // for its next fetch; add waits for the newly requested repository.
          var hold = action == 'rename' || action == 'remove';
          final client = MockClient((request) async {
            if (hold &&
                (request.url.host == 'pending.test' ||
                    request.url.host == 'old.test')) {
              if (!entered.isCompleted) entered.complete();
              return response.future;
            }
            return registry(request.url.host);
          });
          addTearDown(client.close);
          final container = ProviderContainer(
            overrides: [
              preferencesProvider.overrideWithValue(preferences),
              libraryRepositoryProvider.overrideWithValue(repository),
              extensionIndexRepositoryProvider.overrideWithValue(
                ExtensionIndexRepository(client),
              ),
            ],
          );
          addTearDown(container.dispose);
          final subscription = container.listen(
            extensionCatalogueProvider,
            (_, _) {},
          );
          addTearDown(subscription.close);
          if (!hold) await container.read(extensionCatalogueProvider.future);
          hold = true;
          final controller = container.read(
            extensionCatalogueProvider.notifier,
          );
          final work = switch (action) {
            'add' => controller.add(
              SourceEngine.vbook,
              'https://pending.test/plugin.json',
              isCurrent: () => true,
            ),
            'rename' => controller.rename(
              'vbook:https://old.test/plugin.json',
              'Old edit',
            ),
            'remove' => controller.remove('vbook:https://old.test/plugin.json'),
            _ => controller.refresh(),
          };
          final rejected = expectLater(work, throwsFormatException);
          await entered.future;
          await _restoreRepositories(
            container,
            repository,
            preferences,
            'restored.test',
          );
          final restored = preferences.getString(
            ExtensionCatalogueController.preferenceKey,
          );
          await container.read(extensionCatalogueProvider.future);
          response.complete(
            httpFailure
                ? http.Response('Unavailable', 503)
                : registry('Old response'),
          );
          await rejected;
          expect(
            preferences.getString(ExtensionCatalogueController.preferenceKey),
            restored,
          );
          expect(
            (await container.read(extensionCatalogueProvider.future))
                .map((item) => item.url),
            ['https://restored.test/plugin.json'],
          );
          expect((await repository.list()), isEmpty);
        },
      );
    }
  }

  test('restore invalidates edits already queued behind a pending add, then permits fresh edits', () async {
    SharedPreferences.setMockInitialValues({
      ExtensionCatalogueController.preferenceKey: _repositories('old.test'),
    });
    final repository = MemoryLibraryRepository();
    final preferences = await CoordinatedPreferences.open(
      await SharedPreferences.getInstance(),
      repository,
    );
    final entered = Completer<void>(), response = Completer<http.Response>();
    final client = MockClient((request) async {
      if (request.url.host == 'pending.test') {
        entered.complete();
        return response.future;
      }
      return registry(request.url.host);
    });
    addTearDown(client.close);
    final container = ProviderContainer(
      overrides: [
        preferencesProvider.overrideWithValue(preferences),
        libraryRepositoryProvider.overrideWithValue(repository),
        extensionIndexRepositoryProvider.overrideWithValue(
          ExtensionIndexRepository(client),
        ),
      ],
    );
    addTearDown(container.dispose);
    final subscription = container.listen(
      extensionCatalogueProvider,
      (_, _) {},
    );
    addTearDown(subscription.close);
    await container.read(extensionCatalogueProvider.future);
    final controller = container.read(extensionCatalogueProvider.notifier);
    final first = expectLater(
      controller.add(SourceEngine.vbook, 'https://pending.test/plugin.json'),
      throwsFormatException,
    );
    await entered.future;
    final rename = expectLater(
      controller.rename('vbook:https://old.test/plugin.json', 'Stale'),
      throwsFormatException,
    );
    final remove = expectLater(
      controller.remove('vbook:https://restored.test/plugin.json'),
      throwsFormatException,
    );
    final refresh = expectLater(controller.refresh(), throwsFormatException);
    await _restoreRepositories(
      container,
      repository,
      preferences,
      'restored.test',
    );
    await container.read(extensionCatalogueProvider.future);
    response.complete(registry('Late'));
    await Future.wait([first, rename, remove, refresh]);
    expect(
      preferences.getString(ExtensionCatalogueController.preferenceKey),
      _repositories('restored.test'),
    );
    // The old queue settles normally; a later operation captures the new
    // generation and can persist in the same notifier without restarting it.
    await controller.add(SourceEngine.vbook, 'https://fresh.test/plugin.json');
    await controller.rename('vbook:https://fresh.test/plugin.json', 'Fresh');
    await controller.remove('vbook:https://restored.test/plugin.json');
    await controller.refresh();
    final saved = (await container.read(extensionCatalogueProvider.future))
        .single;
    expect(saved.url, 'https://fresh.test/plugin.json');
    expect(saved.label, 'Fresh');
  });
  test('custom repository name survives refresh, restart and clearing restores metadata name', () async {
    final client = MockClient(
      (_) async => http.Response(
        jsonEncode({
          'name': 'Tên kho gốc',
          'data': [
            {'name': 'A', 'path': 'plugin.zip', 'version': 1},
          ],
        }),
        200,
        headers: {'content-type': 'application/json; charset=utf-8'},
      ),
    );
    final container = await mount(client);
    addTearDown(container.dispose);
    final controller = container.read(extensionCatalogueProvider.notifier);
    await controller.add(SourceEngine.vbook, 'https://repo.test/plugin.json');
    await controller.rename(
      'vbook:https://repo.test/plugin.json',
      'Kho của tôi',
    );
    await controller.refresh();
    expect(
      container
          .read(extensionCatalogueProvider)
          .requireValue
          .single
          .displayName,
      'Kho của tôi',
    );
    final prefs = container.read(preferencesProvider);
    expect(
      (jsonDecode(
        prefs.getString('extensionRepositoriesV1')!,
      ) as List).single['name'],
      'Kho của tôi',
    );
    final restarted = ProviderContainer(
      overrides: [
        preferencesProvider.overrideWithValue(prefs),
        extensionIndexRepositoryProvider.overrideWithValue(
          ExtensionIndexRepository(client),
        ),
      ],
    );
    addTearDown(restarted.dispose);
    expect(
      (await restarted.read(extensionCatalogueProvider.future))
          .single
          .displayName,
      'Kho của tôi',
    );
    await restarted
        .read(extensionCatalogueProvider.notifier)
        .rename('vbook:https://repo.test/plugin.json', '');
    expect(
      restarted
          .read(extensionCatalogueProvider)
          .requireValue
          .single
          .displayName,
      'Tên kho gốc',
    );
    expect(
      (jsonDecode(prefs.getString('extensionRepositoriesV1')!) as List).single
          .containsKey('name'),
      isFalse,
    );
  });
  test(
    'overlapping add, add and remove preserve the final saved repository list',
    () async {
      final requested = Completer<void>(),
          download = Completer<http.Response>();
      final container = await mount(
        MockClient((request) async {
          if (request.url.host == 'a.test') {
            requested.complete();
            return download.future;
          }
          return registry('B');
        }),
      );
      addTearDown(container.dispose);
      await container.read(extensionCatalogueProvider.future);
      final controller = container.read(extensionCatalogueProvider.notifier);
      final first = controller.add(
        SourceEngine.vbook,
        'https://a.test/plugin.json',
      );
      await requested.future;
      final second = controller.add(
        SourceEngine.vbook,
        'https://b.test/plugin.json',
      );
      final remove = controller.remove('vbook:https://a.test/plugin.json');
      download.complete(registry('A'));
      await Future.wait([first, second, remove]);
      final current = await container.read(extensionCatalogueProvider.future);
      expect(current.single.url, 'https://b.test/plugin.json');
      final raw = container
          .read(preferencesProvider)
          .getString(ExtensionCatalogueController.preferenceKey)!;
      expect(jsonDecode(raw), [
        {'url': 'https://b.test/plugin.json', 'engine': 'vbook'},
      ]);
    },
  );

  test('repository URLs persist across a fresh controller and fetch a real catalogue', () async {
    final client = MockClient((_) async => registry('Reloaded'));
    final first = await mount(client);
    await first
        .read(extensionCatalogueProvider.notifier)
        .add(SourceEngine.vbook, 'https://repo.test/plugin.json');
    final prefs = first.read(preferencesProvider);
    first.dispose();
    final second = ProviderContainer(
      overrides: [
        preferencesProvider.overrideWithValue(prefs),
        extensionIndexRepositoryProvider.overrideWithValue(
          ExtensionIndexRepository(client),
        ),
      ],
    );
    addTearDown(second.dispose);
    final loaded = await second.read(extensionCatalogueProvider.future);
    expect(loaded.single.entries.single.name, 'Reloaded');
    expect(loaded.single.entries.single.installed, false);
    expect(
      loaded.single.entries.single.iconUrl,
      'https://repo.test/icons/plugin.png',
    );
  });

  test(
    'one failed refresh keeps that catalogue and the other repository updates',
    () async {
      var refreshing = false;
      final container = await mount(
        MockClient((request) async {
          if (refreshing && request.url.host == 'a.test') {
            return http.Response('failure', 503);
          }
          return registry(
            '${request.url.host}${refreshing ? " updated" : " original"}',
          );
        }),
      );
      addTearDown(container.dispose);
      final controller = container.read(extensionCatalogueProvider.notifier);
      await controller.add(SourceEngine.vbook, 'https://a.test/plugin.json');
      await controller.add(SourceEngine.vbook, 'https://b.test/plugin.json');
      final before = container
          .read(preferencesProvider)
          .getString(ExtensionCatalogueController.preferenceKey);
      refreshing = true;
      await controller.refresh();
      final loaded = await container.read(extensionCatalogueProvider.future);
      expect(loaded.first.error, contains('503'));
      expect(loaded.first.entries.single.name, 'a.test original');
      expect(
        loaded.first.entries.single.iconUrl,
        'https://a.test/icons/plugin.png',
      );
      expect(loaded.last.entries.single.name, 'b.test updated');
      expect(
        loaded.last.entries.single.iconUrl,
        'https://b.test/icons/plugin.png',
      );
      expect(loaded.last.error, isEmpty);
      expect(
        container
            .read(preferencesProvider)
            .getString(ExtensionCatalogueController.preferenceKey),
        before,
      );
    },
  );

  test('failed addition does not erase saved URLs or block the next queued addition', () async {
    final container = await mount(
      MockClient(
        (request) async => request.url.host == 'bad.test'
            ? http.Response('failure', 404)
            : registry('Good'),
      ),
    );
    addTearDown(container.dispose);
    final controller = container.read(extensionCatalogueProvider.notifier);
    await expectLater(
      controller.add(SourceEngine.vbook, 'https://bad.test/plugin.json'),
      throwsFormatException,
    );
    await controller.add(SourceEngine.vbook, 'https://good.test/plugin.json');
    expect(
      (await container.read(extensionCatalogueProvider.future))
          .single
          .entries
          .single
          .name,
      'Good',
    );
  });

  test('malformed saved repository preferences are preserved before any HTTP request', () async {
    const raw =
        '[{"url":"https://valid.test/plugin.json","engine":"vbook"},{"url":"https://invalid.test/plugin.json","engine":"unknown"}]';
    var requests = 0;
    final container = await mount(
      MockClient((_) async {
        requests++;
        return registry('Never requested');
      }),
      saved: {ExtensionCatalogueController.preferenceKey: raw},
    );
    addTearDown(container.dispose);
    await expectLater(
      container.read(extensionCatalogueProvider.future),
      throwsFormatException,
    );
    expect(requests, 0);
    expect(
      container
          .read(preferencesProvider)
          .getString(ExtensionCatalogueController.preferenceKey),
      raw,
    );
  });
}
