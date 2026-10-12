
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tachi_books/core/platform/reader_platform.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
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
