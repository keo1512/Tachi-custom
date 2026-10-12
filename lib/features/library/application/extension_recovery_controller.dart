import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/format/error_messages.dart';
import '../../privacy/application/app_lock_controller.dart';
import 'backup_service_provider.dart';

/// A pending local package plan is retried once per startup after unlocking.
/// Packages come from the journal; an extension's startup may itself use HTTP.
/// The offline library remains available on failure.
final extensionRecoveryProvider =
    AsyncNotifierProvider<ExtensionRecoveryController, void>(
      ExtensionRecoveryController.new,
    );

class ExtensionRecoveryController extends AsyncNotifier<void> {
  Future<void>? _pending;
  Future<void>? _startupAttempt;
  Object? _incomplete;
  StackTrace? _incompleteStack;
  @override
  Future<void> build() async {
    ref.watch(
      appLockProvider.select(
        (lock) => (lock.initialized, lock.locked, lock.configurationValid),
      ),
    );
    await ref.read(appLockProvider.notifier).initialize();
    if (!ref.mounted) return;
    final lock = ref.read(appLockProvider);
    if (!lock.initialized || lock.locked || !lock.configurationValid) return;
    if (_incomplete != null) {
      Error.throwWithStackTrace(_incomplete!, _incompleteStack!);
    }
    // Rebuilding after another lock/unlock must not silently retry a failed
    // installation, or repeatedly initialize arbitrary extension code.
    await (_startupAttempt ??= _recover());
  }

  /// A later restore can fail after the startup replay has already succeeded.
  /// Keep its durable plan visible and block automatic snapshots until retry.
  void reportIncomplete(Object error, StackTrace stack) {
    _incomplete = error;
    _incompleteStack = stack;
    state = AsyncError(error, stack);
  }

  Future<void> _recover() {
    final existing = _pending;
    if (existing != null) return existing;
    final future = ref.read(backupServiceProvider).recoverPendingExtensions();
    _pending = future;
    return future.whenComplete(() {
      if (identical(_pending, future)) _pending = null;
    });
  }

  Future<void> retry() async {
    if (state.isLoading) return;
    final lock = ref.read(appLockProvider);
    if (!lock.initialized || lock.locked || !lock.configurationValid) return;
    state = const AsyncLoading();
    final attempt = ref.read(backupServiceProvider).retryPendingExtensions();
    _startupAttempt = attempt;
    final result = await AsyncValue.guard(() => attempt);
    if (ref.mounted) {
      if (result.hasError) {
        _incomplete = result.error;
        _incompleteStack = result.stackTrace;
      } else {
        _incomplete = null;
        _incompleteStack = null;
      }
      state = result;
    }
  }
}

String? extensionRecoveryMessage(AsyncValue<void> value) =>
    value.hasError ? userFacingError(value.error!) : null;

class ExtensionRecoveryLifecycle extends ConsumerWidget {
  const ExtensionRecoveryLifecycle({super.key, required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(extensionRecoveryProvider);
    return child;
  }
}
