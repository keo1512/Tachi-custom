import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

const mainTabRoutes = [
  '/',
  '/updates',
  '/browse',
  '/downloads',
  '/history',
  '/more',
];
const mainTabNames = [
  'library',
  'updates',
  'browse',
  'downloads',
  'history',
  'more',
];
const mainTabLabels = [
  'Thư viện',
  'Cập nhật',
  'Duyệt',
  'Tải xuống',
  'Lịch sử',
  'Thêm',
];

/// UIKit owns product navigation. The Flutter footer is only a host-test fallback.
class NativeTabs extends ChangeNotifier {
  NativeTabs({required this.onSelect});
  final ValueChanged<int> onSelect;
  static const channel = MethodChannel('dev.tachibooks/native_tabs');
  bool get enabled => !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;
  bool active = false;
  String? error;
  String? rootRoute, shellRoute;
  int _index = 0, _revision = 0;
  bool _visible = false, _dark = true, _sending = false, _disposed = false;
  bool? _sentDark;

  void initialize() {
    if (!enabled) return;
    channel.setMethodCallHandler((call) async {
      if (call.method != 'selectTab' || _disposed) return;
      final arguments = call.arguments;
      final index = arguments is Map ? arguments['index'] : null;
      if (index is int && index >= 0 && index < mainTabRoutes.length) {
        onSelect(index);
      }
    });
  }

  void update({required String path, required bool dark}) {
    if (!enabled || _disposed) return;
    final index = mainTabRoutes.indexOf(path);
    final visible =
        index >= 0 &&
        rootRoute == 'main-shell' &&
        mainTabNames.contains(shellRoute);
    final selected = index >= 0 ? index : _index;
    if (active && selected == _index && visible == _visible && dark == _dark) {
      return;
    }
    _index = selected;
    _visible = visible;
    _dark = dark;
    _revision++;
    unawaited(_send());
  }

  Future<void> _send() async {
    if (_sending) return;
    _sending = true;
    try {
      var attempts = 0;
      while (!_disposed) {
        final revision = _revision;
        final sentDark = _dark;
        final configure = !active || _sentDark != _dark;
        try {
          final result = await channel.invokeMethod<bool>(
            configure ? 'configure' : 'select',
            {
              'index': _index,
              'visible': _visible,
              if (configure) 'titles': mainTabLabels,
              if (configure) 'dark': _dark,
              if (configure) 'badges': List<String?>.filled(6, null),
            },
          );
          if (result != true) {
            throw StateError('UIKit không xác nhận thanh điều hướng');
          }
          if (_disposed) return;
          _sentDark = sentDark;
          if (!active || error != null) {
            active = true;
            error = null;
            notifyListeners();
          }
          if (revision == _revision) break;
        } on MissingPluginException {
          // Scene/implicit-engine registration may finish after the first frame.
          if (++attempts < 4) {
            await Future<void>.delayed(const Duration(milliseconds: 200));
            continue;
          }
          rethrow;
        }
      }
    } catch (e) {
      if (!_disposed) {
        error = 'Không khởi tạo được thanh tab UIKit: $e';
        notifyListeners();
      }
    } finally {
      _sending = false;
    }
  }

  @override
  void dispose() {
    _disposed = true;
    if (enabled) channel.setMethodCallHandler(null);
    super.dispose();
  }
}

class NativeTabsRouteObserver extends NavigatorObserver {
  NativeTabsRouteObserver({required this.onRouteChanged});
  final ValueChanged<String?> onRouteChanged;
  final List<Route<dynamic>> _routes = [];
  void changed() => onRouteChanged(_routes.lastOrNull?.settings.name);
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _routes.add(route);
    changed();
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _routes.remove(route);
    changed();
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    final index = oldRoute == null ? -1 : _routes.indexOf(oldRoute);
    if (index >= 0) {
      if (newRoute == null) {
        _routes.removeAt(index);
      } else {
        _routes[index] = newRoute;
      }
    } else if (newRoute != null) {
      _routes.add(newRoute);
    }
    changed();
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _routes.remove(route);
    changed();
  }
}
