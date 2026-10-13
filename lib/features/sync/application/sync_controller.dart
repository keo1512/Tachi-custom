import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/diagnostics/diagnostic_log.dart';

import '../../library/application/backup_service_provider.dart';
import '../../library/application/extension_recovery_controller.dart';
import '../../privacy/application/app_lock_controller.dart';
import '../../library/presentation/library_view_model.dart';
import '../../settings/settings_controller.dart';
import '../data/backup_sync_local.dart';
import '../data/firestore_sync_remote.dart';
import '../data/google_session.dart';
import '../data/sync_link_store.dart';
import '../data/sync_platform.dart';
import '../domain/sync_engine.dart';

final syncAuthProvider = Provider<SyncAuth>((ref) => GoogleSession());
final syncClockProvider = Provider<DateTime Function()>((ref) => DateTime.now);
final syncLocalProvider = Provider<SyncLocal>(
  (ref) => BackupSyncLocal(
    backup: ref.read(backupServiceProvider),
    links: SyncLinkStore(ref.read(preferencesProvider)),
    beforeSnapshot: () async {
      await ref.read(appLockProvider.notifier).initialize();
      final lock = ref.read(appLockProvider);
      if (!lock.initialized || lock.locked || !lock.configurationValid) {
        throw const SyncFailure('Mở khóa ứng dụng trước khi đồng bộ.');
      }
      await ref.read(extensionRecoveryProvider.future);
    },
    beforeCapture: () {
      final lock = ref.read(appLockProvider);
      if (!lock.initialized || lock.locked || !lock.configurationValid) {
        throw const SyncFailure('Mở khóa ứng dụng trước khi đồng bộ.');
      }
      final recovery = ref.read(extensionRecoveryProvider);
      if (recovery.isLoading || recovery.hasError) {
        throw const SyncFailure(
          'Còn phục hồi extension chưa hoàn tất. Mở Sao lưu & Khôi phục và thử lại.',
        );
      }
    },
  ),
);
final syncRemoteFactoryProvider = Provider<SyncRemote Function(String)>((ref) {
  return (uid) {
    final session = ref.read(syncAuthProvider);
    if (session is! GoogleSession) {
      throw const SyncFailure('Chưa cấu hình kết nối đồng bộ.');
    }
    return FirestoreSyncRemote(
      uid: uid,
      db: FirebaseFirestore.instance,
      auth: session.auth,
    );
  };
});
final syncProvider = NotifierProvider<SyncController, SyncState>(
  SyncController.new,
);

class SyncState {
  const SyncState({
    this.user,
    this.busy = false,
    this.enabled = false,
    this.conflict = false,
    this.error = false,
    this.message,
    this.lastSyncedAt,
    this.initialized = false,
    this.progress,
  });
  final SyncUser? user;
  final bool busy, enabled, conflict, error, initialized;
  final String? message;
  final DateTime? lastSyncedAt;
  final SyncTransferProgress? progress;

  SyncState copyWith({
    SyncUser? user,
    bool? busy,
    bool? enabled,
    bool? conflict,
    bool? error,
    String? message,
    DateTime? lastSyncedAt,
    bool? initialized,
    SyncTransferProgress? progress,
    bool clearProgress = false,
  }) => SyncState(
    user: user ?? this.user,
    busy: busy ?? this.busy,
    enabled: enabled ?? this.enabled,
    conflict: conflict ?? this.conflict,
    error: error ?? this.error,
    message: message ?? this.message,
    lastSyncedAt: lastSyncedAt ?? this.lastSyncedAt,
    initialized: initialized ?? this.initialized,
    progress: clearProgress ? null : progress ?? this.progress,
  );
}

class SyncController extends Notifier<SyncState> {
  SyncEngine? _engine;
  DateTime? _lastAutomaticAttempt;
  int _completedRuns = 0;
  @override
  SyncState build() => const SyncState();

