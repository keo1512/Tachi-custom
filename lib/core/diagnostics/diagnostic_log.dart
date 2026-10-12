import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../features/settings/settings_controller.dart';
import '../../features/privacy/application/app_lock_controller.dart';

/// Intentionally records categories/codes, never raw exceptions, URLs, titles,
/// credentials or source payloads. This device-local key is not portable.
class DiagnosticEvent {
  const DiagnosticEvent(this.category, this.code, this.message, this.at);
  final String category, code, message;
  final DateTime at;
  Map<String, String> toJson() => {
    'category': category,
    'code': code,
    'message': message,
    'at': at.toUtc().toIso8601String(),
  };
  static const categories = {
    'app',
    'source',
    'download',
    'backup',
    'sync',
    'background',
    'database',
    'files',
    'network',
  };
  static String safeMessage(String code) {
    final http = RegExp(r'^http_([1-5][0-9]{2})$').firstMatch(code);
    if (http != null) {
      return 'Nguồn trả lỗi HTTP ${http[1]}. Mở trang nguồn hoặc thử lại.';
    }
    return switch (code) {
      'timeout' => 'Thao tác phản hồi quá lâu. Hãy thử lại.',
      'invalid_data' => 'Dữ liệu không đúng định dạng. Hãy kiểm tra hoặc khôi phục bản sao lưu.',
      'platform' => 'Thao tác trên thiết bị chưa hoàn tất. Hãy thử lại.',
      'background_paused' => 'iOS đã dừng thời gian chạy nền. Mở ứng dụng để tiếp tục tác vụ còn lại.',
      _ => 'Thao tác chưa hoàn tất. Mở màn hình liên quan để xem trạng thái và thử lại.',
    };
  }

  static bool validCode(String code) =>
      const {
        'timeout',
        'invalid_data',
        'platform',
        'operation_failed',
        'background_paused',
      }.contains(code) ||
      RegExp(r'^http_([1-5][0-9]{2})$').hasMatch(code);
  factory DiagnosticEvent.error(String category, Object error) {
    if (!categories.contains(category)) {
      throw ArgumentError('Loại nhật ký không hợp lệ.');
    }
    final http = RegExp(
      r'\bHTTP(?: status)?[ :]+([1-5][0-9]{2})\b',
      caseSensitive: false,
    ).firstMatch('$error');
    final (code, message) = http != null
        ? (
            'http_${http[1]}',
            'Nguồn trả lỗi HTTP ${http[1]}. Mở trang nguồn hoặc thử lại.',
          )
        : switch (error) {
            TimeoutException() => (
              'timeout',
              'Thao tác phản hồi quá lâu. Hãy thử lại.',
            ),
            FormatException() => (
              'invalid_data',
              'Dữ liệu không đúng định dạng. Hãy kiểm tra hoặc khôi phục bản sao lưu.',
            ),
            PlatformException() => (
              'platform',
              'Thao tác trên thiết bị chưa hoàn tất. Hãy thử lại.',
            ),
            _ => (
              'operation_failed',
              'Thao tác chưa hoàn tất. Mở màn hình liên quan để xem trạng thái và thử lại.',
            ),
          };
    return DiagnosticEvent(category, code, message, DateTime.now());
  }
}

class DiagnosticLogs {
  static Future<void> Function(DiagnosticEvent)? writer;
  static void error(String category, Object error) {
    final sink = writer;
    if (sink != null) {
      unawaited(
        sink(DiagnosticEvent.error(category, error)).catchError((Object _) {}),
      );
    }
  }
}

