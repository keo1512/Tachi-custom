import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../downloads/presentation/download_queue_controller.dart';
import '../../library/application/automatic_backup_status.dart';
import '../../library/application/automatic_backup_controller.dart';
import '../../library/application/library_update_report.dart';
import '../../library/data/coordinated_preferences.dart';
import '../../library/presentation/library_view_model.dart';
import '../../privacy/application/app_lock_controller.dart';
import '../../settings/settings_controller.dart';
import '../data/task_platform.dart';
import '../domain/continued_work.dart';

final continuedWorkCoordinatorProvider = Provider<ContinuedWorkCoordinator>((
  ref,
) {
  final owner = ContinuedWorkCoordinator(ref);
  ref.onDispose(owner.dispose);
  return owner;
});

/// Numeric progress before a sequence is assigned at the actual send boundary.
class ContinuedWorkProgress {
  const ContinuedWorkProgress(
    this.operation,
    this.state,
    this.completed,
    this.total,
    this.failed,
    this.sessionId,
  );
  final ContinuedWorkOperation operation;
  final ContinuedWorkState state;
  final int completed, total, failed;
  final String sessionId;
  String get identity =>
      '${operation.name}/${state.name}/$completed/$total/$failed/$sessionId';
  ContinuedWork sequence(int value) => ContinuedWork(
    operation: operation,
    state: state,
    completed: completed,
    total: total,
    failed: failed,
    sequence: value,
    sessionId: sessionId,
  );
}

/// One serial presentation channel. Frequent counts coalesce per session;
/// terminal states remain ahead of a subsequent session. Privacy removal is
/// immediate and invalidates an in-flight response before any await.
class _PendingActivity {
  const _PendingActivity(this.progress, this.isCurrent);
  final ContinuedWorkProgress progress;
  final bool Function()? isCurrent;
  bool get valid => isCurrent?.call() ?? true;
}

class ContinuedWorkDriver {
  ContinuedWorkDriver(this.platform);
  final ContinuedWorkPlatform? platform;
  static int _sequence = 0;
  int _epoch = 0;
  int _resumeEpoch = 0;
  bool _sending = false, _disposed = false;
  String? _last;
  _PendingActivity? _latest;
  final _pending = <_PendingActivity>[];
  ContinuedWorkResult result = const ContinuedWorkResult();
  // Reserve the final bounded sequence exclusively for privacy removal.
  int? _next({bool privacy = false}) =>
      _sequence < (privacy ? 1000000 : 999999) ? ++_sequence : null;

  void show(
    ContinuedWorkProgress progress, {
    bool retryDeferred = false,
    bool Function()? isCurrent,
  }) {
    if (_disposed ||
        platform == null ||
        (!retryDeferred && _last == progress.identity)) {
      return;
    }
    _last = progress.identity;
    final pending = _PendingActivity(progress, isCurrent);
    _latest = pending;
    if (_pending.isNotEmpty &&
        _pending.last.progress.sessionId == progress.sessionId &&
        _pending.last.progress.state == ContinuedWorkState.running) {
      _pending[_pending.length - 1] = pending;
    } else {
      // Bound presentation memory if native is unresponsive for many sessions.
      if (_pending.length == 16) _pending.removeAt(0);
      _pending.add(pending);
    }
    if (!_sending) unawaited(_drain());
  }

