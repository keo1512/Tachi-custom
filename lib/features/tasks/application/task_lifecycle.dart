import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../downloads/presentation/download_queue_controller.dart';
import '../../library/presentation/library_view_model.dart';
import '../../library/application/extension_recovery_controller.dart';
import '../../library/application/library_update_policy.dart';
import '../../library/application/library_update_report.dart';
import '../../library/application/library_update_scheduler.dart';
import '../../privacy/application/app_lock_controller.dart';
import '../../settings/settings_controller.dart';
import '../data/task_platform.dart';
import 'task_notifications.dart';

/// Finite execution windows. iOS decides whether a deferred processing request
/// receives time; every granted window runs the same durable guarded queue.
class TaskLifecycle extends ConsumerStatefulWidget {
  const TaskLifecycle({super.key, required this.child});
  final Widget child;
  @override
  ConsumerState<TaskLifecycle> createState() => _TaskLifecycleState();
}

class _TaskLifecycleState extends ConsumerState<TaskLifecycle>
    with WidgetsBindingObserver {
  late TaskPlatform platform;
  late LibraryUpdateExecutionGate updateGate;
  StreamSubscription<void>? expiration;
  StreamSubscription<void>? continuedExpiration;
  StreamSubscription<int>? scheduled;
  StreamSubscription<void>? updateExecutions;
  bool background = false, leased = false, expired = false, disposed = false;
  bool stoppedNoticeSent = false, suspending = false, privateSession = false;
  int? sessionPrivacyGeneration;
  int? scheduledToken;
  bool startingScheduled = false;
  bool scheduledUpdateRunning = false;
  bool updateWasWorking = false;
  Future<void> pending = Future.value();
  @override
  void initState() {
    super.initState();
    platform = ref.read(taskPlatformProvider);
    updateGate = ref.read(libraryUpdateExecutionProvider);
    background =
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.paused;
    if (background) updateGate.hold();
    updateExecutions = updateGate.changes.listen((_) {
      if (!mounted) return;
      if (updateGate.hasWork && !updateWasWorking) {
        sessionPrivacyGeneration = ref
            .read(taskNotificationsProvider.notifier)
            .privacyGeneration;
        privateSession = ref.read(settingsProvider).incognitoMode;
      }
      updateWasWorking = updateGate.hasWork;
      reconcile();
    });
    WidgetsBinding.instance.addObserver(this);
    if (platform case final ContinuedTaskPlatform native) {
      continuedExpiration = native.continuedProcessingExpired.listen((_) {
        if (!mounted) return;
        expired = true;
        leased = false;
        unawaited(_suspend(continued: true));
      });
    }
    expiration = platform.backgroundExpired.listen((_) {
      // A native callback already queued before resume must not pause a new
      // foreground execution after its lease has been ended.
      if (!background || !mounted) return;
      expired = true;
      leased = false;
      if (mounted) unawaited(_suspend());
    });
    if (platform case final BackgroundTaskPlatform native) {
      scheduled = native.scheduledBackground.listen(_resumeScheduled);
      // Subscribe before acknowledging readiness, including a cold native task
      // waiting for the existing application engine to initialize.
      unawaited(native.backgroundReady().catchError((Object _) {}));
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) reconcile();
    });
  }

  void _resumeScheduled(int token) {
    if (!mounted || scheduledToken != null || !background) {
      if (platform case final BackgroundTaskPlatform native) {
        unawaited(
          native
              .completeScheduledBackground(token, success: false)
              .catchError((Object _) {}),
        );
      }
      return;
    }
    scheduledToken = token;
    startingScheduled = true;
    expired = false;
    stoppedNoticeSent = false;
    unawaited(() async {
      try {
        await ref.read(appLockProvider.notifier).initialize();
        if (!mounted || scheduledToken != token || !background || expired) {
          return;
        }
        final lock = ref.read(appLockProvider);
        if (!lock.initialized || !lock.configurationValid || lock.locked) {
          await _finishScheduled(success: false);
          return;
        }
        if (ref.read(settingsProvider).incognitoMode) {
          await _finishScheduled(success: false);
          return;
        }
        await ref.read(extensionRecoveryProvider.future);
        if (!mounted || scheduledToken != token || !background || expired) {
          return;
        }
        await ref.read(libraryProvider.future);
        if (!mounted || scheduledToken != token || !background || expired) {
          return;
        }
        updateGate
            .allow(); // The BGProcessingTask is the existing native grant.
        var updatesHandled = false;
        if (ref.read(libraryUpdatePolicyProvider).hours > 0 &&
            !ref.read(settingsProvider).incognitoMode) {
          scheduledUpdateRunning = true;
          reconcile();
          try {
            await ref
                .read(libraryUpdateSchedulerProvider)
                .check(DateTime.now());
            updatesHandled = true;
          } finally {
            scheduledUpdateRunning = false;
          }
        }
        if (!mounted || scheduledToken != token || !background || expired) {
          return;
        }
        final queue = ref.read(downloadQueueProvider);
        if (queue.storageError != null ||
            ref.read(settingsProvider).incognitoMode) {
          await _finishScheduled(success: false);
          return;
        }
        if (!queue.tasks.any(
          (job) =>
              job.status == DownloadJobStatus.pending ||
              job.status == DownloadJobStatus.active,
        )) {
          await _finishScheduled(success: updatesHandled);
          return;
        }
        await ref.read(downloadQueueProvider.notifier).start();
      } catch (_) {
        if (mounted && scheduledToken == token) {
          await _finishScheduled(success: false);
        }
      } finally {
        startingScheduled = false;
        if (mounted) reconcile();
      }
    }());
  }

  Future<void> _finishScheduled({required bool success}) async {
    final token = scheduledToken;
    scheduledToken = null;
    if (token != null && background && !expired) updateGate.hold();
    if (token != null && platform is BackgroundTaskPlatform) {
      await (platform as BackgroundTaskPlatform).completeScheduledBackground(
        token,
        success: success,
      );
    }
  }

  Future<void> _suspend({bool continued = false}) async {
    if (!mounted || suspending) return;
    if (!continued) updateGate.expire();
    final before = ref.read(downloadQueueProvider);
    if (!before.running &&
        !before.tasks.any((task) => task.status == DownloadJobStatus.active)) {
      await _finishScheduled(success: false);
      return;
    }
    suspending = true;
    try {
      await ref
          .read(downloadQueueProvider.notifier)
          .suspendForBackground(
            reason: continued
                ? 'Tác vụ tải nền đã dừng. Bấm Tiếp tục để tải tiếp.'
                : null,
          );
    } catch (_) {
      // The queue retains its durable entries and exposes its storage error.
    } finally {
      suspending = false;
    }
    await _finishScheduled(success: false);
    if (!mounted || stoppedNoticeSent) return;
    stoppedNoticeSent = true;
    // The native lease owns this notice when it has a pre-expiration snapshot.
    // Posting from Dart as well would duplicate it and depend on Dart uptime.
    if (platform is BackgroundTaskPlatform) return;
    final after = ref.read(downloadQueueProvider);
    await ref
        .read(taskNotificationsProvider.notifier)
        .pausedDownloads(
          after.tasks
              .where(
                (job) =>
                    job.status == DownloadJobStatus.pending ||
                    job.status == DownloadJobStatus.active,
              )
              .length,
          after.tasks
              .where((job) => job.status == DownloadJobStatus.failed)
              .length,
          privateSession: privateSession,
          expectedPrivacyGeneration: sessionPrivacyGeneration,
        );
  }

  void reconcile() {
    pending = pending
        .then((_) async {
          if (disposed || !mounted) return;
          if (startingScheduled && !scheduledUpdateRunning) return;
          final queue = ref.read(downloadQueueProvider);
          final update = ref.read(libraryUpdateProgressProvider);
          final updateWorking =
              update != null || scheduledUpdateRunning || updateGate.hasWork;
          final working =
              queue.running ||
              updateWorking ||
              queue.tasks.any(
                (task) => task.status == DownloadJobStatus.active,
              );
          if (working && sessionPrivacyGeneration == null) {
            sessionPrivacyGeneration = ref
                .read(taskNotificationsProvider.notifier)
                .privacyGeneration;
            privateSession = ref.read(settingsProvider).incognitoMode;
          }
          if (platform case final BackgroundTaskPlatform native) {
            final pendingCount = queue.tasks
                .where(
                  (job) =>
                      job.status == DownloadJobStatus.pending ||
                      job.status == DownloadJobStatus.active,
                )
                .length;
            final failedCount = queue.tasks
                .where((job) => job.status == DownloadJobStatus.failed)
                .length;
            final resumeRequested =
                !privateSession &&
                !ref.read(settingsProvider).incognitoMode &&
                queue.storageError == null &&
                (queue.running ||
                    (expired && queue.pauseReason?.startsWith('iOS') == true));
            // Wait for the native snapshot before acquiring a lease. There is
            // then no dependency on Dart to construct an expiry notification.
            final noticeAllowed = ref
                .read(taskNotificationsProvider.notifier)
                .allowsBackgroundSummary(
                  privateSession: privateSession,
                  expectedPrivacyGeneration: sessionPrivacyGeneration,
                );
            if (platform case final BackgroundLibraryUpdatePlatform updates) {
              final policy = ref.read(libraryUpdatePolicyProvider);
              final lock = ref.read(appLockProvider);
              final updateAllowed =
                  !privateSession &&
                  !ref.read(settingsProvider).incognitoMode &&
                  lock.initialized &&
                  lock.configurationValid &&
                  !lock.locked;
              final last = ref
                  .read(preferencesProvider)
                  .getInt('libraryLastAutomaticUpdate');
              await updates.updateBackgroundWorkSnapshot(
                pending: pendingCount,
                failed: failedCount,
                notifyOnPause: resumeRequested && noticeAllowed,
                resumeRequested: resumeRequested,
                updatesRequested: updateAllowed && policy.hours > 0,
                updateEarliestMillis: last == null
                    ? 0
                    : last + Duration(hours: policy.hours).inMilliseconds,
                updateRemaining: update == null
                    ? 0
                    : (update.requestedBooks - update.processedBooks).clamp(
                        0,
                        1000000,
                      ),
                updateFailed: update?.failedBooks ?? 0,
                notifyUpdatePause:
                    updateAllowed && noticeAllowed && updateWorking,
              );
              if (background && updateWorking && !updateAllowed) {
                updateGate.expire();
              }
            } else {
              await native.updateBackgroundSnapshot(
                pending: pendingCount,
                failed: failedCount,
                notifyOnPause: resumeRequested && noticeAllowed,
                resumeRequested: resumeRequested,
              );
            }
            if (disposed || !mounted) return;
          }
          if (scheduledToken != null) {
            if (!background || !working) {
              await _finishScheduled(
                success: queue.tasks.isEmpty && queue.storageError == null,
              );
            } else {
              if (!expired) updateGate.allow();
              return; // The BGProcessingTask itself owns the execution window.
            }
          }
          if (!background || !working) {
            if (leased) await platform.endBackground();
            leased = false;
            if (background && !expired) updateGate.hold();
          } else if (!leased && !expired) {
            final granted = await platform.beginBackground();
            if (disposed || !mounted || !background || expired) {
              if (granted) await platform.endBackground();
              if (mounted && background && expired) await _suspend();
              return;
            }
            leased = granted;
            if (granted) updateGate.allow();
            if (!granted) {
              expired = true;
              await _suspend();
            }
          } else if (expired && working) {
            await _suspend();
          }
        })
        .catchError((Object _) async {
          if (mounted && background) {
            expired = true;
            await _suspend();
          }
        });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      background = true;
      updateGate.hold();
    } else if (state == AppLifecycleState.resumed) {
      background = false;
      expired = false;
      stoppedNoticeSent = false;
      updateGate.allow();
    } else {
      return;
    }
    reconcile();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(downloadQueueProvider, (previous, next) {
      if (next.running && previous?.running != true) {
        sessionPrivacyGeneration = ref
            .read(taskNotificationsProvider.notifier)
            .privacyGeneration;
        privateSession = ref.read(settingsProvider).incognitoMode;
      }
      reconcile();
    });
    ref.listen(libraryUpdateProgressProvider, (previous, next) {
      if (next != null && previous == null) {
        sessionPrivacyGeneration = ref
            .read(taskNotificationsProvider.notifier)
            .privacyGeneration;
        privateSession = ref.read(settingsProvider).incognitoMode;
      }
      reconcile();
    });
    ref.listen(libraryUpdatePolicyProvider, (_, _) => reconcile());
    ref.listen(appLockProvider, (_, state) {
      if (background && state.locked) updateGate.expire();
      reconcile();
    });
    ref.listen(settingsProvider.select((settings) => settings.incognitoMode), (
      _,
      value,
    ) {
      if (value) {
        privateSession = true;
        if (background) updateGate.expire();
        unawaited(platform.clearNotifications().catchError((Object _) {}));
      }
      reconcile();
    });
    ref.listen(taskNotificationsProvider, (_, _) => reconcile());
    return widget.child;
  }

  @override
  void dispose() {
    disposed = true;
    updateGate.expire();
    WidgetsBinding.instance.removeObserver(this);
    unawaited(expiration?.cancel());
    unawaited(continuedExpiration?.cancel());
    unawaited(scheduled?.cancel());
    unawaited(updateExecutions?.cancel());
    unawaited(_finishScheduled(success: false).catchError((Object _) {}));
    unawaited(platform.endBackground().catchError((Object _) {}));
    super.dispose();
  }
}
