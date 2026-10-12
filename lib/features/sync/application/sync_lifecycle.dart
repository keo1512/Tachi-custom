import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../library/presentation/library_view_model.dart';
import '../../library/application/backup_service_provider.dart';
import '../../library/application/extension_recovery_controller.dart';
import '../../privacy/application/app_lock_controller.dart';
import 'sync_controller.dart';
import '../data/sync_platform.dart';

/// Opt-in sync while the app can execute. The system's network path is a retry
/// signal, never proof that Firebase is reachable. All requests stay throttled.
class SyncLifecycle extends ConsumerStatefulWidget {
  const SyncLifecycle({super.key, required this.child});
  final Widget child;
  @override
  ConsumerState<SyncLifecycle> createState() => _SyncLifecycleState();
}

class _SyncLifecycleState extends ConsumerState<SyncLifecycle>
    with WidgetsBindingObserver {
  Timer? _timer;
  Timer? _periodic;
  StreamSubscription<bool>? _network;
  bool? _connected;
  bool _foreground = true;
  bool _dirty = false;
  int _changeGeneration = 0;

  @override
  void initState() {
    super.initState();
    _foreground =
        WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    WidgetsBinding.instance.addObserver(this);
    _network = ref
        .read(syncConnectivityProvider)
        .listen(
          (connected) {
            final restored = _connected == false && connected;
            _connected = connected;
            if (!connected) {
              _timer?.cancel();
              return;
            }
            if (restored && mounted && _foreground) {
              _dirty = true;
              _changeGeneration++;
              _schedule();
            }
          },
          onError: (Object _) {
            /* No network capability is not a cloud failure. */
          },
        );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_resume());
    });
  }

  Future<void> _runPending(Future<void> Function() action) async {
    await ref.read(appLockProvider.notifier).initialize();
    if (!mounted || !_foreground || !_unlocked) return;
    try {
      await ref.read(extensionRecoveryProvider.future);
    } catch (_) {
      // The recovery screen exposes the saved package plan and explicit retry.
      // Do not upload a partially restored runtime or initialize it repeatedly.
      return;
    }
    if (!mounted || !_foreground || !_unlocked) return;
    final controller = ref.read(syncProvider.notifier);
    final completed = controller.completedRuns;
    final generation = _changeGeneration;
    await action();
    if (!mounted) return;
    if (controller.completedRuns != completed &&
        generation == _changeGeneration) {
      _dirty = false;
    }
    // Errors wait for a network transition, foreground resume or the bounded
    // periodic check; never retry a failed upload in a tight loop.
    if (!ref.read(syncProvider).error) _schedule();
  }

  Future<void> _resume() =>
      _runPending(() => ref.read(syncProvider.notifier).resume());

  bool get _unlocked {
    final lock = ref.read(appLockProvider);
    return lock.initialized && lock.configurationValid && !lock.locked;
  }

  void _schedule() {
    _timer?.cancel();
    final sync = ref.read(syncProvider);
    if (!_dirty ||
        !_foreground ||
        !_unlocked ||
        sync.user == null ||
        !sync.enabled ||
        sync.conflict ||
        _connected == false) {
      return;
    }
    final controller = ref.read(syncProvider.notifier);
    final remaining = controller.automaticSyncDelay;
    final delay = remaining > const Duration(seconds: 6)
        ? remaining
        : const Duration(seconds: 6);
    _timer = Timer(delay, () {
      if (!mounted || !_foreground || !_unlocked || _connected == false) return;
      final current = ref.read(syncProvider);
      if (current.busy || controller.automaticSyncDelay > Duration.zero) {
        _schedule();
        return;
      }
      if (current.user == null || !current.enabled || current.conflict) return;
      unawaited(_runPending(() => controller.sync(automatic: true)));
    });
  }

  void _schedulePeriodic() {
    _periodic?.cancel();
    final state = ref.read(syncProvider);
    if (!_foreground ||
        !_unlocked ||
        !state.enabled ||
        state.user == null ||
        state.conflict) {
      return;
    }
    _periodic = Timer(const Duration(minutes: 15), () {
      if (!mounted || !_foreground) return;
      _dirty = true;
      _changeGeneration++;
      _schedule();
      _schedulePeriodic();
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _timer?.cancel();
    _schedulePeriodic();
    if (_foreground) {
      unawaited(_resume());
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(extensionRecoveryProvider, (previous, next) {
      if (next.hasError) {
        _timer?.cancel();
        _periodic?.cancel();
      } else if (previous?.hasValue != true &&
          next.hasValue &&
          _foreground &&
          _unlocked) {
        unawaited(_resume());
        _schedulePeriodic();
      }
    });
    ref.listen(
      appLockProvider.select(
        (lock) => (lock.initialized, lock.locked, lock.configurationValid),
      ),
      (_, _) {
        _timer?.cancel();
        _periodic?.cancel();
        if (_foreground && _unlocked) {
          unawaited(_resume());
          _schedulePeriodic();
        }
      },
    );
    ref.listen(configurationChangesProvider, (previous, next) {
      if (previous?.hasValue == true &&
          next.hasValue &&
          previous!.value != next.value) {
        _dirty = true;
        _changeGeneration++;
        _schedule();
      }
    });
    ref.listen(libraryProvider, (previous, next) {
      if (previous?.hasValue == true && next.hasValue && next != previous) {
        _dirty = true;
        _changeGeneration++;
        _schedule();
      }
    });
    ref.listen(
      syncProvider.select(
        (state) => (state.user?.uid, state.enabled, state.conflict),
      ),
      (_, _) {
        _schedule();
        _schedulePeriodic();
      },
    );
    return widget.child;
  }

  @override
  void dispose() {
    _timer?.cancel();
    _periodic?.cancel();
    unawaited(_network?.cancel());
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}
