import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

abstract interface class DeviceTools {
  Future<Map<String, int>> usage();
  Future<void> clearWebData();
  Future<void> clearCookies();
  Future<void> clearHttpCache();
  Future<void> resetMutedDomains();
  Future<void> resetUserAgents();
  Future<void> shareLog(Uint8List bytes);
}

final deviceToolsProvider = Provider<DeviceTools>((_) => NativeDeviceTools());

class NativeDeviceTools implements DeviceTools {
  static const channel = MethodChannel('dev.tachibooks/device-tools');
  bool get supported => !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;
  Future<void> _call(String method, [Object? args]) async {
    if (!supported) {
      throw UnsupportedError('Công cụ thiết bị cần iPhone/iPad.');
    }
    await channel.invokeMethod<Object?>(method, args);
  }

  @override
  Future<Map<String, int>> usage() async {
    if (!supported) return const {};
    final value = await channel.invokeMapMethod<String, dynamic>('usage');
    if (value == null || value.values.any((v) => v is! int || v < 0)) {
      throw const FormatException(
        'Không đọc được dung lượng dữ liệu trên thiết bị.',
      );
    }
    return value.cast<String, int>();
  }

  @override
  Future<void> clearWebData() => _call('clearWebData');
  @override
  Future<void> clearCookies() => _call('clearCookies');
  @override
  Future<void> clearHttpCache() => _call('clearHttpCache');
  @override
  Future<void> resetMutedDomains() => _call('resetMutedDomains');
  @override
  Future<void> resetUserAgents() => _call('resetUserAgents');
  @override
  Future<void> shareLog(Uint8List bytes) {
    if (bytes.isEmpty || bytes.length > 128 * 1024) {
      throw const FormatException('Nhật ký trống hoặc vượt giới hạn 128 KiB.');
    }
    return _call('shareLog', bytes);
  }
}