class DiagnosticLogStore {
  DiagnosticLogStore(this.preferences, {this.canRecord});
  final SharedPreferences preferences;
  final bool Function()? canRecord;
  static const key = 'deviceDiagnosticLogV1';
  static const maxEntries = 100, maxBytes = 128 * 1024;
  Future<void> _pending = Future<void>.value();
  final _changes = StreamController<void>.broadcast();
  Stream<void> get changes => _changes.stream;
  List<DiagnosticEvent> read() {
    final raw = preferences.getString(key);
    if (raw == null) return const [];
    if (utf8.encode(raw).length > maxBytes) {
      throw const FormatException(
        'Nhật ký vượt giới hạn. Dữ liệu gốc được giữ.',
      );
    }
    final value = jsonDecode(raw);
    if (value is! Map ||
        value['version'] != 1 ||
        value['entries'] is! List ||
        (value['entries'] as List).length > maxEntries) {
      throw const FormatException('Nhật ký trên máy không hợp lệ.');
    }
    return [for (final item in value['entries'] as List) _decode(item)];
  }

  DiagnosticEvent _decode(Object? item) {
    if (item is! Map ||
        !DiagnosticEvent.categories.contains(item['category']) ||
        item['code'] is! String ||
        !DiagnosticEvent.validCode(item['code'] as String) ||
        item['message'] is! String ||
        (item['message'] as String).length > 500 ||
        item['at'] is! String) {
      throw const FormatException('Mục nhật ký không hợp lệ.');
    }
    // A persisted message is never trusted for display or export. Rebuild it
    // from a small allowlist, so even older/tampered entries cannot leak data.
    return DiagnosticEvent(
      item['category'] as String,
      item['code'] as String,
      DiagnosticEvent.safeMessage(item['code'] as String),
      DateTime.parse(item['at'] as String),
    );
  }

  Future<void> record(DiagnosticEvent event) {
    final result = _pending.then((_) async {
      if (preferences.getBool('incognitoMode') == true ||
          canRecord?.call() == false) {
        return;
      }
      if (!DiagnosticEvent.categories.contains(event.category) ||
          !DiagnosticEvent.validCode(event.code)) {
        throw const FormatException('Mục nhật ký không hợp lệ.');
      }
      final entries = [...read()];
      if (entries.any(
        (previous) =>
            previous.category == event.category &&
            previous.code == event.code &&
            event.at.difference(previous.at).inSeconds >= 0 &&
            event.at.difference(previous.at).inSeconds < 60,
      )) {
        return;
      }
      entries.add(
        DiagnosticEvent(
          event.category,
          event.code,
          DiagnosticEvent.safeMessage(event.code),
          event.at,
        ),
      );
      if (entries.length > maxEntries) {
        entries.removeRange(0, entries.length - maxEntries);
      }
      final raw = jsonEncode({
        'version': 1,
        'entries': entries.map((e) => e.toJson()).toList(),
      });
      if (utf8.encode(raw).length > maxBytes ||
          !await preferences.setString(key, raw)) {
        throw StateError('Không lưu được nhật ký trên máy.');
      }
      if (!_changes.isClosed) _changes.add(null);
    });
    _pending = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  Future<void> clear() {
    final result = _pending.then((_) async {
      if (!await preferences.remove(key)) {
        throw StateError('Không xóa được nhật ký trên máy.');
      }
      if (!_changes.isClosed) _changes.add(null);
    });
    _pending = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  Uint8List export() => Uint8List.fromList(
    utf8.encode(
      jsonEncode({
        'schema': 'tachi-books-diagnostic-log',
        'version': 1,
        'appVersion': '1.0.0+8',
        'entries': read().map((e) => e.toJson()).toList(),
      }),
    ),
  );
  void dispose() => unawaited(_changes.close());
}

final diagnosticLogProvider = Provider<DiagnosticLogStore>((ref) {
  final store = DiagnosticLogStore(
    ref.read(preferencesProvider),
    canRecord: () {
      if (!ref.mounted || ref.read(settingsProvider).incognitoMode) {
        return false;
      }
      final lock = ref.read(appLockProvider);
      return lock.initialized && lock.configurationValid && !lock.locked;
    },
  );
  ref.onDispose(store.dispose);
  return store;
});
final diagnosticLogChangesProvider = StreamProvider<void>(
  (ref) => ref.watch(diagnosticLogProvider).changes,
);
