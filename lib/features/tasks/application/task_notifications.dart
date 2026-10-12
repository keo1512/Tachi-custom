import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../library/data/coordinated_preferences.dart';
import '../../settings/settings_controller.dart';
import '../../privacy/application/app_lock_controller.dart';
import '../data/task_platform.dart';

final taskNotificationsProvider = NotifierProvider<TaskNotifications, bool>(
  TaskNotifications.new,
);

class TaskNotifications extends Notifier<bool> {
  static const preferenceKey = 'taskNotificationsEnabledV1';
  Future<void> _writes = Future.value();
  int _privacyGeneration = 0;
  int get privacyGeneration => _privacyGeneration;
  @override
  bool build() {
    ref.listen(settingsProvider.select((value) => value.incognitoMode), (
      _,
      private,
    ) {
      if (private) _privacyGeneration++;
    });
    ref.listen(appLockProvider, (_, next) {
      if (next.locked || next.authenticating || !next.configurationValid) {
        _privacyGeneration++;
      }
    });
    return ref.watch(preferencesProvider).get(preferenceKey) == true;
  }

  /// Called only by an explicit settings toggle. Restore never prompts iOS.
  Future<void> setEnabled(bool value) {
    final preferences = ref.read(preferencesProvider);
    final generation = preferences is CoordinatedPreferences
        ? preferences.mutationGeneration
        : null;
    final operation = _writes.then((_) async {
      if (!ref.mounted) return;
      if (value &&
          !await ref
              .read(taskPlatformProvider)
              .requestNotificationPermission()) {
        throw StateError(
          'Chưa được cấp quyền thông báo. Bạn có thể bật trong Cài đặt iOS.',
        );
      }
      if (!ref.mounted) return;
      if (preferences is CoordinatedPreferences &&
          preferences.mutationGeneration != generation) {
        throw StateError('Thiết lập đã khôi phục. Hãy mở lại màn hình.');
      }
      if (!await preferences.setBool(preferenceKey, value)) {
        throw StateError('Không lưu được thiết lập thông báo.');
      }
      if (!ref.mounted) return;
      state = value;
      if (!value) await ref.read(taskPlatformProvider).clearNotifications();
    });
    _writes = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return operation;
  }

  Future<void> summary(
    String kind,
    int completed,
    int failed, {
    bool privateSession = false,
    int? expectedPrivacyGeneration,
  }) async {
    if (!_allowed(privateSession, expectedPrivacyGeneration) ||
        (completed == 0 && failed == 0)) {
      return;
    }
    // Notification failure must never turn a completed download into a retry.
    try {
      await ref.read(taskPlatformProvider).notify(kind, completed, failed);
    } catch (_) {}
  }

  bool _allowed(bool privateSession, int? expectedPrivacyGeneration) =>
      ref.mounted &&
      state &&
      !privateSession &&
      !ref.read(settingsProvider).incognitoMode &&
      (expectedPrivacyGeneration == null ||
          expectedPrivacyGeneration == _privacyGeneration);

  bool allowsBackgroundSummary({
    required bool privateSession,
    int? expectedPrivacyGeneration,
  }) => _allowed(privateSession, expectedPrivacyGeneration);

  bool _updateAllowed(
    bool privateSession,
    int generation,
    bool Function() current,
  ) {
    if (!_allowed(privateSession, generation) || !current()) return false;
    final lock = ref.read(appLockProvider);
    return lock.initialized &&
        lock.configurationValid &&
        !lock.locked &&
        !lock.authenticating;
  }

  Future<void> bookUpdate(
    String bookId,
    int added, {
    required bool privateSession,
    required int expectedPrivacyGeneration,
    required bool Function() isCurrent,
  }) async {
    if (added <= 0 ||
        !_updateAllowed(privateSession, expectedPrivacyGeneration, isCurrent)) {
      return;
    }
    final platform = ref.read(taskPlatformProvider);
    if (platform is! LibraryUpdateNotificationPlatform) return;
    final updates = platform as LibraryUpdateNotificationPlatform;
    try {
      await updates.notifyBookUpdate(bookId, added);
      if (!_updateAllowed(
        privateSession,
        expectedPrivacyGeneration,
        isCurrent,
      )) {
        await updates.cancelBookUpdate(bookId);
      }
    } catch (_) {
      // A failed notice must not retry a successfully committed source update.
    }
  }

  Future<void> updateCompleted(
    int checked,
    int added,
    int failed, {
    required bool privateSession,
    required int expectedPrivacyGeneration,
    required bool Function() isCurrent,
  }) async {
    if (checked + failed == 0 ||
        !_updateAllowed(privateSession, expectedPrivacyGeneration, isCurrent)) {
      return;
    }
    final platform = ref.read(taskPlatformProvider);
    try {
      if (platform is LibraryUpdateNotificationPlatform) {
        await (platform as LibraryUpdateNotificationPlatform)
            .notifyUpdateCompletion(checked, added, failed);
      } else if (added + failed > 0) {
        await platform.notify('updates', added, failed);
      }
      if (!_updateAllowed(
        privateSession,
        expectedPrivacyGeneration,
        isCurrent,
      )) {
        await platform.clearNotifications();
      }
    } catch (_) {}
  }

  Future<void> pausedDownloads(
    int pending,
    int failed, {
    bool privateSession = false,
    int? expectedPrivacyGeneration,
  }) async {
    if (!_allowed(privateSession, expectedPrivacyGeneration) ||
        pending + failed == 0) {
      return;
    }
    final platform = ref.read(taskPlatformProvider);
    if (platform is! PausedTaskPlatform) return;
    try {
      await (platform as PausedTaskPlatform).notifyPausedDownloads(
        pending,
        failed,
      );
    } catch (_) {}
  }
}
