import 'package:flutter/services.dart';

/// Only the current reader owns the system overlays. Queued writes from a
/// previous reader are ignored, and release cannot restore over a newer owner.
class ReaderSystemUiLease {
  static ReaderSystemUiLease? _owner;
  static Future<void> _pending = Future<void>.value();
  bool? _fullScreen, _hideStatusBar;

  Future<void> apply({required bool fullScreen, required bool hideStatusBar}) {
    if (identical(_owner, this) &&
        _fullScreen == fullScreen &&
        _hideStatusBar == hideStatusBar) {
      return _pending;
    }
    _owner = this;
    _fullScreen = fullScreen;
    _hideStatusBar = hideStatusBar;
    final result = _pending.then((_) async {
      if (!identical(_owner, this)) return;
      await SystemChrome.setEnabledSystemUIMode(
        SystemUiMode.manual,
        overlays: [
          if (!fullScreen && !hideStatusBar) SystemUiOverlay.top,
          if (!fullScreen) SystemUiOverlay.bottom,
        ],
      );
    });
    _pending = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  Future<void> release() {
    if (!identical(_owner, this)) return _pending;
    _owner = null;
    _fullScreen = _hideStatusBar = null;
    final result = _pending.then((_) async {
      if (_owner != null) return;
      await SystemChrome.setEnabledSystemUIMode(
        SystemUiMode.manual,
        overlays: SystemUiOverlay.values,
      );
    });
    _pending = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }
}