  Future<void> _drain() async {
    _sending = true;
    try {
      while (!_disposed && _pending.isNotEmpty) {
        final pending = _pending.removeAt(0), epoch = _epoch;
        final progress = pending.progress, resumeEpoch = _resumeEpoch;
        if (!pending.valid) {
          clear();
          continue;
        }
        final sequence = _next();
        if (sequence == null) {
          _pending.clear();
          return;
        }
        try {
          final value = await platform!.updateContinuedWork(
            progress.sequence(sequence),
          );
          if (_disposed || epoch != _epoch) continue;
          if (!pending.valid) {
            clear();
            continue;
          }
          result = value;
          if (value.deferred &&
              _resumeEpoch > resumeEpoch &&
              progress.state == ContinuedWorkState.running &&
              _pending.isEmpty) {
            final latest = _latest;
            if (latest != null && latest.valid) {
              show(
                latest.progress,
                retryDeferred: true,
                isCurrent: latest.isCurrent,
              );
            }
          }
        } catch (_) {
          // Presentation can never retry, cancel or fail an execution.
        }
        if (!_disposed && epoch == _epoch && !pending.valid) {
          clear();
          continue;
        }
        if (!_disposed &&
            epoch == _epoch &&
            pending.valid &&
            progress.state != ContinuedWorkState.running) {
          final endSequence = _next();
          if (endSequence != null) {
            try {
              await platform!.endContinuedWork(
                sequence: endSequence,
                immediate: false,
              );
            } catch (_) {}
          }
        }
      }
    } finally {
      _sending = false;
    }
  }

  void clear() {
    _epoch++;
    _last = null;
    _latest = null;
    result = const ContinuedWorkResult();
    _pending.clear();
    final sequence = _next(privacy: true);
    if (platform == null || sequence == null) return;
    try {
      unawaited(
        platform!
            .endContinuedWork(sequence: sequence, immediate: true)
            .catchError((Object _) => const ContinuedWorkResult()),
      );
    } catch (_) {}
  }

  void resumed() {
    _resumeEpoch++;
    final latest = _latest;
    if (!_disposed &&
        result.deferred &&
        latest != null &&
        latest.valid &&
        latest.progress.state == ContinuedWorkState.running) {
      show(latest.progress, retryDeferred: true, isCurrent: latest.isCurrent);
    }
  }

  void dispose() {
    if (_disposed) return;
    clear();
    _disposed = true;
  }
}

class _Run {
  _Run(this.operation, this.revision, this.generation, {required this.private});
  final ContinuedWorkOperation operation;
  final int revision;
  final int? generation;
  final String id = base64UrlEncode(
    List<int>.generate(18, (_) => Random.secure().nextInt(256)),
  );
  bool private, active = true;
  int completed = 0, total = 1, failed = 0;
  final identities = <String>{};
  ContinuedWorkState terminal = ContinuedWorkState.paused;
  ContinuedWorkProgress progress([ContinuedWorkState? state]) =>
      ContinuedWorkProgress(
        operation,
        state ?? ContinuedWorkState.running,
        completed,
        total,
        failed,
        id,
      );
}

