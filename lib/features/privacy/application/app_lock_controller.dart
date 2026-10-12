import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../settings/settings_controller.dart';
import '../data/privacy_platform.dart';
import '../domain/privacy_preferences.dart';

final privacyPlatformProvider = Provider<PrivacyPlatform>(
  (_) => NativePrivacyPlatform(),
);
final privacyClockProvider = Provider<DateTime Function()>((_) => DateTime.now);
final privacyAuthTimeoutProvider = Provider<Duration>(
  (_) => const Duration(seconds: 90),
);
final appLockProvider = NotifierProvider<AppLockController, AppLockState>(
  AppLockController.new,
);

class AppLockState {
  const AppLockState({
    this.preferences = const PrivacyPreferences(),
    this.capabilities = const PrivacyCapabilities(available: false),
    this.initialized = false,
    this.locked = false,
    this.obscured = false,
    this.authenticating = false,
    this.configurationValid = true,
    this.error,
    this.retryAfter,
  });

  final PrivacyPreferences preferences;
  final PrivacyCapabilities capabilities;
  final bool initialized, locked, obscured, authenticating;
  final bool configurationValid;
  final String? error;
  final DateTime? retryAfter;

  AppLockState copyWith({
    PrivacyPreferences? preferences,
    PrivacyCapabilities? capabilities,
    bool? initialized,
    bool? locked,
    bool? obscured,
    bool? authenticating,
    bool? configurationValid,
    String? error,
    DateTime? retryAfter,
    bool clearError = false,
    bool clearRetry = false,
  }) => AppLockState(
    preferences: preferences ?? this.preferences,
    capabilities: capabilities ?? this.capabilities,
    initialized: initialized ?? this.initialized,
    locked: locked ?? this.locked,
    obscured: obscured ?? this.obscured,
    authenticating: authenticating ?? this.authenticating,
    configurationValid: configurationValid ?? this.configurationValid,
    error: clearError ? null : error ?? this.error,
    retryAfter: clearRetry ? null : retryAfter ?? this.retryAfter,
  );
}

class AppLockController extends Notifier<AppLockState> {
  static const preferenceKey = 'privacyV1';
  int _generation = 0, _failedAttempts = 0;
  DateTime? _inactiveAt;
  bool _foreground = true;
  Future<void>? _initializing;
  Future<void> _writes = Future<void>.value();
  Timer? _idleTimer;
  DateTime? _lastInteraction;

  DateTime get _now => ref.read(privacyClockProvider)();
  PrivacyPlatform get _platform => ref.read(privacyPlatformProvider);
  bool get _incognito => ref.read(settingsProvider).incognitoMode;

  PrivacyPreferences _read() {
    final raw = ref.read(preferencesProvider).get(preferenceKey);
    if (raw == null) return const PrivacyPreferences();
    if (raw is! String) {
      throw const FormatException('Thiết lập bảo mật không hợp lệ.');
    }
    final json = jsonDecode(raw);
    if (json is! Map<String, dynamic>) {
      throw const FormatException('Thiết lập bảo mật không hợp lệ.');
    }
    return PrivacyPreferences.fromJson(json);
  }

  @override
  AppLockState build() {
    ref.watch(preferencesProvider);
    _generation++;
    _initializing = null;
    _inactiveAt = null;
    _failedAttempts = 0;
    final platform = _platform;
    ref.onDispose(() {
      _idleTimer?.cancel();
      _generation++;
      unawaited(platform.cancel().catchError((Object _) {}));
    });
    ref.listen(
      settingsProvider.select((settings) => settings.incognitoMode),
      (_, incognito) => unawaited(_configure(incognito: incognito)),
    );
    try {
      final preferences = _read();
      return AppLockState(
        preferences: preferences,
        locked: preferences.enabled,
      );
    } on FormatException {
      // Preserve the invalid bytes and fail closed until they are repaired.
      return const AppLockState(
        locked: true,
        configurationValid: false,
        error: 'Thiết lập bảo mật bị lỗi. Dữ liệu gốc đã được giữ lại.',
      );
    }
  }