  SyncConflict? get pendingConflict => _engine?.conflict;
  int get completedRuns => _completedRuns;

  /// Foreground scheduling and the request guard use one shared throttle.
  Duration get automaticSyncDelay {
    final last = _lastAutomaticAttempt;
    if (last == null) return Duration.zero;
    final remaining =
        const Duration(minutes: 1) -
        ref.read(syncClockProvider)().difference(last);
    return remaining > Duration.zero ? remaining : Duration.zero;
  }

  SyncEngine _forUser(SyncUser user) {
    if (_engine?.uid != user.uid) {
      final remote = ref.read(syncRemoteFactoryProvider)(user.uid);
      if (remote is SyncProgressRemote) {
        (remote as SyncProgressRemote).onProgress = (progress) {
          if (ref.mounted && state.busy && state.user?.uid == user.uid) {
            state = state.copyWith(progress: progress);
          }
        };
      }
      _engine = SyncEngine(
        uid: user.uid,
        local: ref.read(syncLocalProvider),
        remote: remote,
      );
    }
    return _engine!;
  }

  void _setUser(SyncUser user) {
    final link = ref.read(syncLocalProvider).link;
    final owned = link?.uid == user.uid;
    state = SyncState(
      user: user,
      busy: true,
      initialized: true,
      conflict: _engine?.uid == user.uid && _engine?.conflict != null,
      enabled: owned && link!.enabled,
      lastSyncedAt: owned ? link!.lastSyncedAt : null,
    );
  }

  Future<void> _run(Future<void> Function() action) async {
    if (state.busy) return;
    state = state.copyWith(
      busy: true,
      error: false,
      message: '',
      clearProgress: true,
    );
    try {
      await action();
      if (ref.mounted) state = state.copyWith(busy: false);
    } catch (error) {
      if (ref.mounted) {
        DiagnosticLogs.error('sync', error);
        var enabled = state.enabled;
        // Enabling sync pins the link before requesting the network. Reflect
        // that persisted choice even when its first upload fails. A malformed
        // link must still be preserved rather than replaced while reporting it.
        try {
          final link = ref.read(syncLocalProvider).link;
          if (state.user != null && link?.uid == state.user!.uid) {
            enabled = link!.enabled;
          }
        } catch (_) {
          // Keep the last known state; the original error remains actionable.
        }
        state = state.copyWith(
          busy: false,
          enabled: enabled,
          error: true,
          initialized: true,
          conflict: _engine?.conflict != null,
          message: syncErrorMessage(error),
        );
      }
    }
  }

  /// Restores a real Firebase session; signing in never implicitly enables sync.
  Future<void> resume() => _run(() async {
    final auth = ref.read(syncAuthProvider);
    await auth.initialize();
    final user = auth.currentUser;
    if (user == null) {
      state = const SyncState(busy: true, initialized: true);
      return;
    }
    _setUser(user);
    if (state.enabled && _engine?.conflict == null) {
      await _sync(user, enable: false, automatic: true);
    }
  });

  Future<void> signIn() => _run(() async {
    final user = await ref.read(syncAuthProvider).signIn();
    if (user == null) {
      state = state.copyWith(message: 'Đã hủy đăng nhập.', error: false);
      return;
    }
    _engine = null;
    _lastAutomaticAttempt = null;
    _setUser(user);
    state = state.copyWith(
      message: state.enabled
          ? 'Đã đăng nhập. Bấm Đồng bộ ngay để cập nhật thư viện.'
          : 'Đã đăng nhập. Bạn có thể bật đồng bộ cho thư viện này.',
    );
  });

  Future<void> openGoogleAccount({
    GoogleAccountAction action = GoogleAccountAction.profile,
  }) => _run(() => SyncPlatform.openGoogleAccount(action: action));

