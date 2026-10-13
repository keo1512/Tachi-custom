import 'package:firebase_core/firebase_core.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tachi_books/features/sync/application/sync_controller.dart';
import 'package:tachi_books/features/sync/data/google_session.dart';
import 'package:tachi_books/features/sync/data/sync_link_store.dart';
import 'package:tachi_books/features/sync/domain/sync_engine.dart';
import 'package:tachi_books/core/diagnostics/diagnostic_log.dart';

import 'support/sync_fakes.dart';

void main() {
  late FakeSyncAuth auth;
  late FakeSyncLocal local;
  late FakeSyncRemote remote;
  late ProviderContainer container;
  late DateTime now;
  setUp(() {
    now = DateTime.utc(2026, 10, 10);
    auth = FakeSyncAuth();
    local = FakeSyncLocal();
    remote = FakeSyncRemote();
    container = ProviderContainer(
      overrides: [
        syncAuthProvider.overrideWithValue(auth),
        syncLocalProvider.overrideWithValue(local),
        syncRemoteFactoryProvider.overrideWithValue((_) => remote),
        syncClockProvider.overrideWithValue(() => now),
      ],
    );
  });
  tearDown(() => container.dispose());

  test(
    'sign in uses auth result without uploading or implicitly enabling sync',
    () async {
      await container.read(syncProvider.notifier).signIn();
      expect(auth.signIns, 1);
      expect(container.read(syncProvider).user!.uid, 'alice');
      expect(container.read(syncProvider).enabled, false);
      expect(remote.headReads, 0);
      expect(local.link, isNull);
      await container.read(syncProvider.notifier).sync(enable: true);
      expect(container.read(syncProvider).enabled, true);
      expect(remote.publishes, 1);
    },
  );

  test(
    'cancel and configuration error never display a fake signed-in user',
    () async {
      auth.signInResult = null;
      await container.read(syncProvider.notifier).signIn();
      expect(container.read(syncProvider).user, isNull);
      auth.error = const SyncFailure('missing config');
      await container.read(syncProvider.notifier).signIn();
      expect(container.read(syncProvider).user, isNull);
      expect(container.read(syncProvider).error, true);
      expect(remote.publishes, 0);
    },
  );

  test('resume of paused linked session performs no cloud request', () async {
    auth.user = auth.signInResult;
    local.savedLink = const SyncLink(uid: 'alice', enabled: false);
    await container.read(syncProvider.notifier).resume();
    expect(container.read(syncProvider).user!.uid, 'alice');
    expect(container.read(syncProvider).enabled, false);
    expect(remote.headReads, 0);
  });

  test('failed first enabled upload keeps the switch aligned with its saved opt-in', () async {
    await container.read(syncProvider.notifier).signIn();
    remote.headError = const SyncFailure('offline');
    await container.read(syncProvider.notifier).sync(enable: true);
    expect(container.read(syncProvider).error, true);
    expect(container.read(syncProvider).enabled, true);
    expect(local.link!.enabled, true);
    expect(local.link!.uid, 'alice');
    expect(remote.publishes, 0);
    remote.headError = null;
    await container.read(syncProvider.notifier).sync();
    expect(container.read(syncProvider).error, false);
    expect(remote.publishes, 1);
  });

  test(
    'repeated foreground resumes respect the automatic one-minute limit',
    () async {
      auth.user = auth.signInResult;
      local.savedLink = const SyncLink(uid: 'alice', enabled: true);
      final controller = container.read(syncProvider.notifier);
      await controller.resume();
      expect(remote.publishes, 1);
      final reads = remote.headReads;
      await controller.resume();
      now = now.add(const Duration(seconds: 59));
      await controller.resume();
      await controller.sync(automatic: true);
      expect(remote.headReads, reads);
      now = now.add(const Duration(seconds: 1));
      await controller.resume();
      expect(remote.headReads, reads + 1);
      expect(container.read(syncProvider).busy, false);
    },
  );

  test('a failed automatic request is also throttled while manual retries stay available', () async {
    auth.user = auth.signInResult;
    local.savedLink = const SyncLink(uid: 'alice', enabled: true);
    remote.headError = const SyncFailure('offline');
    final controller = container.read(syncProvider.notifier);
    await controller.resume();
    expect(remote.headReads, 1);
    await controller.resume();
    expect(remote.headReads, 1);
    await controller.sync();
    expect(remote.headReads, 2);
  });

  test(
    'sign out pauses sync and preserves full library data and baseline',
    () async {
      await container.read(syncProvider.notifier).signIn();
      await container.read(syncProvider.notifier).sync(enable: true);
      final bytes = local.bytes;
      final head = local.link!.headId;
      await container.read(syncProvider.notifier).signOut();
      expect(auth.signOuts, 1);
      expect(container.read(syncProvider).user, isNull);
      expect(local.bytes, bytes);
      expect(local.link!.enabled, false);
      expect(local.link!.headId, head);
    },
  );

  test('provider exception text never leaks into displayed error messages', () {
    final error = FirebaseException(
      plugin: 'auth',
      code: 'network-request-failed',
      message: 'SECRET_TOKEN_AND_UID',
    );
    expect(syncErrorMessage(error), contains('Dữ liệu trên máy'));
    expect(syncErrorMessage(error), isNot(contains('SECRET')));
    expect(
      syncErrorMessage(StateError('secret-url')),
      isNot(contains('secret-url')),
    );
  });
  test('sync catch logs one original Firebase code instead of translated StateError', () async {
    final events = <DiagnosticEvent>[];
    final previous = DiagnosticLogs.writer;
    DiagnosticLogs.writer = (event) async => events.add(event);
    addTearDown(() => DiagnosticLogs.writer = previous);
    await container.read(syncProvider.notifier).signIn();
    remote.headError = FirebaseException(
      plugin: 'cloud_firestore',
      code: 'permission-denied',
      message: 'private token=secret',
    );
    await container.read(syncProvider.notifier).sync(enable: true);
    expect(events, hasLength(1));
    expect(events.single.code, 'sync_permission_denied');
    expect(events.single.type, 'FirebaseException');
    expect(events.single.toJson().values.join(), isNot(contains('secret')));
  });

  test(
    'Firestore permission failure keeps the signed-in session and library',
    () async {
      await container.read(syncProvider.notifier).signIn();
      final originalBytes = local.bytes;
      remote.headError = FirebaseException(
        plugin: 'cloud_firestore',
        code: 'permission-denied',
        message: 'PRIVATE_PROJECT_AND_UID',
      );
      await container.read(syncProvider.notifier).sync(enable: true);

      final state = container.read(syncProvider);
      expect(state.user!.uid, 'alice');
      expect(state.enabled, true);
      expect(state.error, true);
      expect(state.message, contains('quy tắc Firestore'));
      expect(state.message, contains('phiên bản 2'));
      expect(state.message, isNot(contains('bật Google')));
      expect(state.message, isNot(contains('PRIVATE')));
      expect(auth.signOuts, 0);
      expect(local.bytes, same(originalBytes));
      expect(local.replaces, 0);
      expect(remote.publishes, 0);
    },
  );

  test(
    'disabled Google provider and expired cloud auth have distinct remedies',
    () {
      final disabledProvider = syncErrorMessage(
        FirebaseException(
          plugin: 'firebase_auth',
          code: 'operation-not-allowed',
          message: 'SECRET_PROVIDER_CONFIG',
        ),
      );
      expect(disabledProvider, contains('Bật Google trong Authentication'));
      expect(disabledProvider, isNot(contains('Firestore')));
      expect(disabledProvider, isNot(contains('SECRET')));

      final expiredSession = syncErrorMessage(
        FirebaseException(
          plugin: 'cloud_firestore',
          code: 'unauthenticated',
          message: 'SECRET_TOKEN',
        ),
      );
      expect(expiredSession, contains('đăng nhập Google lại'));
      expect(expiredSession, isNot(contains('Firestore')));
      expect(expiredSession, isNot(contains('SECRET')));
    },
  );

  test(
    'malformed persisted link remains intact and blocks automatic relinking',
    () async {
      SharedPreferences.setMockInitialValues({SyncLinkStore.key: '{bad-link'});
      final preferences = await SharedPreferences.getInstance();
      expect(
        () => SyncLinkStore(preferences).read(),
        throwsA(isA<SyncFailure>()),
      );
      expect(preferences.getString(SyncLinkStore.key), '{bad-link');
    },
  );

  test(
    'persisted enabled flag, owner and baseline survive a new store instance',
    () async {
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      await SyncLinkStore(preferences).save(
        SyncLink(
          uid: 'alice',
          enabled: true,
          headId: '11111111111111111111111111111111',
          fingerprint: 'a' * 64,
          lastSyncedAt: DateTime.utc(2026, 10, 10),
        ),
      );
      final link = SyncLinkStore(preferences).read()!;
      expect(link.uid, 'alice');
      expect(link.enabled, true);
      expect(link.headId, '11111111111111111111111111111111');
      expect(link.lastSyncedAt, DateTime.utc(2026, 10, 10));
    },
  );
}
