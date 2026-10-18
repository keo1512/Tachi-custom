import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tachi_books/features/sources/data/extension_mutation_queue.dart';
import 'package:tachi_books/features/sources/data/native_tachi_repository.dart';
import 'package:tachi_books/features/sources/domain/catalogue.dart';

// Regression from a read-only audit reproduction. Only the executor is faked;
// the repository timeout and shared mutation/backup leases are real Dart code.
class _AuditTimer implements Timer {
  _AuditTimer(this.callback);
  final void Function() callback;
  bool _active = true;
  void fire() {
    if (!_active) return;
    _active = false;
    callback();
  }

  @override
  void cancel() => _active = false;
  @override
  bool get isActive => _active;
  @override
  int get tick => _active ? 0 : 1;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('reentrant follow-up waits for a retained native call', () async {
    final native = Completer<Object?>();
    var nestedEntered = false;
    await ExtensionMutationQueue.run('retained-reentrant-audit', () async {
      ExtensionMutationQueue.retainUntilSettled(native.future);
      final nested = ExtensionMutationQueue.run(
        'retained-reentrant-audit',
        () async => nestedEntered = true,
      );
      await Future<void>.delayed(Duration.zero);
      expect(nestedEntered, false);
      native.complete();
      expect(await nested, true);
    });
  });

  for (final failLate in [false, true]) {
    test(
      'native timeout keeps backup and next mutation blocked until late ${failLate ? 'error' : 'success'}',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'tachi-timeout-audit-',
        );
        final nativeMutation = Completer<String>();
        final mutationEntered = Completer<void>();
        final events = <String>[];
        final repository = NativeTachiRepository(
          storageDirectory: directory,
          executor: (raw) {
            final method = (jsonDecode(raw) as Map<String, dynamic>)['method'];
            if (method == 'clearCookies') {
              events.add('mutation-entered');
              mutationEntered.complete();
              return nativeMutation.future.then(
                (value) {
                  events.add('native-mutation-completed');
                  return value;
                },
                onError: (Object error, StackTrace stack) {
                  events.add('native-mutation-failed');
                  Error.throwWithStackTrace(error, stack);
                },
              );
            }
            if (method == 'clearSourceCache') {
              events.add('next-mutation-entered');
            }
            return Future.value(
              jsonEncode({'ok': true, 'result': <String, dynamic>{}}),
            );
          },
        );
        try {
          await repository.health();
          _AuditTimer? timeout;
          await runZoned(
            () async {
              final mutation = repository.clearCookies();
              final error = expectLater(
                mutation,
                throwsA(
                  isA<ApiException>().having((e) => e.code, 'code', 'TIMEOUT'),
                ),
              );
              await mutationEntered.future;
              expect(events, ['mutation-entered']);
              expect(timeout, isNotNull);
              timeout!.fire();
              await error;
              expect(nativeMutation.isCompleted, false);

              final capture = repository.exclusiveExtensionBackup(() async {
                events.add('backup-capture-entered');
              });
              final next = repository.clearSourceCache();
              await Future<void>.delayed(Duration.zero);
              expect(events, ['mutation-entered']);

              if (failLate) {
                nativeMutation.completeError(
                  StateError('Native mutation failed late'),
                );
              } else {
                nativeMutation.complete(
                  jsonEncode({'ok': true, 'result': true}),
                );
              }
              await capture;
              await next;
              expect(events, [
                'mutation-entered',
                failLate
                    ? 'native-mutation-failed'
                    : 'native-mutation-completed',
                'backup-capture-entered',
                'next-mutation-entered',
              ]);
            },
            zoneSpecification: ZoneSpecification(
              createTimer: (self, parent, zone, duration, callback) {
                if (duration == const Duration(seconds: 90)) {
                  return timeout = _AuditTimer(callback);
                }
                return parent.createTimer(zone, duration, callback);
              },
            ),
          );
        } finally {
          repository.dispose();
          await directory.delete(recursive: true);
        }
      },
    );
  }
}
