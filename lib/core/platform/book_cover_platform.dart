import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class BookCoverPlatform {
  static const channel = MethodChannel('dev.tachibooks/book-cover');
  static Future<Uint8List?> choosePhoto() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.iOS) {
      throw UnsupportedError('Chọn bìa từ Ảnh cần thiết bị iOS.');
    }
    return channel.invokeMethod<Uint8List>('choosePhoto');
  }

  static Future<void> shareLink(String value) async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.iOS) {
      throw UnsupportedError('Chia sẻ liên kết cần thiết bị iOS.');
    }
    await channel.invokeMethod<void>('shareLink', value);
  }
}
