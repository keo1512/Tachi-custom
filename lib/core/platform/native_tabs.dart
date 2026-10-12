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
  bool _blocked = false;
  bool? _sentDark;
  List<int> _order = const [0, 1, 2, 3, 4, 5];
  bool _showLabels = true;
  int _configurationRevision = 0, _sentConfigurationRevision = -1;

  void initialize() {
    if (!enabled) return;
    channel.setMethodCallHandler((call) async {
      if (call.method != 'selectTab' || _disposed || _blocked) return;
      final arguments = call.arguments;
      final tabId = arguments is Map ? arguments['tabId'] : null;
      if (tabId != null) {
        if (tabId is int && tabId >= 0 && tabId < mainTabRoutes.length) {
          onSelect(tabId);
        }
        return;
      }
      final index = arguments is Map ? arguments['index'] : null;
      if (index is int && index >= 0 && index < mainTabRoutes.length) {
        onSelect(_order[index]);
      }
    });
  }

  void update({
    required String path,
    required bool dark,
    bool blocked = false,
    List<int> order = const [0, 1, 2, 3, 4, 5],
    bool showLabels = true,
  }) {
    if (!enabled || _disposed) return;
    if (order.length != 6 ||
        order.toSet().length != 6 ||
        order.any((i) => i < 0 || i >= 6)) {
      throw ArgumentError('Thứ tự thanh tab không hợp lệ.');
    }
    final changed = !listEquals(_order, order) || _showLabels != showLabels;
    if (changed) {
      _order = List.unmodifiable(order);
      _showLabels = showLabels;
      _configurationRevision++;
    }
    final routeIndex = mainTabRoutes.indexOf(path);
    final index = routeIndex < 0 ? -1 : _order.indexOf(routeIndex);
    final visible =
        !blocked &&
        index >= 0 &&
        rootRoute == 'main-shell' &&
        mainTabNames.contains(shellRoute);
    final selected = index >= 0 ? index : _index;
    _blocked = blocked;
    if (active &&
        selected == _index &&
        visible == _visible &&
        dark == _dark &&
        !changed) {
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
        final sentConfiguration = _configurationRevision;
        final configure =
            !active ||
            _sentDark != _dark ||
            _sentConfigurationRevision != _configurationRevision;
        try {
          final result = await channel.invokeMethod<bool>(
            configure ? 'configure' : 'select',
            {
              'index': _index,
              'visible': _visible,
              if (configure)
                'titles': [
                  for (final id in _order) _showLabels ? mainTabLabels[id] : '',
                ],
              if (configure) 'order': _order,
              if (configure) 'dark': _dark,
              if (configure) 'badges': List<String?>.filled(6, null),
            },
          );
          if (result != true) {
            throw StateError('UIKit không xác nhận thanh điều hướng');
          }
          if (_disposed) return;
          _sentDark = sentDark;
          _sentConfigurationRevision = sentConfiguration;
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
