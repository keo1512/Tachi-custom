import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:tachi_books/features/sources/data/extension_mutation_queue.dart';

void main() {
  test(
    'nested awaited mutations are reentrant, failures release the queue',
    () async {
      await ExtensionMutationQueue.run('nested', () async {
        expect(await ExtensionMutationQueue.run('nested', () async => 7), 7);
      });
      await expectLater(
        ExtensionMutationQueue.run(
          'nested',
          () async => throw StateError('fail'),
        ),
        throwsStateError,
      );
      expect(await ExtensionMutationQueue.run('nested', () async => 8), 8);
    },
  );
  test(
    'delayed descendant cannot reuse a released lease to bypass the next owner',
    () async {
      final startOldChild = Completer<void>();
      final newOwnerEntered = Completer<void>();
      final finishNewOwner = Completer<void>();
      final oldChildEnteredQueue = Completer<void>();
      final applied = <String>[];
      late Future<void> oldChild;
      await ExtensionMutationQueue.run('same-runtime', () async {
        oldChild = startOldChild.future.then((_) async {
          oldChildEnteredQueue.complete();
          await ExtensionMutationQueue.run(
            'same-runtime',
            () async => applied.add('old child'),
          );
        });
      });
      final newOwner = ExtensionMutationQueue.run('same-runtime', () async {
        newOwnerEntered.complete();
        await finishNewOwner.future;
        applied.add('new owner');
      });
      await newOwnerEntered.future;
      startOldChild.complete();
      await oldChildEnteredQueue.future;
      // Flush chained futures to expose a stale-zone bypass deterministically.
      await Future<void>.delayed(Duration.zero);
      expect(applied, isEmpty);
      finishNewOwner.complete();
      await newOwner;
      await oldChild;
      expect(applied, ['new owner', 'old child']);
    },
  );
}
