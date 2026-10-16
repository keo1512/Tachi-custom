import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../application/app_lock_controller.dart';

/// Keeps the existing routes alive while blocking input and accessibility behind
/// the lock. UIKit's tab bar is hidden separately by the app navigation owner.
class PrivacyGate extends ConsumerStatefulWidget {
  const PrivacyGate({super.key, required this.child});
  final Widget child;

  @override
  ConsumerState<PrivacyGate> createState() => _PrivacyGateState();
}

class _PrivacyGateState extends ConsumerState<PrivacyGate>
    with WidgetsBindingObserver {
  Timer? _retryTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    HardwareKeyboard.instance.addHandler(_keyActivity);
    unawaited(
      ref.read(appLockProvider.notifier).initialize().then((_) {
        if (mounted) _foregroundReady();
      }),
    );
  }

  void _foregroundReady() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        unawaited(ref.read(appLockProvider.notifier).foregroundReady());
      }
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  bool _keyActivity(KeyEvent _) {
    if (mounted) ref.read(appLockProvider.notifier).recordActivity();
    return false;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    ref.read(appLockProvider.notifier).lifecycle(state);
    if (state == AppLifecycleState.resumed) _foregroundReady();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    HardwareKeyboard.instance.removeHandler(_keyActivity);
    _retryTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(appLockProvider);
    final retryAfter = state.retryAfter;
    final remaining = retryAfter == null
        ? 0
        : retryAfter.difference(ref.read(privacyClockProvider)()).inSeconds + 1;
    if (remaining > 0 && _retryTimer == null) {
      _retryTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() {});
      });
    } else if (remaining <= 0) {
      _retryTimer?.cancel();
      _retryTimer = null;
    }
    final blocked = state.locked || state.obscured;
    if (blocked) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) FocusManager.instance.primaryFocus?.unfocus();
      });
    }
    return Stack(
      fit: StackFit.expand,
      children: [
        ExcludeSemantics(
          excluding: blocked,
          child: Listener(
            onPointerDown: (_) =>
                ref.read(appLockProvider.notifier).recordActivity(),
            onPointerMove: (_) =>
                ref.read(appLockProvider.notifier).recordActivity(),
            onPointerSignal: (_) =>
                ref.read(appLockProvider.notifier).recordActivity(),
            child: IgnorePointer(
              ignoring: blocked,
              child: FocusScope(canRequestFocus: !blocked, child: widget.child),
            ),
          ),
        ),
        if (blocked)
          Positioned.fill(
            child: Material(
              color: Theme.of(context).scaffoldBackgroundColor,
              child: SafeArea(
                child: Center(
                  child: SingleChildScrollView(
                    key: const ValueKey('privacy-lock-scroll'),
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 360),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(CupertinoIcons.lock_shield, size: 64),
                            const SizedBox(height: 20),
                            const Text(
                              'TachiBooks đã khóa',
                              style: TextStyle(fontSize: 22),
                            ),
                            if (state.locked && !state.obscured) ...[
                              const SizedBox(height: 12),
                              Text(
                                state.capabilities.label,
                                textAlign: TextAlign.center,
                              ),
                              if (state.error != null) ...[
                                const SizedBox(height: 12),
                                Text(state.error!, textAlign: TextAlign.center),
                              ],
                              const SizedBox(height: 24),
                              FilledButton.icon(
                                key: const ValueKey('privacy-unlock'),
                                onPressed:
                                    state.authenticating ||
                                        remaining > 0 ||
                                        !state.configurationValid
                                    ? null
                                    : () => unawaited(
                                        ref
                                            .read(appLockProvider.notifier)
                                            .unlock(),
                                      ),
                                icon: state.authenticating
                                    ? const CupertinoActivityIndicator()
                                    : const Icon(CupertinoIcons.lock_open),
                                label: Text(
                                  state.authenticating
                                      ? 'Đang xác thực'
                                      : remaining > 0
                                      ? 'Thử lại sau ${remaining}s'
                                      : 'Mở khóa',
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
