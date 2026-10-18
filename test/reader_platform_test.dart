import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:tachi_books/core/platform/reader_platform.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('OCR region retains bytes and validates normalized coordinates before native call', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(ReaderPlatform.channel, (call) async {
      calls.add(call);
      return 'Chữ trong vùng';
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(ReaderPlatform.channel, null),
    );
    final bytes = Uint8List.fromList([4, 2, 7]);
    expect(
      await ReaderPlatform.recognizeText(
        bytes,
        region: const Rect.fromLTWH(.1, .2, .4, .5),
      ),
      'Chữ trong vùng',
    );
    expect(calls.single.method, 'recognizeTextRegion');
    final payload = calls.single.arguments as Map;
    expect(payload['bytes'], bytes);
    final region = payload['region'] as Map;
    expect(region['left'], closeTo(.1, 1e-12));
    expect(region['top'], closeTo(.2, 1e-12));
    expect(region['width'], closeTo(.4, 1e-12));
    expect(region['height'], closeTo(.5, 1e-12));
    for (final region in [
      Rect.zero,
      const Rect.fromLTWH(-.1, 0, .5, .5),
      const Rect.fromLTWH(0, 0, 1.1, 1),
      const Rect.fromLTWH(0, double.nan, 1, .5),
    ]) {
      await expectLater(
        ReaderPlatform.recognizeText(bytes, region: region),
        throwsArgumentError,
      );
    }
    expect(calls, hasLength(1));
    expect(bytes, [4, 2, 7]);
  });
  test('image native methods retain original bytes and forward OCR and permission errors', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(ReaderPlatform.channel, (call) async {
      calls.add(call);
      if (call.method == 'recognizeText') return 'Chữ nhận dạng';
      if (call.method == 'saveImage') {
        throw PlatformException(
          code: 'photos_denied',
          message: 'Chưa được phép lưu vào Ảnh.',
        );
      }
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(ReaderPlatform.channel, null),
    );
    final original = Uint8List.fromList([1, 4, 8, 16]);
    await ReaderPlatform.copyImage(original);
    await ReaderPlatform.shareImage(original);
    expect(await ReaderPlatform.recognizeText(original), 'Chữ nhận dạng');
    await expectLater(
      ReaderPlatform.saveImageToPhotos(original),
      throwsA(isA<PlatformException>()),
    );
    expect(calls.map((call) => call.method), [
      'copyImage',
      'shareImage',
      'recognizeText',
      'saveImage',
    ]);
    for (final call in calls) {
      expect(call.arguments, original);
    }
    expect(original, [1, 4, 8, 16]);
    await ReaderPlatform.translateText('Đoạn được chọn');
    expect(calls.last.method, 'translateText');
    expect(calls.last.arguments, 'Đoạn được chọn');
  });
}
