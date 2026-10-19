import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../../settings/settings_controller.dart';
import '../../privacy/application/app_lock_controller.dart';
import '../data/automatic_backup_store.dart';
import '../data/backup_directory_platform.dart';
import '../data/external_automatic_backup_store.dart';
import '../data/coordinated_preferences.dart';
import 'backup_service_provider.dart';
import 'automatic_backup_status.dart';
import 'extension_recovery_controller.dart';

final automaticBackupStoreProvider = FutureProvider<AutomaticBackupStore>((
  ref,
) async {
  final backup = ref.read(backupServiceProvider);
  final platform = ref.watch(backupDirectoryPlatformProvider);
  final selected = await ref.watch(backupDirectoryLocationProvider.future);
  if (selected != null) {
    return ExternalAutomaticBackupStore(backup, platform, selected);
  }
  final directory = await getApplicationSupportDirectory();
  return AutomaticBackupStore(
    Directory('${directory.path}/automatic-backups'),
    backup,
  );
});

final automaticBackupPolicyProvider =
    NotifierProvider<AutomaticBackupPolicyController, AutomaticBackupPolicy>(
      AutomaticBackupPolicyController.new,
    );

class AutomaticBackupPolicyController extends Notifier<AutomaticBackupPolicy> {
  static const key = 'automaticBackupPolicyV1';
  Future<void> _pending = Future.value();
  @override
  AutomaticBackupPolicy build() {
    try {
      return AutomaticBackupPolicy.decode(
        ref.watch(preferencesProvider).getString(key),
      );
    } catch (_) {
      return const AutomaticBackupPolicy();
    }
  }

  Future<void> update({int? hours, int? keep}) {
    final work = _pending.then((_) async {
      final preferences = ref.read(preferencesProvider);
      final current = AutomaticBackupPolicy.decode(preferences.getString(key));
      final next = AutomaticBackupPolicy.decode(
        AutomaticBackupPolicy(
          hours: hours ?? current.hours,
          keep: keep ?? current.keep,
        ).encode(),
      );
      if (!await preferences.setString(key, next.encode())) {
        throw StateError('Không lưu được lịch sao lưu.');
      }
      if (ref.mounted) state = next;
    });
    _pending = work.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return work;
  }
}

final automaticBackupSchedulerProvider = Provider<AutomaticBackupScheduler>(
  AutomaticBackupScheduler.new,
);

class AutomaticBackupInterrupted extends StateError {
  AutomaticBackupInterrupted()
    : super('Phiên sao lưu đã bị ngắt. Sẽ thử lại trong lượt sau.');
}

class AutomaticBackupExecutionGate {
  int _generation = 0;
  bool _allowed = true;
  bool _userStopped = false;
  void allow() => _allowed = true;
  void expire() {
    _allowed = false;
    _generation++;
  }

  int begin({bool userInitiated = false}) {
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    if (_userStopped &&
        userInitiated &&
        (lifecycle == null || lifecycle == AppLifecycleState.resumed)) {
      _userStopped = false;
      allow();
    }
    if (!_allowed || _userStopped) throw AutomaticBackupInterrupted();
    return _generation;
  }

  void check(int generation) {
    if (!_allowed || generation != _generation) {
      throw AutomaticBackupInterrupted();
    }
  }

  void stopForUser() {
    _userStopped = true;
    expire();
  }
}

final automaticBackupExecutionProvider = Provider<AutomaticBackupExecutionGate>(
  (ref) {
    final gate = AutomaticBackupExecutionGate();
    ref.onDispose(gate.expire);
    return gate;
  },
);

class AutomaticBackupScheduler {
  AutomaticBackupScheduler(this.ref);
  final Ref ref;
  Future<StoredBackup?>? _active;
  Future<StoredBackup?> check(DateTime now, {bool force = false}) {
    if (_active != null) return _active!;
    final operation = _run(now, force: force);
    _active = operation;
    return operation.whenComplete(() => _active = null);
  }

