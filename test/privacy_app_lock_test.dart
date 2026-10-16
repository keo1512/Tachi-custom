import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tachi_books/features/privacy/application/app_lock_controller.dart';
import 'package:tachi_books/features/privacy/data/privacy_platform.dart';
import 'package:tachi_books/features/privacy/domain/privacy_preferences.dart';
import 'package:tachi_books/features/privacy/presentation/privacy_gate.dart';
import 'package:tachi_books/features/settings/presentation/app_settings_screens.dart';
import 'package:tachi_books/features/settings/settings_controller.dart';

class FakePrivacyPlatform implements PrivacyPlatform {
  bool answer = true;
  bool available = true;
  int attempts = 0, canceled = 0, ready = 0;
  Completer<bool>? deferred;
  PrivacyPreferences? configured;
  bool? configuredIncognito;
  @override
  Future<PrivacyCapabilities> capabilities() async =>
      PrivacyCapabilities(available: available, biometry: 'faceID');
  @override
  Future<bool> authenticate() {
    attempts++;
    if (!available) throw PlatformException(code: 'unavailable');
    return deferred?.future ?? Future.value(answer);
  }

  @override
  Future<void> cancel() async {
    canceled++;
  }

  @override
  Future<void> configure(
    PrivacyPreferences preferences, {
    required bool incognito,
  }) async {
    configured = preferences;
    configuredIncognito = incognito;
  }

