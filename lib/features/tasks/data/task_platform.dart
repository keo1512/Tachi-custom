import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../deep_links/domain/app_deep_link.dart';

abstract interface class TaskPlatform {
  Stream<void> get backgroundExpired;
  Future<bool> requestNotificationPermission();
  Future<bool> notify(String kind, int completed, int failed);
  Future<void> clearNotifications();
  Future<bool> beginBackground();
  Future<void> endBackground();
  void dispose();
}

/// Additive capability: existing task platforms keep their completion contract.
abstract interface class PausedTaskPlatform {
  Future<bool> notifyPausedDownloads(int pending, int failed);
}

abstract interface class ContinuedTaskPlatform {
  Stream<void> get continuedProcessingExpired;
  Future<void> downloadPageProgress(int completed, int total);
}

/// A local book identity is sufficient to navigate after app-lock and revision
/// checks. Notification text never includes a title, account or source URL.
abstract interface class LibraryUpdateNotificationPlatform {
  Future<bool> notifyBookUpdate(String bookId, int addedChapters);
  Future<void> cancelBookUpdate(String bookId);
  Future<bool> notifyUpdateCompletion(int checked, int added, int failed);
}

/// Native snapshots let iOS finish the lease and post a numeric notice even
/// when Dart no longer receives callbacks. Scheduled windows reuse the normal
/// guarded queue executor; they never substitute raw HTTP for engine getImage.
abstract interface class BackgroundTaskPlatform {
  Stream<int> get scheduledBackground;
  Future<void> backgroundReady();
  Future<void> updateBackgroundSnapshot({
    required int pending,
    required int failed,
    required bool notifyOnPause,
    required bool resumeRequested,
  });
  Future<void> completeScheduledBackground(int token, {required bool success});
}

/// Optional extension of the legacy four-field snapshot. A platform without
/// this capability still supports ordinary finite leases for active updates.
abstract interface class BackgroundLibraryUpdatePlatform {
  Future<void> updateBackgroundWorkSnapshot({
    required int pending,
    required int failed,
    required bool notifyOnPause,
    required bool resumeRequested,
    required bool updatesRequested,
    required int updateEarliestMillis,
    required int updateRemaining,
    required int updateFailed,
    required bool notifyUpdatePause,
  });
}

final taskPlatformProvider = Provider<TaskPlatform>((ref) {
  final platform = NativeTaskPlatform();
  ref.onDispose(platform.dispose);
  return platform;
});

