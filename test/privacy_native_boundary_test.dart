import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tachi_books/features/privacy/data/privacy_platform.dart';
import 'package:tachi_books/features/privacy/domain/privacy_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(
    () =>
        messenger.setMockMethodCallHandler(NativePrivacyPlatform.channel, null),
  );

  test('privacy channel sends only nonsecret policy and checks real authentication result', () async {
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(NativePrivacyPlatform.channel, (
      call,
    ) async {
      calls.add(call);
      return switch (call.method) {
        'capabilities' => {'available': true, 'biometry': 'touchID'},
        'authenticate' => true,
        _ => null,
      };
    });
    final platform = NativePrivacyPlatform();
    expect((await platform.capabilities()).biometry, 'touchID');
    expect(await platform.authenticate(), isTrue);
    await platform.configure(
      const PrivacyPreferences(
        enabled: true,
        delaySeconds: 60,
        secureScreen: SecureScreenMode.always,
      ),
      incognito: false,
    );
    expect(calls.last.arguments, {
      'enabled': true,
      'delaySeconds': 60,
      'secureScreen': 'always',
      'incognito': false,
    });
    await platform.cancel();
    await platform.foregroundReady();
    expect(calls.map((call) => call.method), [
      'capabilities',
      'authenticate',
      'configure',
      'cancel',
      'foregroundReady',
    ]);
    expect(calls[1].arguments, isNull);
  });

  test('malformed native capability and nontrue authentication never imply success', () async {
    messenger.setMockMethodCallHandler(
      NativePrivacyPlatform.channel,
      (call) async =>
          call.method == 'capabilities' ? {'biometry': 'faceID'} : null,
    );
    final platform = NativePrivacyPlatform();
    await expectLater(platform.capabilities(), throwsStateError);
    expect(await platform.authenticate(), isFalse);
  });
}