  Future<void> initialize() => _initializing ??= _initialize();

  Future<void> _initialize() async {
    final generation = _generation;
    try {
      final capabilities = await _platform.capabilities();
      if (!ref.mounted || generation != _generation) return;
      state = state.copyWith(capabilities: capabilities, initialized: true);
      await _configure();
    } catch (_) {
      if (!ref.mounted || generation != _generation) return;
      state = state.copyWith(
        initialized: true,
        error: 'Không dùng được xác thực iOS. Thử lại khi thiết bị đã mở khóa.',
      );
    }
  }

  Future<void> _configure({bool? incognito}) async {
    try {
      await _platform.configure(
        state.preferences,
        incognito: incognito ?? _incognito,
      );
    } catch (_) {
      if (ref.mounted && (state.preferences.enabled || _shouldCover)) {
        state = state.copyWith(error: 'Chưa bật được bảo vệ màn hình iOS.');
      }
    }
  }

  bool get _shouldCover =>
      state.preferences.enabled ||
      state.preferences.secureScreen == SecureScreenMode.always ||
      (state.preferences.secureScreen == SecureScreenMode.incognito &&
          _incognito);

  Future<bool> _authenticate() async {
    if (state.authenticating) return false;
    if (state.retryAfter != null && _now.isBefore(state.retryAfter!)) {
      return false;
    }
    final generation = ++_generation;
    state = state.copyWith(authenticating: true, clearError: true);
    var success = false;
    String? error;
    try {
      success = await _platform.authenticate().timeout(
        ref.read(privacyAuthTimeoutProvider),
        onTimeout: () {
          unawaited(_platform.cancel().catchError((Object _) {}));
          throw TimeoutException('authentication');
        },
      );
      if (!success) error = 'Chưa mở khóa. Bạn có thể thử lại.';
    } on TimeoutException {
      error = 'Xác thực quá lâu. Chạm Mở khóa để thử lại.';
    } on PlatformException catch (failure) {
      error = failure.code == 'unavailable'
          ? 'Đặt mã khóa trong Cài đặt iPhone/iPad để bật khóa ứng dụng.'
          : 'Không mở khóa được. Hãy dùng mã khóa thiết bị hoặc thử lại.';
    } catch (_) {
      error = 'Không dùng được xác thực iOS. Thử lại trên iPhone/iPad.';
    }
    if (!ref.mounted || generation != _generation || !_foreground) return false;
    if (success) {
      _failedAttempts = 0;
      state = state.copyWith(
        authenticating: false,
        clearRetry: true,
        clearError: true,
      );
    } else {
      _failedAttempts++;
      final seconds = _failedAttempts < 3
          ? 0
          : (5 * (_failedAttempts - 2)).clamp(5, 30);
      state = state.copyWith(
        authenticating: false,
        error: error,
        retryAfter: seconds == 0 ? null : _now.add(Duration(seconds: seconds)),
        clearRetry: seconds == 0,
      );
    }
    return success;
  }

  Future<bool> unlock() async {
    if (!state.configurationValid) return false;
    if (!state.locked) return true;
    if (!await _authenticate()) return false;
    if (!ref.mounted) return false;
    _inactiveAt = null;
    state = state.copyWith(locked: false);
    recordActivity();
    return true;
  }

  void lockNow() {
    if (!state.preferences.enabled) return;
    _idleTimer?.cancel();
    _generation++;
    unawaited(_platform.cancel().catchError((Object _) {}));
    state = state.copyWith(
      locked: true,
      authenticating: false,
      clearError: true,
    );
  }

