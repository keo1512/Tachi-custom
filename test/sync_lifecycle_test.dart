import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tachi_books/features/library/data/library_repository.dart';
import 'package:tachi_books/features/library/domain/library_book.dart';
import 'package:tachi_books/features/library/presentation/library_view_model.dart';
import 'package:tachi_books/features/sync/application/sync_controller.dart';
import 'package:tachi_books/features/sync/application/sync_lifecycle.dart';
import 'package:tachi_books/features/sync/data/google_session.dart';
import 'package:tachi_books/features/sync/domain/sync_engine.dart';

import 'support/sync_fakes.dart';

void main() {
  Future<ProviderContainer> mount(
    WidgetTester tester, {
    required FakeSyncLocal local,
    required FakeSyncRemote remote,
    bool enabled = true,
  }) async {
    final auth = FakeSyncAuth()..user = const SyncUser(uid: 'alice');
    remote.seed(local.bytes);
    local.savedLink = SyncLink(
      uid: 'alice',
      headId: remote.current!.id,
      fingerprint: local.fingerprint(local.bytes),
      enabled: enabled,
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          libraryRepositoryProvider.overrideWithValue(
            MemoryLibraryRepository(),
          ),
          syncAuthProvider.overrideWithValue(auth),
          syncLocalProvider.overrideWithValue(local),
          syncRemoteFactoryProvider.overrideWithValue((_) => remote),
          syncClockProvider.overrideWithValue(() => tester.binding.clock.now()),
        ],
        child: const SyncLifecycle(child: SizedBox()),
      ),
    );
    await tester.pump();
    return ProviderScope.containerOf(
      tester.element(find.byType(SyncLifecycle)),
    );
  }

  final book = LibraryBook(id: 'event-book', title: 'Sách vừa nhập');

  testWidgets(
    'an edit within a minute after launch waits for the throttle and uploads without another event',
    (tester) async {
      final local = FakeSyncLocal();
      final remote = FakeSyncRemote();
      final container = await mount(tester, local: local, remote: remote);
      expect(remote.headReads, 1);
      await tester.pump(const Duration(seconds: 10));
      local.bytes = sampleSnapshot(progress: .4);
      await container.read(libraryProvider.notifier).save(book);
      await tester.pump(const Duration(seconds: 6));
      expect(remote.headReads, 1);
      await tester.pump(const Duration(seconds: 43));
      expect(remote.headReads, 1);
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      expect(remote.headReads, 2);
      expect(remote.publishes, 1);
      expect(remote.bytes, local.bytes);
      await tester.pump(const Duration(minutes: 2));
      expect(remote.headReads, 2);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'a manual sync postpones pending automatic work without dropping a later edit',
    (tester) async {
      final local = FakeSyncLocal();
      final remote = FakeSyncRemote();
      final container = await mount(tester, local: local, remote: remote);
      await tester.pump(const Duration(seconds: 10));
      local.bytes = sampleSnapshot(progress: .2);
      await container.read(libraryProvider.notifier).save(book);
      // The pending timer initially targets launch + 60s. A manual sync at
      // launch + 50s moves the shared next permitted automatic run to +110s.
      await tester.pump(const Duration(seconds: 40));
      await container.read(syncProvider.notifier).sync();
      expect(remote.headReads, 2);
      expect(remote.publishes, 1);
      await tester.pump(const Duration(seconds: 5));
      local.bytes = sampleSnapshot(progress: .7);
      remote.nextId = '44444444444444444444444444444444';
      await container
          .read(libraryProvider.notifier)
          .save(book.copyWith(title: 'Sách đã sửa'));
      await tester.pump(const Duration(seconds: 54));
      expect(remote.headReads, 2);
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      expect(remote.headReads, 3);
      expect(remote.publishes, 2);
      expect(remote.bytes, local.bytes);
      await tester.pump(const Duration(minutes: 2));
      expect(remote.headReads, 3);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'enabled foreground changes debounce for six seconds with no idle polling',
    (tester) async {
      final local = FakeSyncLocal();
      final remote = FakeSyncRemote();
      final container = await mount(tester, local: local, remote: remote);
      expect(remote.headReads, 1);
      await tester.pump(const Duration(minutes: 2));
      await tester.pump();
      expect(remote.headReads, 1);
      await container.read(libraryProvider.notifier).save(book);
      await tester.pump(const Duration(seconds: 5));
      expect(remote.headReads, 1);
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      expect(remote.headReads, 2);
      await tester.pump(const Duration(minutes: 2));
      expect(remote.headReads, 2);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'background transition cancels pending library sync until foreground resume',
    (tester) async {
      final local = FakeSyncLocal();
      final remote = FakeSyncRemote();
      final container = await mount(tester, local: local, remote: remote);
      await tester.pump(const Duration(minutes: 2));
      await container.read(libraryProvider.notifier).save(book);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump(const Duration(seconds: 10));
      expect(remote.headReads, 1);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(remote.headReads, 2);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'a throttled foreground resume keeps an earlier edit pending until allowed',
    (tester) async {
      final local = FakeSyncLocal();
      final remote = FakeSyncRemote();
      final container = await mount(tester, local: local, remote: remote);
      await tester.pump(const Duration(seconds: 10));
      local.bytes = sampleSnapshot(progress: .6);
      await container.read(libraryProvider.notifier).save(book);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump(const Duration(seconds: 10));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(remote.headReads, 1);
      await tester.pump(const Duration(seconds: 39));
      expect(remote.headReads, 1);
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      expect(remote.headReads, 2);
      expect(remote.publishes, 1);
      expect(remote.bytes, local.bytes);
      await tester.pump(const Duration(minutes: 2));
      expect(remote.headReads, 2);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'signed-in paused link never auto-syncs on launch or library edits',
    (tester) async {
      final local = FakeSyncLocal();
      final remote = FakeSyncRemote();
      final container = await mount(
        tester,
        local: local,
        remote: remote,
        enabled: false,
      );
      await container.read(libraryProvider.notifier).save(book);
      await tester.pump(const Duration(minutes: 2));
      expect(remote.headReads, 0);
      expect(remote.publishes, 0);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
