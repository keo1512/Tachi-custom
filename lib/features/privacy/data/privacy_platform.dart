import 'package:flutter/services.dart';

import '../domain/privacy_preferences.dart';

abstract class PrivacyPlatform {
  Future<PrivacyCapabilities> capabilities();
  Future<bool> authenticate();
  Future<void> cancel();
  Future<void> configure(
    PrivacyPreferences preferences, {
    required bool incognito,
  });
  Future<void> foregroundReady();
}

class NativePrivacyPlatform implements PrivacyPlatform {
  static const channel = MethodChannel('dev.tachibooks/privacy');

  @override
  Future<PrivacyCapabilities> capabilities() async {
    final json = await channel.invokeMapMethod<String, dynamic>('capabilities');
    if (json == null || json['available'] is! bool) {
      throw StateError('iOS chưa xác nhận khả năng mở khóa.');
    }
    return PrivacyCapabilities(
      available: json['available'] as bool,
      biometry: json['biometry'] as String? ?? 'none',
    );
  }

  @override
  Future<bool> authenticate() async =>
      await channel.invokeMethod<bool>('authenticate') == true;

  @override
  Future<void> cancel() => channel.invokeMethod<void>('cancel');

  @override
  Future<void> configure(
    PrivacyPreferences preferences, {
    required bool incognito,
  }) => channel.invokeMethod<void>('configure', {
    ...preferences.toJson(),
    'incognito': incognito,
  });

  @override
  Future<void> foregroundReady() =>
      channel.invokeMethod<void>('foregroundReady');
}