/// Observes the application's existing executors. It owns no queue, container,
/// timer or lease, including when the app starts with no visible Flutter view.
class ContinuedWorkCoordinator with WidgetsBindingObserver {
  ContinuedWorkCoordinator(this.ref) {
    final platform = ref.read(taskPlatformProvider);
    driver = ContinuedWorkDriver(
      platform is ContinuedWorkPlatform
          ? platform as ContinuedWorkPlatform
          : null,
    );
    if (platform is! ContinuedWorkPlatform) return;
    _expiry = (platform as ContinuedWorkPlatform).continuedWorkExpired.listen(
      _expired,
    );
    // Claim the generic native owner before any queue or scheduler can emit a
    // legacy page-progress request, including an automatic foreground launch.
    driver.clear();
    ref.listen(downloadQueueProvider, (_, next) => _downloads(next));
    ref.listen(libraryUpdateProgressProvider, (_, next) {
      if (next != null && next.requestedBooks <= 0) return;
      if (next != null) {
        final run = _activeRun(ContinuedWorkOperation.updates);
        if (!next.userInitiated) run.private = true;
        run.total = next.requestedBooks.clamp(1, 1000000);
        run.completed = next.processedBooks.clamp(0, run.total);
        run.failed = next.failedBooks.clamp(0, run.completed);
      } else {
        final run = _runs[ContinuedWorkOperation.updates];
        if (run != null) {
          run.active = false;
          run.terminal = run.completed < run.total
              ? ContinuedWorkState.paused
              : run.failed > 0
              ? ContinuedWorkState.failed
              : ContinuedWorkState.completed;
        }
      }
      _reconcile();
    }, fireImmediately: true);
    ref.listen(automaticBackupStatusProvider, (_, next) {
      if (next.stage == AutomaticBackupRunStage.running) {
        final run = _activeRun(ContinuedWorkOperation.backup);
        if (!next.userInitiated) run.private = true;
      } else {
        final run = _runs[ContinuedWorkOperation.backup];
        if (run != null && run.active) {
          run.active = false;
          run.completed = next.stage == AutomaticBackupRunStage.interrupted
              ? 0
              : 1;
          run.failed = next.stage == AutomaticBackupRunStage.failed ? 1 : 0;
          run.terminal = switch (next.stage) {
            AutomaticBackupRunStage.succeeded => ContinuedWorkState.completed,
            AutomaticBackupRunStage.failed => ContinuedWorkState.failed,
            _ => ContinuedWorkState.paused,
          };
        }
      }
      _reconcile();
    }, fireImmediately: true);
    ref.listen(settingsProvider.select((value) => value.incognitoMode), (
      _,
      value,
    ) {
      if (value) _invalidateRuns();
      _reconcile();
    });
    ref.listen(appLockProvider, (_, next) {
      if (!_unlocked(next)) _invalidateRuns();
      _reconcile();
    });
    final preferences = ref.read(preferencesProvider);
    if (preferences is CoordinatedPreferences) {
      _mutations = preferences.mutationChanges.listen((_) => _invalidateRuns());
      _publications = preferences.changes.listen((_) => _reconcile());
    }
    WidgetsBinding.instance.addObserver(this);
    // Observe a run already active when this owner is first retained.
    _downloads(ref.read(downloadQueueProvider));
  }

  final Ref ref;
  late final ContinuedWorkDriver driver;
  final _runs = <ContinuedWorkOperation, _Run>{};
  StreamSubscription<int>? _mutations, _publications;
  StreamSubscription<ContinuedWorkExpiry>? _expiry;
  _Run? _shown;
  bool _disposed = false, _watchingLibrary = false;
  bool _unlocked(AppLockState value) =>
      value.initialized &&
      value.configurationValid &&
      !value.locked &&
      !value.authenticating;
  int? get _generation {
    final preferences = ref.read(preferencesProvider);
    return preferences is CoordinatedPreferences
        ? preferences.mutationGeneration
        : null;
  }

  bool get _restoring {
    final preferences = ref.read(preferencesProvider);
    return preferences is CoordinatedPreferences && preferences.restoring;
  }

  bool get _allowed =>
      !_disposed &&
      ref.mounted &&
      !ref.read(settingsProvider).incognitoMode &&
      !_restoring &&
      _unlocked(ref.read(appLockProvider));

  _Run _activeRun(ContinuedWorkOperation operation) {
    final existing = _runs[operation];
    if (existing != null && existing.active) return existing;
    return _runs[operation] = _Run(
      operation,
      ref.read(libraryRepositoryProvider).replacementRevision,
      _generation,
      private:
          ref.read(settingsProvider).incognitoMode ||
          _restoring ||
          !_unlocked(ref.read(appLockProvider)),
    );
  }