/// Contains only numeric summaries, never title, URL, account or error text.
class NativeTaskPlatform
    implements
        TaskPlatform,
        ContinuedTaskPlatform,
        PausedTaskPlatform,
        LibraryUpdateNotificationPlatform,
        BackgroundTaskPlatform,
        BackgroundLibraryUpdatePlatform {
  NativeTaskPlatform() {
    if (_available) {
      _channel.setMethodCallHandler((call) async {
        if (call.method == 'backgroundExpired' && !_disposed) {
          _expired.add(null);
        } else if (call.method == 'continuedProcessingExpired' && !_disposed) {
          _continuedExpired.add(null);
        } else if (call.method == 'scheduledBackground' && !_disposed) {
          final token = call.arguments;
          if (token is int && token > 0 && token <= 0x7fffffff) {
            _scheduled.add(token);
          }
        }
      });
    }
  }
  static const _channel = MethodChannel('dev.tachibooks/tasks');
  final _expired = StreamController<void>.broadcast(sync: true);
  final _continuedExpired = StreamController<void>.broadcast(sync: true);
  @override
  Stream<void> get continuedProcessingExpired => _continuedExpired.stream;
  @override
  Future<void> downloadPageProgress(int completed, int total) async {
    if (completed < 0 || total <= 0 || completed > total || total > 10000) {
      throw ArgumentError('Tiến độ tải không hợp lệ.');
    }
    if (_available) {
      await _channel.invokeMethod<void>('downloadPageProgress', {
        'completed': completed,
        'total': total,
      });
    }
  }

  final _scheduled = StreamController<int>.broadcast(sync: true);
  bool _disposed = false;
  bool get _available => !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;
  @override
  Stream<void> get backgroundExpired => _expired.stream;
  @override
  Stream<int> get scheduledBackground => _scheduled.stream;
  @override
  Future<void> backgroundReady() async {
    if (_available) await _channel.invokeMethod<void>('backgroundReady');
  }

  @override
  Future<void> updateBackgroundSnapshot({
    required int pending,
    required int failed,
    required bool notifyOnPause,
    required bool resumeRequested,
  }) async {
    if (pending < 0 || failed < 0 || pending > 1000000 || failed > 1000000) {
      throw ArgumentError('Tóm tắt tác vụ không hợp lệ.');
    }
    if (_available) {
      await _channel.invokeMethod<void>('updateBackgroundSnapshot', {
        'pending': pending,
        'failed': failed,
        'notifyOnPause': notifyOnPause,
        'resumeRequested': resumeRequested && pending > 0,
      });
    }
  }

  @override
  Future<void> completeScheduledBackground(
    int token, {
    required bool success,
  }) async {
    if (token <= 0 || token > 0x7fffffff) {
      throw ArgumentError('Mã lượt chạy nền không hợp lệ.');
    }
    if (_available) {
      await _channel.invokeMethod<void>('completeScheduledBackground', {
        'token': token,
        'success': success,
      });
    }
  }

  @override
  Future<void> updateBackgroundWorkSnapshot({
    required int pending,
    required int failed,
    required bool notifyOnPause,
    required bool resumeRequested,
    required bool updatesRequested,
    required int updateEarliestMillis,
    required int updateRemaining,
    required int updateFailed,
    required bool notifyUpdatePause,
  }) async {
    if ([
          pending,
          failed,
          updateRemaining,
          updateFailed,
        ].any((n) => n < 0 || n > 1000000) ||
        updateEarliestMillis < 0 ||
        updateEarliestMillis > 253402300799999) {
      throw ArgumentError('Tóm tắt cập nhật nền không hợp lệ.');
    }
    if (_available) {
      await _channel.invokeMethod<void>('updateBackgroundSnapshot', {
        'pending': pending,
        'failed': failed,
        'notifyOnPause': notifyOnPause,
        'resumeRequested': resumeRequested && pending > 0,
        'updatesRequested': updatesRequested,
        'updateEarliestMillis': updateEarliestMillis,
        'updateRemaining': updateRemaining,
        'updateFailed': updateFailed,
        'notifyUpdatePause':
            notifyUpdatePause && updateRemaining + updateFailed > 0,
      });
    }
  }

  @override
  Future<bool> requestNotificationPermission() async =>
      _available &&
      await _channel.invokeMethod<bool>('requestNotificationPermission') ==
          true;
  @override
  Future<bool> notify(String kind, int completed, int failed) async {
    if (!['downloads', 'updates'].contains(kind) ||
        completed < 0 ||
        failed < 0 ||
        completed > 1000000 ||
        failed > 1000000) {
      throw ArgumentError('Tóm tắt tác vụ không hợp lệ.');
    }
    return _available &&
        await _channel.invokeMethod<bool>('notify', {
              'kind': kind,
              'completed': completed,
              'failed': failed,
            }) ==
            true;
  }

  @override
  Future<bool> notifyPausedDownloads(int pending, int failed) async {
    if (pending < 0 || failed < 0 || pending > 1000000 || failed > 1000000) {
      throw ArgumentError('Tóm tắt tác vụ không hợp lệ.');
    }
    if (pending + failed == 0) return false;
    return _available &&
        await _channel.invokeMethod<bool>('notifyPausedDownloads', {
              'pending': pending,
              'failed': failed,
            }) ==
            true;
  }

  static void _checkBookId(String bookId) {
    if (bookId.isEmpty ||
        bookId.contains(RegExp(r'[\x00-\x1f\x7f]')) ||
        utf8.encode(bookId).length > 2048) {
      throw ArgumentError('Mã truyện trong thông báo không hợp lệ.');
    }
    // Use the same bounded identity contract as the guarded link inbox.
    LibraryDeepLink(bookId, notification: true).identity;
  }

  @override
  Future<bool> notifyBookUpdate(String bookId, int addedChapters) async {
    _checkBookId(bookId);
    if (addedChapters <= 0 || addedChapters > 1000000) {
      throw ArgumentError('Số chương mới trong thông báo không hợp lệ.');
    }
    return _available &&
        await _channel.invokeMethod<bool>('notifyBookUpdate', {
              'bookId': bookId,
              'added': addedChapters,
            }) ==
            true;
  }

  @override
  Future<void> cancelBookUpdate(String bookId) async {
    _checkBookId(bookId);
    if (_available) {
      await _channel.invokeMethod<void>('cancelBookUpdate', {'bookId': bookId});
    }
  }

  @override
  Future<bool> notifyUpdateCompletion(
    int checked,
    int added,
    int failed,
  ) async {
    if ([checked, added, failed].any((n) => n < 0 || n > 1000000) ||
        checked + failed == 0) {
      throw ArgumentError('Kết quả cập nhật không hợp lệ.');
    }
    return _available &&
        await _channel.invokeMethod<bool>('notifyUpdateCompletion', {
              'checked': checked,
              'added': added,
              'failed': failed,
            }) ==
            true;
  }

  @override
  Future<void> clearNotifications() async {
    if (_available) await _channel.invokeMethod<void>('clearNotifications');
  }

  @override
  Future<bool> beginBackground() async =>
      _available &&
      await _channel.invokeMethod<bool>('beginBackground') == true;
  @override
  Future<void> endBackground() async {
    if (_available) await _channel.invokeMethod<void>('endBackground');
  }

  @override
  void dispose() {
    _disposed = true;
    if (_available) {
      _channel.setMethodCallHandler(null);
      unawaited(endBackground().catchError((Object _) {}));
    }
    unawaited(_expired.close());
    unawaited(_continuedExpired.close());
    unawaited(_scheduled.close());
  }
}
