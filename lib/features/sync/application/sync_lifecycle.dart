import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../library/presentation/library_view_model.dart';
import 'sync_controller.dart';

/// Opt-in foreground sync only. No periodic idle polling or background claim.
class SyncLifecycle extends ConsumerStatefulWidget {
  const SyncLifecycle({super.key, required this.child});
  final Widget child;
  @override
  ConsumerState<SyncLifecycle> createState() => _SyncLifecycleState();
}

class _SyncLifecycleState extends ConsumerState<SyncLifecycle>
    with WidgetsBindingObserver {
  Timer? _timer;
  bool _foreground = true;
  bool _dirty = false;
  int _changeGeneration = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_resume());
    });
  }

  Future<void> _runPending(Future<void> Function() action) async {
    final controller = ref.read(syncProvider.notifier);
    final completed = controller.completedRuns;
    final generation = _changeGeneration;
    await action();
    if (!mounted) return;
    if (controller.completedRuns != completed &&
        generation == _changeGeneration) {
      _dirty = false;
    }
    // A rejected/throttled request remains pending. Network errors wait for a
    // new edit or foreground resume, instead of generating idle retry polling.
    if (!ref.read(syncProvider).error) _schedule();
  }

  Future<void> _resume() =>
      _runPending(() => ref.read(syncProvider.notifier).resume());

  void _schedule() {
    _timer?.cancel();
    final sync = ref.read(syncProvider);
    if (!_dirty ||
        !_foreground ||
        sync.user == null ||
        !sync.enabled ||
        sync.conflict) {
      return;
    }
    final controller = ref.read(syncProvider.notifier);
    final remaining = controller.automaticSyncDelay;
    final delay = remaining > const Duration(seconds: 6)
        ? remaining
        : const Duration(seconds: 6);
    _timer = Timer(delay, () {
      if (!mounted || !_foreground) return;
      final current = ref.read(syncProvider);
      if (current.busy || controller.automaticSyncDelay > Duration.zero) {
        _schedule();
        return;
      }
      if (current.user == null || !current.enabled || current.conflict) return;
      unawaited(_runPending(() => controller.sync(automatic: true)));
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _timer?.cancel();
    if (_foreground) {
      unawaited(_resume());
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(libraryProvider, (previous, next) {
      if (previous?.hasValue == true && next.hasValue && next != previous) {
        _dirty = true;
        _changeGeneration++;
        _schedule();
      }
    });
    ref.listen(
      syncProvider.select((state) => (state.user?.uid, state.enabled)),
      (_, _) => _schedule(),
    );
    return widget.child;
  }

  @override
  void dispose() {
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}
