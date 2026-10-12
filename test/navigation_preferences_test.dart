import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tachi_books/core/platform/native_tabs.dart';
import 'package:tachi_books/features/library/data/coordinated_preferences.dart';
import 'package:tachi_books/features/library/data/library_repository.dart';
import 'package:tachi_books/features/settings/navigation_preferences.dart';
import 'package:tachi_books/features/settings/settings_controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('legacy order and malformed persisted route IDs never change default routes', () {
    expect(NavigationPreferences.decode(null).order, [0, 1, 2, 3, 4, 5]);
    for (final order in [
      [0, 1, 2, 3, 4, 4],
      [0, 1, 2],
      [0, 1, 2, 3, 4, 6],
    ]) {
      expect(
        () => NavigationPreferences.decode(jsonEncode({'order': order})),
        throwsFormatException,
      );
    }
  });
  test('saved tab order, hidden labels and startup route survive restart; stale screen is rejected', () async {
    SharedPreferences.setMockInitialValues({});
    final raw = await SharedPreferences.getInstance();
    final preferences = await CoordinatedPreferences.open(
      raw,
      MemoryLibraryRepository(),
    );
    final container = ProviderContainer(
      overrides: [preferencesProvider.overrideWithValue(preferences)],
    );
    addTearDown(container.dispose);
    final controller = container.read(navigationPreferencesProvider.notifier);
    await controller.save(
      const NavigationPreferences(
        order: [5, 2, 0, 4, 3, 1],
        start: 3,
        showLabels: false,
        rememberSelected: true,
      ),
    );
    await controller.recordSelection('/history');
    final restarted = ProviderContainer(
      overrides: [preferencesProvider.overrideWithValue(preferences)],
    );
    addTearDown(restarted.dispose);
    expect(restarted.read(navigationPreferencesProvider).order, [
      5,
      2,
      0,
      4,
      3,
      1,
    ]);
    expect(restarted.read(navigationPreferencesProvider).showLabels, false);
    expect(
      restarted.read(navigationPreferencesProvider.notifier).startRoute,
      '/history',
    );
    await expectLater(
      controller.save(const NavigationPreferences(), expectedGeneration: -1),
      throwsStateError,
    );
    expect(restarted.read(navigationPreferencesProvider).order.first, 5);
  });
  test('UIKit slots map back to unchanged route identities and privacy still blocks callbacks', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(NativeTabs.channel, (call) async {
      calls.add(call);
      return true;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(NativeTabs.channel, null),
    );
    final selected = <int>[];
    final tabs = NativeTabs(onSelect: selected.add)
      ..rootRoute = 'main-shell'
      ..shellRoute = 'library';
    addTearDown(tabs.dispose);
    tabs.initialize();
    const order = [5, 2, 0, 4, 3, 1];
    tabs.update(path: '/', dark: true, order: order, showLabels: false);
    await Future<void>.delayed(Duration.zero);
    expect((calls.last.arguments as Map)['index'], 2);
    expect((calls.last.arguments as Map)['order'], order);
    expect((calls.last.arguments as Map)['titles'], List.filled(6, ''));
    Future<void> select(int index) => messenger.handlePlatformMessage(
      NativeTabs.channel.name,
      const StandardMethodCodec().encodeMethodCall(
        MethodCall('selectTab', {'index': index}),
      ),
      null,
    );
    await select(0);
    expect(selected, [5]);
    // A callback carries the identity painted by UIKit, including while Dart
    // is preparing a different order. Do not reinterpret its old slot.
    await messenger.handlePlatformMessage(
      NativeTabs.channel.name,
      const StandardMethodCodec().encodeMethodCall(
        const MethodCall('selectTab', {'index': 0, 'tabId': 3}),
      ),
      null,
    );
    expect(selected, [5, 3]);
    tabs.update(
      path: '/',
      dark: true,
      order: order,
      blocked: true,
      showLabels: false,
    );
    await Future<void>.delayed(Duration.zero);
    expect((calls.last.arguments as Map)['visible'], false);
    await select(1);
    expect(selected, [5, 3]);
    tabs.update(path: '/', dark: true, order: order, showLabels: false);
    await select(1);
    expect(selected, [5, 3, 2]);
  });
}