  Future<StoredBackup?> _run(DateTime now, {required bool force}) async {
    final policy = ref.read(automaticBackupPolicyProvider);
    final preferences = ref.read(preferencesProvider);
    if (!force && policy.hours == 0) return null;
    if (!force && ref.read(settingsProvider).incognitoMode) return null;
    final last = preferences.getInt('lastAutomaticBackup');
    if (!force &&
        last != null &&
        now.difference(DateTime.fromMillisecondsSinceEpoch(last)).inHours <
            policy.hours) {
      return null;
    }
    // Capturing installed packages can initialize source code. Wait for the
    // privacy gate and an interrupted restore before invoking either runtime.
    await ref.read(appLockProvider.notifier).initialize();
    if (!ref.mounted) return null;
    final lock = ref.read(appLockProvider);
    if (!lock.initialized || lock.locked || !lock.configurationValid) {
      return null;
    }
    await ref.read(extensionRecoveryProvider.future);
    if (!ref.mounted) return null;
    if (ref.read(appLockProvider).locked ||
        !ref.read(appLockProvider).configurationValid) {
      return null;
    }
    final gate = ref.read(automaticBackupExecutionProvider);
    final execution = gate.begin(userInitiated: force);
    final repository = ref.read(backupServiceProvider).repository;
    final revision = repository.replacementRevision;
    final generation = preferences is CoordinatedPreferences
        ? preferences.mutationGeneration
        : 0;
    void check() {
      if (!ref.mounted) throw AutomaticBackupInterrupted();
      gate.check(execution);
      if (repository.replacementRevision != revision ||
          (preferences is CoordinatedPreferences &&
              preferences.mutationGeneration != generation) ||
          (!force && ref.read(settingsProvider).incognitoMode)) {
        throw AutomaticBackupInterrupted();
      }
      final lock = ref.read(appLockProvider);
      if (!lock.initialized || lock.locked || !lock.configurationValid) {
        throw StateError('Ứng dụng đang khóa; sao lưu chưa được tạo.');
      }
      if (!force && ref.read(automaticBackupPolicyProvider).hours == 0) {
        throw AutomaticBackupInterrupted();
      }
    }

    final status = ref.read(automaticBackupStatusProvider.notifier);
    await status.record(
      AutomaticBackupRunStatus(
        stage: AutomaticBackupRunStage.running,
        userInitiated: force,
        startedAt: now,
      ),
    );
    StoredBackup? stored;
    try {
      final store = await ref.read(automaticBackupStoreProvider.future);
      if (!ref.mounted) return null;
      check();
      stored = await store.create(
        now,
        keep: policy.keep,
        beforeCapture: () {
          check();
          if (!ref.mounted) throw StateError('Lượt sao lưu đã đóng.');
          final lock = ref.read(appLockProvider);
          if (!lock.initialized || lock.locked || !lock.configurationValid) {
            throw StateError('Ứng dụng đang khóa; sao lưu chưa được tạo.');
          }
          final recovery = ref.read(extensionRecoveryProvider);
          if (recovery.isLoading || recovery.hasError) {
            throw StateError(
              'Còn phục hồi extension chưa hoàn tất. Mở Sao lưu & Khôi phục và thử lại.',
            );
          }
        },
        beforePublish: check,
      );
      check();
      if (!await preferences.setInt(
        'lastAutomaticBackup',
        now.millisecondsSinceEpoch,
      )) {
        throw StateError('Không lưu được thời điểm sao lưu.');
      }
      if (ref.mounted) {
        await status.record(
          AutomaticBackupRunStatus(
            stage: AutomaticBackupRunStage.succeeded,
            userInitiated: force,
            startedAt: now,
            finishedAt: DateTime.now(),
            fileName: stored.name,
            bytes: stored.size,
          ),
        );
      }
      return stored;
    } catch (error) {
      if (ref.mounted) {
        try {
          await status.record(
            AutomaticBackupRunStatus(
              userInitiated: force,
              stage: error is AutomaticBackupInterrupted
                  ? AutomaticBackupRunStage.interrupted
                  : AutomaticBackupRunStage.failed,
              startedAt: now,
              finishedAt: DateTime.now(),
              fileName: stored?.name,
              bytes: stored?.size,
              failure: automaticBackupFailure(
                error,
                fileCreated: stored != null,
              ),
            ),
          );
        } catch (_) {
          // Preserve the original failure if device status storage also fails.
        }
      }
      rethrow;
    }
  }
}

class AutomaticBackupLifecycle extends ConsumerStatefulWidget {
  const AutomaticBackupLifecycle({super.key, required this.child});
  final Widget child;
  @override
  ConsumerState<AutomaticBackupLifecycle> createState() =>
      _AutomaticBackupLifecycleState();
}

class _AutomaticBackupLifecycleState
    extends ConsumerState<AutomaticBackupLifecycle>
    with WidgetsBindingObserver {
  Timer? _timer;
  bool _foreground = true;
  @override
  void initState() {
    super.initState();
    _foreground =
        WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _configure();
    });
  }

  void _configure() {
    _timer?.cancel();
    _timer = null;
    if (_foreground && ref.read(automaticBackupPolicyProvider).hours > 0) {
      _check();
      _timer = Timer.periodic(const Duration(minutes: 1), (_) => _check());
    }
  }

  void _check() => unawaited(
    ref.read(automaticBackupSchedulerProvider).check(DateTime.now()).catchError(
      (Object e) {
        debugPrint('Automatic backup: $e');
        return null;
      },
    ),
  );
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _configure();
  }

  @override
  void dispose() {
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(
      appLockProvider.select(
        (lock) => (lock.initialized, lock.locked, lock.configurationValid),
      ),
      (_, _) => _configure(),
    );
    ref.listen(extensionRecoveryProvider, (previous, next) {
      if (previous?.hasValue != true && next.hasValue) _configure();
    });
    ref.listen(automaticBackupPolicyProvider, (_, _) => _configure());
    return widget.child;
  }
}
