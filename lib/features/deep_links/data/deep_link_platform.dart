import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

abstract interface class DeepLinkPlatform {
  Stream<String> get links;
  Future<List<String>> ready();
  void dispose();
}

final deepLinkPlatformProvider = Provider<DeepLinkPlatform>((ref) {
  final platform = NativeDeepLinkPlatform();
  ref.onDispose(platform.dispose);
  return platform;
});

class NativeDeepLinkPlatform implements DeepLinkPlatform {
  NativeDeepLinkPlatform() {
    if (_available) {
      _channel.setMethodCallHandler((call) async {
        if (call.method == 'openURL' &&
            call.arguments is String &&
            !_disposed) {
          _links.add(call.arguments as String);
        }
      });
    }
  }
  static const _channel = MethodChannel('dev.tachibooks/deepLinks');
  bool get _available => !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;
  final _links = StreamController<String>.broadcast(sync: true);
  bool _disposed = false;
  @override
  Stream<String> get links => _links.stream;
  @override
  Future<List<String>> ready() async {
    if (!_available || _disposed) return [];
    final result = await _channel.invokeListMethod<Object?>('ready');
    return result?.whereType<String>().toList() ?? [];
  }

  @override
  void dispose() {
    _disposed = true;
    if (_available) _channel.setMethodCallHandler(null);
    unawaited(_links.close());
  }
}
