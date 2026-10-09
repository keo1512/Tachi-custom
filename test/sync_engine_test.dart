import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tachi_books/features/sync/domain/sync_engine.dart';

import 'support/sync_fakes.dart';

void main() {
  late FakeSyncLocal local;
  late FakeSyncRemote remote;
  late SyncEngine engine;
  setUp(() {
    local = FakeSyncLocal();
    remote = FakeSyncRemote();
    engine = SyncEngine(uid: 'alice', local: local, remote: remote);
  });

  void baseline({bool enabled = true}) {
    remote.seed(local.bytes);
    local.savedLink = SyncLink(
      uid: 'alice',
      headId: remote.current!.id,
      fingerprint: local.fingerprint(local.bytes),
      enabled: enabled,
    );
  }

  test('disabled sync makes no snapshot or network request', () async {
    expect(await engine.run(), SyncOutcome.paused);
    expect(local.snapshots, 0);
    expect(remote.headReads, 0);
  });

  test('first upload preserves full cached text and pins account before a failed network request', () async {
    final original = Uint8List.fromList(local.bytes);
    remote.headError = const SyncFailure('offline');
    await expectLater(engine.run(enable: true), throwsA(isA<SyncFailure>()));
    expect(local.link!.uid, 'alice');
    expect(local.bytes, original);
    expect(remote.publishes, 0);
    remote.headError = null;
    expect(await engine.run(), SyncOutcome.uploaded);
    expect(remote.bytes, original);
    expect(utf8.decode(remote.bytes!), contains('Nội dung đã tải'));
    expect(local.link!.fingerprint, local.fingerprint(original));
  });

  test(
    'cloud-only edit replaces unchanged local data using saved fingerprint',
    () async {
      baseline();
      final incoming = sampleSnapshot(
        progress: .7,
        html: '<p>Nội dung mới đầy đủ</p>',
      );
      remote.seed(incoming, id: '33333333333333333333333333333333');
      expect(await engine.run(), SyncOutcome.downloaded);
      expect(local.bytes, incoming);
      expect(local.replaces, 1);
      expect(remote.publishes, 0);
    },
  );

  test('both edits require explicit choice and never merge incompatible metadata/cache', () async {
    baseline();
    local.bytes = sampleSnapshot(progress: .4);
    remote.seed(
      sampleSnapshot(progress: .8),
      id: '33333333333333333333333333333333',
    );
    expect(await engine.run(), SyncOutcome.conflict);
    expect(local.replaces, 0);
    expect(remote.publishes, 0);
    expect(await engine.resolve(keepLocal: true), SyncOutcome.uploaded);
    expect(remote.bytes, local.bytes);
    expect(engine.conflict, isNull);
  });

  test('initial nonmatching cloud copy also requires choice rather than overwriting either side', () async {
    remote.seed(sampleSnapshot(progress: .8));
    expect(await engine.run(enable: true), SyncOutcome.conflict);
    expect(local.replaces, 0);
    expect(remote.publishes, 0);
    final incoming = remote.bytes;
    expect(await engine.resolve(keepLocal: false), SyncOutcome.downloaded);
    expect(local.bytes, incoming);
  });

  test(
    'stale local conflict decision is rejected before cloud or local writes',
    () async {
      remote.seed(sampleSnapshot(progress: .8));
      await engine.run(enable: true);
      local.bytes = sampleSnapshot(progress: .5);
      await expectLater(
        engine.resolve(keepLocal: false),
        throwsA(isA<SyncFailure>()),
      );
      expect(local.replaces, 0);
      expect(remote.publishes, 0);
      expect(engine.conflict, isNull);
    },
  );

  test(
    'stale cloud conflict decision is rejected before any local replacement',
    () async {
      remote.seed(sampleSnapshot(progress: .8));
      await engine.run(enable: true);
      remote.seed(
        sampleSnapshot(progress: .9),
        id: '33333333333333333333333333333333',
      );
      await expectLater(
        engine.resolve(keepLocal: false),
        throwsA(isA<SyncFailure>()),
      );
      expect(local.replaces, 0);
    },
  );

  test('repository CAS protects a reader edit between snapshot check and replacement', () async {
    baseline();
    remote.seed(
      sampleSnapshot(progress: .8),
      id: '33333333333333333333333333333333',
    );
    final readerEdit = sampleSnapshot(progress: .25);
    local.beforeReplace = () => local.bytes = readerEdit;
    await expectLater(engine.run(), throwsA(isA<SyncFailure>()));
    expect(local.bytes, readerEdit);
    expect(local.replaces, 0);
    expect(local.link!.headId, '22222222222222222222222222222222');
  });

  test(
    'edit while uploading remains dirty and is sent on the next run',
    () async {
      final first = Uint8List.fromList(local.bytes);
      final edit = sampleSnapshot(progress: .5);
      remote.beforePublish = () => local.bytes = edit;
      expect(await engine.run(enable: true), SyncOutcome.uploaded);
      expect(remote.bytes, first);
      expect(local.bytes, edit);
      remote.beforePublish = null;
      remote.nextId = '44444444444444444444444444444444';
      expect(await engine.run(), SyncOutcome.uploaded);
      expect(remote.bytes, edit);
    },
  );

  test(
    'wrong account cannot read, replace or upload the linked library',
    () async {
      local.savedLink = const SyncLink(uid: 'bob', enabled: true);
      await expectLater(engine.run(enable: true), throwsA(isA<SyncFailure>()));
      expect(remote.headReads, 0);
      expect(local.snapshots, 0);
      expect(local.link!.uid, 'bob');
    },
  );

  test(
    'missing previous cloud baseline cannot silently create a new head',
    () async {
      baseline();
      remote.current = null;
      await expectLater(engine.run(), throwsA(isA<SyncFailure>()));
      expect(remote.publishes, 0);
      expect(local.replaces, 0);
    },
  );

  test('invalid cloud payload and changed head during chunk download preserve local data', () async {
    baseline();
    final original = Uint8List.fromList(local.bytes);
    remote.seed(
      Uint8List.fromList(utf8.encode('{}')),
      id: '33333333333333333333333333333333',
    );
    await expectLater(engine.run(), throwsA(isA<FormatException>()));
    expect(local.bytes, original);
    remote.seed(
      sampleSnapshot(progress: .8),
      id: '33333333333333333333333333333333',
    );
    remote.beforeDownload = () => remote.seed(
      sampleSnapshot(progress: .9),
      id: '44444444444444444444444444444444',
    );
    await expectLater(engine.run(), throwsA(isA<SyncFailure>()));
    expect(local.bytes, original);
  });

  test('pause retains link baseline and discards pending conflict', () async {
    remote.seed(sampleSnapshot(progress: .8));
    await engine.run(enable: true);
    await engine.pause();
    expect(local.link!.enabled, false);
    expect(local.link!.uid, 'alice');
    expect(engine.conflict, isNull);
    expect(await engine.run(), SyncOutcome.paused);
  });
}