  Future<void> sync({bool enable = false, bool automatic = false}) =>
      _run(() async {
        final user = ref.read(syncAuthProvider).currentUser;
        if (user == null || user.uid != state.user?.uid) {
          throw const SyncFailure('Hãy đăng nhập Google trước khi đồng bộ.');
        }
        await _sync(user, enable: enable, automatic: automatic);
      });

  Future<void> _sync(
    SyncUser user, {
    required bool enable,
    bool automatic = false,
  }) async {
    final now = ref.read(syncClockProvider)();
    if (automatic && automaticSyncDelay > Duration.zero) {
      return;
    }
    // Manual attempts also postpone the next automatic request. Switching
    // between applications cannot bypass this interval and consume free quota.
    _lastAutomaticAttempt = now;
    final engine = _forUser(user);
    final outcome = await engine.run(enable: enable);
    await _afterOutcome(user, outcome);
    _completedRuns++;
  }

  Future<void> _afterOutcome(SyncUser user, SyncOutcome outcome) async {
    final link = ref.read(syncLocalProvider).link;
    if (outcome == SyncOutcome.downloaded) {
      await ref.read(libraryProvider.notifier).refresh();
    }
    if (!ref.mounted) return;
    state = SyncState(
      user: user,
      busy: true,
      initialized: true,
      enabled: link?.uid == user.uid && link!.enabled,
      conflict: outcome == SyncOutcome.conflict,
      lastSyncedAt: link?.uid == user.uid ? link!.lastSyncedAt : null,
      message: switch (outcome) {
        SyncOutcome.current => 'Thư viện trên máy và cloud đã đồng nhất.',
        SyncOutcome.uploaded => 'Đã tải bản sao lưu đầy đủ lên cloud.',
        SyncOutcome.downloaded => 'Đã khôi phục bản cloud. Bản trên máy trước đó được giữ làm bản phục hồi.',
        SyncOutcome.conflict =>
          'Thư viện trên máy và cloud đều đã thay đổi. Hãy chọn bản muốn giữ.',
        SyncOutcome.paused => 'Đồng bộ đang tắt cho thư viện này.',
      },
    );
  }

  Future<void> pause() => _run(() async {
    final user = ref.read(syncAuthProvider).currentUser;
    if (user == null || user.uid != state.user?.uid) {
      throw const SyncFailure(
        'Hãy đăng nhập tài khoản đã liên kết trước khi tắt đồng bộ.',
      );
    }
    await _forUser(user).pause();
    state = state.copyWith(
      enabled: false,
      conflict: false,
      message: 'Đã tắt đồng bộ. Thư viện và bản cloud được giữ nguyên.',
    );
  });

  Future<void> resolve({required bool keepLocal}) => _run(() async {
    final user = ref.read(syncAuthProvider).currentUser;
    if (user == null || user.uid != state.user?.uid) {
      throw const SyncFailure('Tài khoản đã thay đổi. Hãy đăng nhập lại.');
    }
    final outcome = await _forUser(user).resolve(keepLocal: keepLocal);
    await _afterOutcome(user, outcome);
  });

  Future<void> resolveRecords(Map<String, bool> choices) => _run(() async {
    final user = ref.read(syncAuthProvider).currentUser;
    if (user == null || user.uid != state.user?.uid) {
      throw const SyncFailure('Tài khoản đã thay đổi. Hãy đăng nhập lại.');
    }
    final outcome = await _forUser(user).resolveRecords(choices);
    await _afterOutcome(user, outcome);
  });

  Future<void> signOut() => _run(() async {
    // Pause the persisted link first so a later sign-in cannot silently resume.
    final user = ref.read(syncAuthProvider).currentUser;
    final link = ref.read(syncLocalProvider).link;
    if (user != null && link?.uid == user.uid) await _forUser(user).pause();
    await ref.read(syncAuthProvider).signOut();
    _engine = null;
    _lastAutomaticAttempt = null;
    state = const SyncState(
      busy: true,
      initialized: true,
      message: 'Đã đăng xuất. Thư viện trên máy được giữ nguyên.',
    );
  });
}
