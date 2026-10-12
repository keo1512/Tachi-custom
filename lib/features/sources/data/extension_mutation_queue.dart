import 'dart:async';

class _ExtensionLease {
  bool active = true;
}

/// Reentrant within one asynchronous restore, shared by handles of the same
/// runtime store. Ordinary source/image reads do not enter this mutation queue.
class ExtensionMutationQueue {
  static final _tails = <String, Future<void>>{};
  static final _zoneKey = Object();

  static Future<T> run<T>(String key, Future<T> Function() action) async {
    final owned =
        Zone.current[_zoneKey] as Map<String, _ExtensionLease>? ??
        const <String, _ExtensionLease>{};
    if (owned[key]?.active == true) return action();
    final previous = _tails[key] ?? Future<void>.value();
    final future = previous.then((_) async {
      final lease = _ExtensionLease();
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
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    _tails[key] = tail;
    try {
      return await future;
    } finally {
      if (identical(_tails[key], tail)) _tails.remove(key);
    }
  }
}
