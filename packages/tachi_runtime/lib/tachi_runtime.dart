import 'package:flutter/services.dart';

class TachiRuntime {
  const TachiRuntime();

  static const channel = MethodChannel('dev.tachibooks/tachi_runtime');

  Future<Map<String, dynamic>> openBrowser(String url) async {
    final response = await channel.invokeMapMethod<String, dynamic>(
      'openBrowser',
      url,
    );
    if (response == null) {
      throw PlatformException(
        code: 'EMPTY_BROWSER_RESPONSE',
        message: 'Trang nguồn chưa trả phiên đăng nhập.',
      );
    }
    return response;
  }

  Future<String> invoke(String request) async {
    final response = await channel.invokeMethod<String>('invoke', request);
    if (response == null) {
      throw PlatformException(
        code: 'EMPTY_RUNTIME_RESPONSE',
        message: 'Engine không trả dữ liệu.',
      );
    }
    return response;
  }
}
