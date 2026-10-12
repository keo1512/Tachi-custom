import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tachi_books/features/reader/presentation/reader_system_ui.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final calls = <MethodCall>[];
  setUp(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          calls.add(call);
          return null;
        });
  });
  tearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null),
  );

  test('reader overlay lease applies options and restores on exit', () async {
    final lease = ReaderSystemUiLease();
    await lease.apply(fullScreen: true, hideStatusBar: false);
    expect(calls.last.arguments, isEmpty);
    await lease.apply(fullScreen: false, hideStatusBar: true);
    expect(calls.last.arguments, ['SystemUiOverlay.bottom']);
    final count = calls.length;
    await lease.apply(fullScreen: false, hideStatusBar: true);
    expect(calls.length, count);
    await lease.release();
    expect(calls.last.arguments, [
      'SystemUiOverlay.top',
      'SystemUiOverlay.bottom',
    ]);
  });

  test(
    'queued apply or release from previous reader cannot overwrite next reader',
    () async {
      final old = ReaderSystemUiLease(), current = ReaderSystemUiLease();
      await old.apply(fullScreen: false, hideStatusBar: false);
      calls.clear();
      final pending = old.apply(fullScreen: true, hideStatusBar: true);
      final release = old.release();
      final next = current.apply(fullScreen: false, hideStatusBar: true);
      await Future.wait([pending, release, next]);
      expect(calls.map((call) => call.arguments).toList(), [
        ['SystemUiOverlay.bottom'],
      ]);
      await old.release();
      expect(calls.length, 1);
      await current.release();
      expect(calls.last.arguments, [
        'SystemUiOverlay.top',
        'SystemUiOverlay.bottom',
      ]);
    },
  );
}
