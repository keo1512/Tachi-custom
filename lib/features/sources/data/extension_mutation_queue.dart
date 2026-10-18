import 'dart:async';

class _ExtensionLease {
  bool active = true;
  final retained = <Future<void>>[];

  Future<void> waitForRetained() async {
    var observed = 0;
    while (observed < retained.length) {
      final pending = retained.sublist(observed);
      observed += pending.length;
      await Future.wait(pending);
    }
  }
}

/// Reentrant within one asynchronous restore, shared by handles of the same
/// runtime store. Ordinary source/image reads do not enter this mutation queue.
class ExtensionMutationQueue {
  static final _tails = <String, Future<void>>{};
  static final _zoneKey = Object();

  /// A caller timeout cannot cancel native code. Keep any current mutation or
  /// backup lease reserved until that executor really settles, including errors.
  static void retainUntilSettled(Future<Object?> operation) {
    final owned = Zone.current[_zoneKey] as Map<String, _ExtensionLease>?;
    if (owned == null) return;
    final settled = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    for (final lease in owned.values) {
      if (lease.active) lease.retained.add(settled);
    }
  }

  static Future<T> run<T>(String key, Future<T> Function() action) async {
    final owned =
        Zone.current[_zoneKey] as Map<String, _ExtensionLease>? ??
        const <String, _ExtensionLease>{};
    final current = owned[key];
    if (current?.active == true) {
      await current!.waitForRetained();
      // A delayed descendant may have waited past its owner's completion.
      if (current.active) return action();
    }
    final previous = _tails[key] ?? Future<void>.value();
    final lease = _ExtensionLease();
    final future = previous.then((_) async {
      try {
        return await runZoned(
          action,
          zoneValues: {
            _zoneKey: {...owned, key: lease},
          },
        );
      } finally {
        // Delayed descendants retain their Zone, but may not inherit a lease
        // after its owner has returned. They must queue behind the next owner.
        lease.active = false;
      }
    });
    final tail = future.then<void>(
      (_) => lease.waitForRetained(),
      onError: (Object _, StackTrace _) => lease.waitForRetained(),
    );
    _tails[key] = tail;
    unawaited(
      tail.then((_) {
        if (identical(_tails[key], tail)) _tails.remove(key);
      }),
    );
    return future;
  }
}
