import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class ReaderPlatform {
  static const channel = MethodChannel('dev.tachibooks/reader');
  static bool get supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;
  static Future<void> keepAwake(bool value) async {
    if (supported) await channel.invokeMethod<void>('keepAwake', value);
  }

  static Future<void> copyImage(Uint8List bytes) async {
    if (!supported) throw UnsupportedError('Sao chép ảnh cần thiết bị iOS.');
    await channel.invokeMethod<void>('copyImage', bytes);
  }

  static Future<void> shareImage(Uint8List bytes) async {
    if (!supported) throw UnsupportedError('Chia sẻ ảnh cần thiết bị iOS.');
    await channel.invokeMethod<void>('shareImage', bytes);
  }

  static Future<void> saveImageToPhotos(Uint8List bytes) async {
    if (!supported) throw UnsupportedError('Lưu vào Ảnh cần thiết bị iOS.');
    await channel.invokeMethod<void>('saveImage', bytes);
  }

  static Future<String> recognizeText(Uint8List bytes, {Rect? region}) async {
    if (!supported) throw UnsupportedError('Nhận dạng chữ cần thiết bị iOS.');
    if (region != null) {
      if (!region.isFinite ||
          region.isEmpty ||
          region.left < 0 ||
          region.top < 0 ||
          region.right > 1 ||
          region.bottom > 1) {
        throw ArgumentError.value(
          region,
          'region',
          'Vùng ảnh phải nằm trong khoảng 0–1.',
        );
      }
      return await channel.invokeMethod<String>('recognizeTextRegion', {
            'bytes': bytes,
            'region': {
              'left': region.left,
              'top': region.top,
              'width': region.width,
              'height': region.height,
            },
          }) ??
          '';
    }
    return await channel.invokeMethod<String>('recognizeText', bytes) ?? '';
  }

  static Future<void> translateText(String text) async {
    if (!supported) throw UnsupportedError('Dịch văn bản cần thiết bị iOS.');
    await channel.invokeMethod<void>('translateText', text);
  }
}
