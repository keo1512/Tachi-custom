import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

enum GoogleAccountAction { profile, password, recovery }

class SyncPlatform {
  static const channel = MethodChannel('dev.tachibooks/sync');
  static const events = EventChannel('dev.tachibooks/connectivity');
  static bool get supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;
  static Stream<bool> get connectivity => supported
      ? events
            .receiveBroadcastStream()
            .where((event) => event is bool)
            .cast<bool>()
      : const Stream.empty();
  static Future<void> openGoogleAccount({
    GoogleAccountAction action = GoogleAccountAction.profile,
  }) async {
    if (!supported) {
      throw UnsupportedError('Quản lý tài khoản cần thiết bị iOS.');
    }
    await channel.invokeMethod<void>(
      'openGoogleAccount',
      action == GoogleAccountAction.profile ? null : action.name,
    );
  }
}

final syncConnectivityProvider = Provider<Stream<bool>>(
  (ref) => SyncPlatform.connectivity,
);