  void _downloads(DownloadQueueState queue) {
    final working = queue.tasks.any(
      (job) =>
          job.status == DownloadJobStatus.active ||
          (queue.running && job.status == DownloadJobStatus.pending),
    );
    var run = _runs[ContinuedWorkOperation.downloads];
    if (working) run = _activeRun(ContinuedWorkOperation.downloads);
    if (run == null) return;
    if (run.active) {
      if (!ref
          .read(downloadQueueProvider.notifier)
          .continuedWorkUserInitiated) {
        run.private = true;
      }
      run.identities.addAll(queue.tasks.map((job) => job.identity));
      run.total = run.identities.length.clamp(1, 1000000);
      final remaining = queue.tasks
          .where((job) => run!.identities.contains(job.identity))
          .toList();
      run.failed = remaining
          .where((job) => job.status == DownloadJobStatus.failed)
          .length
          .clamp(0, run.total);
      run.completed =
          (ref.read(downloadQueueProvider.notifier).completedChaptersInRun +
                  run.failed)
              .clamp(0, run.total);
      if (!working) {
        run.active = false;
        run.terminal = queue.storageError != null
            ? ContinuedWorkState.failed
            : run.completed < run.total
            ? ContinuedWorkState.paused
            : run.failed > 0
            ? ContinuedWorkState.failed
            : ContinuedWorkState.completed;
      }
    }
    _reconcile();
  }

  void _invalidateRuns() {
    for (final run in _runs.values) {
      run.private = true;
    }
    _shown = null;
    driver.clear();
  }

  void _reconcile({bool retryDeferred = false}) {
    if (_disposed || !ref.mounted) return;
    if (!_allowed) {
      if (_shown != null) _invalidateRuns();
      return;
    }
    if (!_watchingLibrary) {
      _watchingLibrary = true;
      ref.listen(libraryProvider, (_, _) => _reconcile());
    }
    final revision = ref.read(libraryRepositoryProvider).replacementRevision;
    for (final run in _runs.values) {
      if (run.revision != revision || run.generation != _generation) {
        run.private = true;
      }
    }
    final shown = _shown;
    if (shown != null && !shown.active && !shown.private) {
      driver.show(
        shown.progress(shown.terminal),
        isCurrent: () => _validRun(shown),
      );
      _shown = null;
    } else if (shown?.private == true) {
      _shown = null;
      driver.clear();
    }
    // An accepted OS grant belongs to one concrete session. Keep it until its
    // executor stops: a background replacement cannot obtain a fresh grant.
    if (shown != null && shown.active && !shown.private) {
      driver.show(
        shown.progress(),
        retryDeferred: retryDeferred,
        isCurrent: () => _validRun(shown),
      );
      return;
    }
    for (final operation in ContinuedWorkOperation.values) {
      final run = _runs[operation];
      if (run != null && run.active && !run.private) {
        _shown = run;
        driver.show(
          run.progress(),
          retryDeferred: retryDeferred,
          isCurrent: () => _validRun(run),
        );
        return;
      }
    }
  }

  bool _validRun(_Run run) {
    if (!_allowed || run.private) return false;
    if (run.revision !=
            ref.read(libraryRepositoryProvider).replacementRevision ||
        run.generation != _generation) {
      run.private = true;
      return false;
    }
    return true;
  }

  void _expired(ContinuedWorkExpiry event) {
    if (_disposed || !ref.mounted) return;
    final run = _shown;
    if (run == null ||
        !run.active ||
        run.operation != event.operation ||
        run.id != event.sessionId) {
      return;
    }
    // Keep this run latched until its existing executor publishes idle. A late
    // response must not create a replacement request after the system's Stop.
    run.private = true;
    _shown = null;
    driver.clear();
    switch (event.operation) {
      case ContinuedWorkOperation.downloads:
        unawaited(
          ref
              .read(downloadQueueProvider.notifier)
              .suspendForBackground(
                reason: 'Tác vụ nền đã dừng. Bấm Tiếp tục để tải tiếp.',
              )
              .catchError((Object _) {}),
        );
      case ContinuedWorkOperation.updates:
        ref.read(libraryUpdateExecutionProvider).stopForUser();
      case ContinuedWorkOperation.backup:
        ref.read(automaticBackupExecutionProvider).stopForUser();
    }
    _reconcile();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _reconcile();
      driver.resumed();
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_mutations?.cancel());
    unawaited(_publications?.cancel());
    unawaited(_expiry?.cancel());
    driver.dispose();
  }
}