  @override
  Future<void> foregroundReady() async {
    ready++;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<(ProviderContainer, FakePrivacyPlatform)> fixture({
    PrivacyPreferences preferences = const PrivacyPreferences(),
    Duration timeout = const Duration(seconds: 90),
    DateTime Function()? clock,
  }) async {
    final storage = await SharedPreferences.getInstance();
    await storage.setString(
      AppLockController.preferenceKey,
      jsonEncode(preferences.toJson()),
    );
    final platform = FakePrivacyPlatform();
    final container = ProviderContainer(
      overrides: [
        preferencesProvider.overrideWithValue(storage),
        privacyPlatformProvider.overrideWithValue(platform),
        privacyAuthTimeoutProvider.overrideWithValue(timeout),
        if (clock != null) privacyClockProvider.overrideWithValue(clock),
      ],
    );
    addTearDown(container.dispose);
    final subscription = container.listen(appLockProvider, (_, _) {});
    addTearDown(subscription.close);
    await container.read(appLockProvider.notifier).initialize();
    return (container, platform);
  }

  test('disabled default never requests authentication, secret is never in preferences', () async {
    final (container, platform) = await fixture();
    expect(container.read(appLockProvider).locked, isFalse);
    expect(platform.attempts, 0);
    container
        .read(appLockProvider.notifier)
        .lifecycle(AppLifecycleState.paused);
    expect(container.read(appLockProvider).locked, isFalse);
    expect(container.read(appLockProvider).obscured, isFalse);
    final storage = await SharedPreferences.getInstance();
    expect(jsonDecode(storage.getString(AppLockController.preferenceKey)!), {
      'enabled': false,
      'delaySeconds': 0,
      'secureScreen': 'incognito',
    });
  });

  test('enabling and disabling require successful device authentication and persist for restart', () async {
    final (container, platform) = await fixture();
    final controller = container.read(appLockProvider.notifier);
    platform.answer = false;
    await controller.update(enabled: true);
    expect(container.read(appLockProvider).preferences.enabled, isFalse);
    platform.answer = true;
    await controller.update(enabled: true);
    expect(container.read(appLockProvider).preferences.enabled, isTrue);
    expect(container.read(appLockProvider).locked, isFalse);
    container.invalidate(appLockProvider);
    expect(container.read(appLockProvider).locked, isTrue);
    platform.answer = false;
    await container.read(appLockProvider.notifier).update(enabled: false);
    expect(container.read(appLockProvider).preferences.enabled, isTrue);
    platform.answer = true;
    await container.read(appLockProvider.notifier).update(enabled: false);
    expect(container.read(appLockProvider).locked, isFalse);
    expect(container.read(appLockProvider).preferences.enabled, isFalse);
  });

  test(
    'foreground idle locks after actual inactivity and input never unlocks',
    () async {
      var now = DateTime.utc(2026, 10, 11);
      final (container, _) = await fixture(
        preferences: const PrivacyPreferences(enabled: true, idleSeconds: 60),
        clock: () => now,
      );
      final controller = container.read(appLockProvider.notifier);
      expect(await controller.unlock(), true);
      now = now.add(const Duration(seconds: 50));
      controller.recordActivity();
      now = now.add(const Duration(seconds: 50));
      controller.checkIdle();
      expect(container.read(appLockProvider).locked, false);
      now = now.add(const Duration(seconds: 11));
      controller.checkIdle();
      expect(container.read(appLockProvider).locked, true);
      controller.recordActivity();
      expect(container.read(appLockProvider).locked, true);
      expect(await controller.unlock(), true);
      controller.lifecycle(AppLifecycleState.paused);
      now = now.add(const Duration(minutes: 10));
      controller.checkIdle();
      expect(container.read(appLockProvider).obscured, true);
      controller.lifecycle(AppLifecycleState.resumed);
      expect(container.read(appLockProvider).locked, true);
      expect(PrivacyPreferences.fromJson({'enabled': true}).idleSeconds, 0);
      expect(
        () => PrivacyPreferences.fromJson({'idleSeconds': -1}),
        throwsFormatException,
      );
    },
  );

  test('turning off idle timeout stays off after restart and preserves unknown fields', () async {
    final (container, _) = await fixture(
      preferences: const PrivacyPreferences(enabled: true, idleSeconds: 300),
    );
    final storage = await SharedPreferences.getInstance();
    final raw = jsonDecode(
      storage.getString(AppLockController.preferenceKey)!,
    ) as Map<String, dynamic>;
    await storage.setString(
      AppLockController.preferenceKey,
      jsonEncode({...raw, 'futurePolicy': 'keep'}),
    );
    await container.read(appLockProvider.notifier).unlock();
    await container.read(appLockProvider.notifier).update(idleSeconds: 0);
    container.invalidate(appLockProvider);
    expect(container.read(appLockProvider).preferences.idleSeconds, 0);
    final saved = jsonDecode(
      storage.getString(AppLockController.preferenceKey)!,
    ) as Map<String, dynamic>;
    expect(saved.containsKey('idleSeconds'), false);
    expect(saved['futurePolicy'], 'keep');
  });

  test('device lacking a passcode remains unlocked before enabling and shows actionable error', () async {
    final (container, platform) = await fixture();
    platform.available = false;
    await container.read(appLockProvider.notifier).update(enabled: true);
    expect(container.read(appLockProvider).preferences.enabled, isFalse);
    expect(container.read(appLockProvider).error, contains('Cài đặt'));
  });

  test(
    'authentication timeout stays locked; late native success cannot unlock it',
    () async {
      final (container, platform) = await fixture(
        preferences: const PrivacyPreferences(enabled: true),
        timeout: const Duration(milliseconds: 10),
      );
      platform.deferred = Completer<bool>();
      expect(await container.read(appLockProvider.notifier).unlock(), isFalse);
      expect(container.read(appLockProvider).locked, isTrue);
      expect(container.read(appLockProvider).authenticating, isFalse);
      expect(container.read(appLockProvider).error, contains('quá lâu'));
      expect(platform.canceled, greaterThanOrEqualTo(1));
      platform.deferred!.complete(true);
      await container.pump();
      expect(container.read(appLockProvider).locked, isTrue);
      platform.deferred = null;
      expect(await container.read(appLockProvider.notifier).unlock(), isTrue);
    },
  );

  test('three failures throttle immediate retries and a later success clears errors', () async {
    var now = DateTime.utc(2026);
    final (container, platform) = await fixture(
      preferences: const PrivacyPreferences(enabled: true),
      clock: () => now,
    );
    final controller = container.read(appLockProvider.notifier);
    platform.answer = false;
    for (var i = 0; i < 3; i++) {
      expect(await controller.unlock(), isFalse);
    }
    expect(
      container.read(appLockProvider).retryAfter,
      now.add(const Duration(seconds: 5)),
    );
    expect(await controller.unlock(), isFalse);
    expect(platform.attempts, 3);
    now = now.add(const Duration(seconds: 5));
    platform.answer = true;
    expect(await controller.unlock(), isTrue);
    expect(container.read(appLockProvider).retryAfter, isNull);
    expect(container.read(appLockProvider).error, isNull);
  });

  test('real background cancels pending authentication; prompt-only inactive does not', () async {
    final (container, platform) = await fixture(
      preferences: const PrivacyPreferences(enabled: true),
    );
    platform.deferred = Completer<bool>();
    final controller = container.read(appLockProvider.notifier);
    final pending = controller.unlock();
    controller.lifecycle(AppLifecycleState.inactive);
    expect(container.read(appLockProvider).authenticating, isTrue);
    controller.lifecycle(AppLifecycleState.paused);
    expect(container.read(appLockProvider).authenticating, isFalse);
    platform.deferred!.complete(true);
    expect(await pending, isFalse);
    controller.lifecycle(AppLifecycleState.resumed);
    expect(container.read(appLockProvider).locked, isTrue);
    platform.deferred = null;
    expect(await controller.unlock(), isTrue);
  });

  test(
    'delay compares elapsed time on resume; backward clock fails closed',
    () async {
      var now = DateTime.utc(2026);
      final (container, _) = await fixture(
        preferences: const PrivacyPreferences(enabled: true, delaySeconds: 30),
        clock: () => now,
      );
      final controller = container.read(appLockProvider.notifier);
      await controller.unlock();
      controller.lifecycle(AppLifecycleState.inactive);
      expect(container.read(appLockProvider).obscured, isTrue);
      now = now.add(const Duration(seconds: 29));
      controller.lifecycle(AppLifecycleState.resumed);
      expect(container.read(appLockProvider).locked, isFalse);
      controller.lifecycle(AppLifecycleState.paused);
      now = now.add(const Duration(seconds: 30));
      controller.lifecycle(AppLifecycleState.resumed);
      expect(container.read(appLockProvider).locked, isTrue);
      await controller.unlock();
      controller.lifecycle(AppLifecycleState.paused);
      now = now.subtract(const Duration(seconds: 1));
      controller.lifecycle(AppLifecycleState.resumed);
      expect(container.read(appLockProvider).locked, isTrue);
    },
  );

  test(
    'independent screen protection follows always/incognito/off policies',
    () async {
      final (container, platform) = await fixture();
      final controller = container.read(appLockProvider.notifier);
      await controller.update(secureScreen: SecureScreenMode.always);
      controller.lifecycle(AppLifecycleState.paused);
      expect(container.read(appLockProvider).obscured, isTrue);
      controller.lifecycle(AppLifecycleState.resumed);
      await controller.update(secureScreen: SecureScreenMode.incognito);
      await container
          .read(settingsProvider.notifier)
          .update(incognitoMode: true);
      await container.pump();
      expect(platform.configuredIncognito, isTrue);
      controller.lifecycle(AppLifecycleState.inactive);
      expect(container.read(appLockProvider).obscured, isTrue);
      controller.lifecycle(AppLifecycleState.resumed);
      await controller.update(secureScreen: SecureScreenMode.off);
      controller.lifecycle(AppLifecycleState.paused);
      expect(container.read(appLockProvider).obscured, isFalse);
    },
  );

  test('restored/reloaded policy rejects an authentication result from the old generation', () async {
    final (container, platform) = await fixture(
      preferences: const PrivacyPreferences(enabled: true),
    );
    platform.deferred = Completer<bool>();
    final pending = container.read(appLockProvider.notifier).unlock();
    container.invalidate(appLockProvider);
    expect(container.read(appLockProvider).locked, isTrue);
    platform.deferred!.complete(true);
    expect(await pending, isFalse);
    expect(container.read(appLockProvider).locked, isTrue);
  });

  test('unknown policy fields survive updates, corrupt input is preserved and cannot be unlocked', () async {
    final (container, platform) = await fixture();
    final storage = await SharedPreferences.getInstance();
    await storage.setString(
      AppLockController.preferenceKey,
      jsonEncode({
        'enabled': false,
        'future': {'keep': true},
      }),
    );
    container.invalidate(appLockProvider);
    await container.read(appLockProvider.notifier).update(delaySeconds: 60);
    expect(
      (jsonDecode(storage.getString(AppLockController.preferenceKey)!)
          as Map)['future'],
      {'keep': true},
    );
    await storage.setString(
      AppLockController.preferenceKey,
      '{invalid original',
    );
    container.invalidate(appLockProvider);
    final attempts = platform.attempts;
    expect(await container.read(appLockProvider.notifier).unlock(), isFalse);
    expect(platform.attempts, attempts);
    await expectLater(
      container.read(appLockProvider.notifier).update(enabled: false),
      throwsFormatException,
    );
    expect(
      storage.getString(AppLockController.preferenceKey),
      '{invalid original',
    );
    expect(container.read(appLockProvider).locked, isTrue);
  });

  for (final width in [320.0, 430.0]) {
    testWidgets(
      'privacy settings expose incognito for new reader sessions at $width',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = Size(width, 568);
        addTearDown(tester.view.reset);
        final storage = await SharedPreferences.getInstance();
        final platform = FakePrivacyPlatform();
        final container = ProviderContainer(
          overrides: [
            preferencesProvider.overrideWithValue(storage),
            privacyPlatformProvider.overrideWithValue(platform),
          ],
        );
        addTearDown(container.dispose);
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(textScaler: const TextScaler.linear(1.5)),
                child: child!,
              ),
              home: const PrivacySettingsScreen(),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final toggle = find.byKey(const ValueKey('privacy-incognito'));
        expect(tester.widget<CupertinoSwitch>(toggle).value, false);
        await tester.tap(toggle);
        await tester.pumpAndSettle();
        expect(container.read(settingsProvider).incognitoMode, true);
        expect(storage.getBool('incognitoMode'), true);
        expect(platform.configuredIncognito, true);
        expect(
          find.textContaining('Áp dụng cho phiên đọc mở mới'),
          findsOneWidget,
        );
        await tester.tap(toggle);
        await tester.pumpAndSettle();
        expect(container.read(settingsProvider).incognitoMode, false);
        expect(platform.configuredIncognito, false);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'privacy gate blocks content until authenticating and settings fit at $width',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = Size(width, 932);
        addTearDown(tester.view.reset);
        final storage = await SharedPreferences.getInstance();
        await storage.setString(
          AppLockController.preferenceKey,
          jsonEncode(const PrivacyPreferences(enabled: true).toJson()),
        );
        final platform = FakePrivacyPlatform();
        var taps = 0;
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              preferencesProvider.overrideWithValue(storage),
              privacyPlatformProvider.overrideWithValue(platform),
            ],
            child: MaterialApp(
              home: PrivacyGate(
                child: Scaffold(
                  body: Center(
                    child: TextButton(
                      onPressed: () {
                        taps++;
                      },
                      child: const Text('Private title'),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('TachiBooks đã khóa'), findsOneWidget);
        await tester.tap(find.text('Private title'), warnIfMissed: false);
        expect(taps, 0);
        await tester.tap(find.byKey(const ValueKey('privacy-unlock')));
        await tester.pumpAndSettle();
        expect(find.text('TachiBooks đã khóa'), findsNothing);
        await tester.tap(find.text('Private title'));
        expect(taps, 1);
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              preferencesProvider.overrideWithValue(storage),
              privacyPlatformProvider.overrideWithValue(platform),
            ],
            child: const MaterialApp(home: PrivacySettingsScreen()),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('privacy-delay')), findsOneWidget);
        await tester.ensureVisible(
          find.byKey(const ValueKey('privacy-screen-mode')),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('privacy-screen-mode')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Luôn bảo vệ').last);
        await tester.pumpAndSettle();
        expect(platform.configured?.secureScreen, SecureScreenMode.always);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets(
    'landscape lock scrolls long errors and retry countdown without hiding unlock',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(568, 320);
      addTearDown(tester.view.reset);
      final storage = await SharedPreferences.getInstance();
      await storage.setString(
        AppLockController.preferenceKey,
        jsonEncode(const PrivacyPreferences(enabled: true).toJson()),
      );
      final platform = FakePrivacyPlatform()..answer = false;
      var now = DateTime(2026, 10, 16, 12);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            preferencesProvider.overrideWithValue(storage),
            privacyPlatformProvider.overrideWithValue(platform),
            privacyClockProvider.overrideWithValue(() => now),
          ],
          child: MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: const TextScaler.linear(1.5)),
              child: child!,
            ),
            home: const PrivacyGate(
              child: Scaffold(body: Text('Nội dung riêng tư')),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final unlock = find.byKey(const ValueKey('privacy-unlock'));
      for (var attempt = 0; attempt < 3; attempt++) {
        await tester.ensureVisible(unlock);
        await tester.tap(unlock);
        await tester.pumpAndSettle();
      }
      expect(find.textContaining('Thử lại sau'), findsOneWidget);
      expect(tester.takeException(), isNull);
      now = now.add(const Duration(seconds: 6));
      await tester.pump(const Duration(seconds: 6));
      await tester.ensureVisible(unlock);
      expect(find.text('Mở khóa'), findsOneWidget);
      platform.answer = true;
      await tester.tap(unlock);
      await tester.pumpAndSettle();
      expect(find.text('TachiBooks đã khóa'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
