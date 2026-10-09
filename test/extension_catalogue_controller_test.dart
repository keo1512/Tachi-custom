import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tachi_books/features/settings/settings_controller.dart';
import 'package:tachi_books/features/sources/data/extension_index.dart';
import 'package:tachi_books/features/sources/domain/catalogue.dart';
import 'package:tachi_books/features/sources/presentation/extension_catalogue_controller.dart';

http.Response registry(String name) => http.Response(
  jsonEncode({
    'data': [
      {'name': name, 'path': 'plugin.zip', 'version': 1},
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
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
      expect(loaded.last.entries.single.name, 'b.test updated');
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