  Future<void> update({
    bool? enabled,
    int? delaySeconds,
    int? idleSeconds,
    SecureScreenMode? secureScreen,
  }) {
    final result = _writes.then((_) async {
      final previous = _read();
      final next = previous.copyWith(
        enabled: enabled,
        delaySeconds: delaySeconds,
        idleSeconds: idleSeconds,
        secureScreen: secureScreen,
      );
      PrivacyPreferences.fromJson(next.toJson());
      if (next.enabled != previous.enabled && !await _authenticate()) return;
      if (!ref.mounted || !_foreground) return;
      final preferences = ref.read(preferencesProvider);
      final raw = preferences.getString(preferenceKey);
      final json = raw == null
          ? <String, dynamic>{}
          : jsonDecode(raw) as Map<String, dynamic>;
      final updated = {...json, ...next.toJson()};
      if (next.idleSeconds == 0) updated.remove('idleSeconds');
      try {
        if (!await preferences.setString(
          preferenceKey,
          jsonEncode(updated),
        )) {
          throw StateError('Không lưu được thiết lập bảo mật.');
        }
      } catch (_) {
        if (raw == null) {
          await preferences.remove(preferenceKey);
        } else {
          await preferences.setString(preferenceKey, raw);
        }
        rethrow;
      }
      if (!ref.mounted) return;
      _generation++;
      state = state.copyWith(
        preferences: next,
        locked: false,
        clearError: true,
        clearRetry: true,
      );
      await _configure();
      if (ref.mounted) recordActivity();
    });
    _writes = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  void lifecycle(AppLifecycleState lifecycle) {
    if (lifecycle == AppLifecycleState.resumed) {
      _foreground = true;
      final inactiveAt = _inactiveAt;
      _inactiveAt = null;
      final elapsed = inactiveAt == null ? null : _now.difference(inactiveAt);
      final expired =
          elapsed != null &&
          (elapsed.isNegative ||
              elapsed.inSeconds >= state.preferences.delaySeconds);
      state = state.copyWith(
        locked: state.locked || (state.preferences.enabled && expired),
        obscured: false,
      );
      recordActivity();
      return;
    }
    if (lifecycle == AppLifecycleState.inactive && state.authenticating) return;
    if (lifecycle == AppLifecycleState.inactive ||
        lifecycle == AppLifecycleState.paused ||
        lifecycle == AppLifecycleState.hidden ||
        lifecycle == AppLifecycleState.detached) {
      _foreground = false;
      _idleTimer?.cancel();
      _inactiveAt ??= _now;
      _generation++;
      unawaited(_platform.cancel().catchError((Object _) {}));
      state = state.copyWith(
        locked:
            state.locked ||
            (state.preferences.enabled && state.preferences.delaySeconds == 0),
        obscured: _shouldCover,
        authenticating: false,
      );
    }
  }

  /// Called after Flutter has rendered the resumed state, before exposing UIKit.
  /// Input renews only an unlocked foreground session. It never unlocks it.
  void recordActivity() {
    if (!ref.mounted) return;
    _idleTimer?.cancel();
    if (!_foreground ||
        state.locked ||
        state.authenticating ||
        !state.preferences.enabled ||
        state.preferences.idleSeconds == 0) {
      return;
    }
    _lastInteraction = _now;
    _scheduleIdle(Duration(seconds: state.preferences.idleSeconds));
  }

  void _scheduleIdle(Duration duration) {
    _idleTimer?.cancel();
    _idleTimer = Timer(duration, checkIdle);
  }

  void checkIdle() {
    if (!ref.mounted ||
        !_foreground ||
        state.locked ||
        state.authenticating ||
        !state.preferences.enabled ||
        state.preferences.idleSeconds == 0) {
      return;
    }
    final last = _lastInteraction;
    if (last == null) {
      recordActivity();
      return;
    }
    final elapsed = _now.difference(last);
    final threshold = Duration(seconds: state.preferences.idleSeconds);
    if (elapsed.isNegative || elapsed >= threshold) {
      lockNow();
    } else {
      _scheduleIdle(threshold - elapsed);
    }
  }

  Future<void> foregroundReady() async {
    if (!_foreground) return;
    try {
      await _platform.foregroundReady();
    } catch (_) {}
  }
}
