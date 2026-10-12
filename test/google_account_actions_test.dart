import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tachi_books/features/sync/data/sync_platform.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'Google account actions send allowlisted tokens instead of arbitrary URLs',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final calls = <MethodCall>[];
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(SyncPlatform.channel, (call) async {
        calls.add(call);
        return null;
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(SyncPlatform.channel, null),
      );
      for (final action in GoogleAccountAction.values) {
        await SyncPlatform.openGoogleAccount(action: action);
      }
      expect(calls.map((call) => call.method).toSet(), {'openGoogleAccount'});
      expect(calls.map((call) => call.arguments), [
        null,
        'password',
        'recovery',
      ]);
    },
  );
}
