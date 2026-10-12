import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tachi_books/features/settings/settings_controller.dart';
import 'package:tachi_books/features/privacy/application/app_lock_controller.dart';
import 'package:tachi_books/features/library/data/library_repository.dart';
import 'package:tachi_books/features/library/presentation/library_view_model.dart';
import 'package:tachi_books/features/sync/application/sync_controller.dart';
import 'package:tachi_books/features/sync/application/sync_lifecycle.dart';
import 'package:tachi_books/features/sync/data/google_session.dart';
import 'package:tachi_books/features/sync/data/sync_platform.dart';
import 'package:tachi_books/features/sync/domain/sync_engine.dart';

import 'support/sync_fakes.dart';

class _SyncLock extends AppLockController {
  _SyncLock(this.startsLocked);
  final bool startsLocked;
  @override
  AppLockState build() => AppLockState(initialized: true, locked: startsLocked);
  @override
  Future<void> initialize() async {}
  void setLocked(bool value) => state = state.copyWith(locked: value);
}

void main() {
  late StreamController<bool> network;
  late FakeSyncLocal local;
  late FakeSyncRemote remote;
  setUp(() {
    network = StreamController<bool>.broadcast(sync: true);
    local = FakeSyncLocal();
    remote = FakeSyncRemote()..seed(local.bytes);
    local.savedLink = SyncLink(
      uid: 'alice',
      enabled: true,
      headId: remote.current!.id,
      fingerprint: local.fingerprint(local.bytes),
    );
  });
  tearDown(() async => network.close());
  Future<ProviderContainer> mount(
    WidgetTester tester, {
    bool locked = false,
  }) async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          preferencesProvider.overrideWithValue(preferences),
          appLockProvider.overrideWith(() => _SyncLock(locked)),
          libraryRepositoryProvider.overrideWithValue(
            MemoryLibraryRepository(),
          ),
          syncAuthProvider.overrideWithValue(
            FakeSyncAuth()..user = const SyncUser(uid: 'alice'),
          ),
          syncLocalProvider.overrideWithValue(local),
          syncRemoteFactoryProvider.overrideWithValue((_) => remote),
          syncClockProvider.overrideWithValue(() => tester.binding.clock.now()),
          syncConnectivityProvider.overrideWithValue(network.stream),
        ],
        child: const SyncLifecycle(child: SizedBox()),
      ),
    );
    await tester.pump();
    return ProviderScope.containerOf(
      tester.element(find.byType(SyncLifecycle)),
    );
  }

  testWidgets(
    'automatic sync does not capture packages or use cloud while locked',
    (tester) async {
      final container = await mount(tester, locked: true);
      network.add(true);
      await tester.pump(const Duration(minutes: 16));
      expect(remote.headReads, 0);
      final lock = container.read(appLockProvider.notifier) as _SyncLock;
      lock.setLocked(false);
      await tester.pump();
      await tester.pump();
      expect(remote.headReads, 1);
      lock.setLocked(true);
      local.bytes = sampleSnapshot(progress: .6);
      network.add(false);
      network.add(true);
      await tester.pump(const Duration(minutes: 16));
      expect(remote.headReads, 1);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'network restoration retries a failed sync after the shared throttle',
    (tester) async {
      remote.headError = const SyncFailure('Không có mạng');
      final container = await mount(tester);
      network.add(false);
      expect(remote.headReads, 1);
      expect(container.read(syncProvider).error, isTrue);
      await tester.pump(const Duration(seconds: 20));
      remote.headError = null;
      network.add(true);
      await tester.pump(const Duration(seconds: 39));
      expect(remote.headReads, 1);
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      expect(remote.headReads, 2);
      expect(container.read(syncProvider).error, isFalse);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'idle foreground check downloads another device edit after fifteen minutes',
    (tester) async {
      await mount(tester);
      remote.seed(
        sampleSnapshot(progress: .8),
        id: '33333333333333333333333333333333',
      );
      await tester.pump(const Duration(minutes: 15));
      expect(remote.headReads, 1);
      await tester.pump(const Duration(seconds: 6));
      await tester.pump();
      expect(remote.headReads, 3); // Head read plus pre-replacement CAS check.
      expect(local.replaces, 1);
      expect(local.bytes, remote.bytes);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets('disabled sync ignores connectivity and periodic checks', (
    tester,
  ) async {
    local.savedLink = SyncLink(uid: 'alice', enabled: false);
    await mount(tester);
    network.add(false);
    network.add(true);
    await tester.pump(const Duration(minutes: 16));
    expect(remote.headReads, 0);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('network loss cancels an already armed periodic sync', (
    tester,
  ) async {
    await mount(tester);
    network.add(true);
    await tester.pump(const Duration(minutes: 15));
    network.add(false);
    await tester.pump(const Duration(seconds: 10));
    expect(remote.headReads, 1);
    network.add(true);
    await tester.pump(const Duration(seconds: 6));
    await tester.pump();
    expect(remote.headReads, 2);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
    'background suspends idle checks and resume preserves throttling',
    (tester) async {
      await mount(tester);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump(const Duration(minutes: 16));
      expect(remote.headReads, 1);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      await tester.pump();
      expect(remote.headReads, 2);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
