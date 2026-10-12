import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tachi_books/features/library/data/backup_configuration.dart';
import 'package:tachi_books/features/library/data/backup_service.dart';
import 'package:tachi_books/features/library/data/coordinated_preferences.dart';
import 'package:tachi_books/features/library/data/extension_backup_store.dart';
import 'package:tachi_books/features/library/data/library_repository.dart';
import 'package:tachi_books/features/library/data/library_snapshot.dart';
import 'package:tachi_books/features/library/domain/library_book.dart';
import 'package:tachi_books/features/sources/domain/catalogue.dart';
import 'package:tachi_books/features/sources/domain/extension_backup.dart';
import 'package:tachi_books/features/sync/data/backup_sync_local.dart';
import 'package:tachi_books/features/sync/data/sync_link_store.dart';
import 'package:tachi_books/features/sync/domain/sync_engine.dart';
import 'package:tachi_books/features/sync/domain/sync_merge_plan.dart';

import 'support/sync_fakes.dart';

ExtensionBackupPackage _package(String id, {int version = 1}) =>
    ExtensionBackupPackage.create(
      engine: SourceEngine.tachimanga,
      id: 'eu.kanade.tachiyomi.extension.en.$id',
      name: 'Nguồn $id',
      version: '$version',
      bytes: Uint8List.fromList([0x50, 0x4b, 3, 4, version]),
      sourceIds: [id == 'one' ? '1' : '2'],
    );

class _AdditiveExtensions implements ExtensionBackupStore {
  _AdditiveExtensions(this.value);
  ExtensionBackup value;
  ExtensionBackup? pending;
  @override
  Future<T> exclusive<T>(Future<T> Function() action) => action();
  @override
  Future<ExtensionBackup?> capture() async => value;
  @override
  Future<void> prepare(
    ExtensionBackup incoming, {
    required String oldLibraryFingerprint,
    required String newLibraryFingerprint,
  }) async => pending = incoming;
  @override
  Future<void> complete() async {
    value = ExtensionBackup(
      {
        for (final package in value.packages) package.identity: package,
        for (final package in pending!.packages) package.identity: package,
      }.values,
    );
    pending = null;
  }

  @override
  Future<void> discardPrepared() async => pending = null;
  @override
  Future<void> recoverPending() async {}
}

class _HistoryRemote extends FakeSyncRemote implements SyncHistoryRemote {
  final history = <String, Uint8List>{};
  @override
  void seed(Uint8List data, {String id = '22222222222222222222222222222222'}) {
    super.seed(data, id: id);
    history[id] = Uint8List.fromList(data);
  }

  @override
  Future<Uint8List?> baseline(String headId) async => history[headId];
}

Uint8List _snapshot({
  String firstNotes = '',
  String secondNotes = '',
  ExtensionBackup? extensions,
  BackupConfiguration? configuration,
}) => LibrarySnapshot(
  [
    for (final id in ['a', 'b'])
      LibrarySnapshotEntry(
        LibraryBook(
          id: id,
          title: 'Truyện $id',
          notes: id == 'a' ? firstNotes : secondNotes,
          chapters: const [
            BookChapter(
              id: 'chapter',
              title: 'Chương',
              index: 0,
              downloaded: true,
            ),
          ],
        ),
        {0: ReaderContent(kind: 'novel', html: '<p>Offline $id</p>')},
      ),
  ],
  extensions: extensions,
  configuration: configuration,
).encode();

ExtensionBackup _extensions(Uint8List bytes) => ExtensionBackup.fromJson(
  (jsonDecode(utf8.decode(bytes)) as Map)['extensions'],
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('partial package omissions retain the present union with a baseline in either direction', () {
    final one = _package('one'), two = _package('two');
    final base = _snapshot(extensions: ExtensionBackup([one]));
    final full = _snapshot(extensions: ExtensionBackup([one, two]));
    for (final partial in [
      _snapshot(),
      _snapshot(extensions: ExtensionBackup(const [])),
      _snapshot(extensions: ExtensionBackup([two])),
    ]) {
      for (final inputs in [
        [full, partial],
        [partial, full],
      ]) {
        final plan = SyncMergePlan.tryBuild(
          inputs[0],
          inputs[1],
          baseline: base,
        )!;
        expect(plan.conflicts, isEmpty);
        expect(
          _extensions(plan.encode({})).fingerprint,
          ExtensionBackup([one, two]).fingerprint,
        );
      }
    }
  });

  test('present packages still use baseline versions and explicit divergent choices', () {
    final base = _snapshot(extensions: ExtensionBackup([_package('one')]));
    final local = _snapshot(
      extensions: ExtensionBackup([_package('one', version: 2)]),
    );
    final remote = _snapshot(
      extensions: ExtensionBackup([_package('one', version: 3)]),
    );
    final plan = SyncMergePlan.tryBuild(local, remote, baseline: base)!;
    expect(plan.conflicts.single.key, 'extension:${_package('one').identity}');
    expect(
      _extensions(plan.encode({plan.conflicts.single.key: false}))
          .packages
          .single
          .version,
      '3',
    );
    final remoteOnly = SyncMergePlan.tryBuild(base, remote, baseline: base)!;
    expect(remoteOnly.conflicts, isEmpty);
    expect(_extensions(remoteOnly.encode({})).packages.single.version, '3');
  });

  test('whole configuration omission retains current settings with a baseline while explicit deletion remains supported', () {
    final configuration = BackupConfiguration.fromJson({
      'version': 1,
      'preferences': {'fontSize': 24.0},
    });
    final base = _snapshot(configuration: configuration);
    final omitted = _snapshot(firstNotes: 'Ghi chú cloud');
    for (final inputs in [
      [base, omitted],
      [omitted, base],
    ]) {
      final plan = SyncMergePlan.tryBuild(
        inputs[0],
        inputs[1],
        baseline: base,
      )!;
      expect(plan.conflicts, isEmpty);
      expect(
        (jsonDecode(utf8.decode(plan.encode({}))) as Map)['configuration'],
        configuration.toJson(),
      );
    }
    final deleted = _snapshot(
      configuration: BackupConfiguration.fromJson({
        'version': 1,
        'preferences': <String, Object>{},
      }),
    );
    final plan = SyncMergePlan.tryBuild(base, deleted, baseline: base)!;
    expect(plan.conflicts, isEmpty);
    expect((jsonDecode(utf8.decode(plan.encode({}))) as Map)['configuration'], {
      'version': 1,
      'preferences': <String, Object>{},
    });
  });

  late MemoryLibraryRepository repository;
  late _AdditiveExtensions extensions;
  late BackupService backup;
  late _HistoryRemote remote;
  late SyncEngine engine;
  Future<void> initialize() async {
    SharedPreferences.setMockInitialValues({'fontSize': 24.0});
    repository = MemoryLibraryRepository();
    final preferences = await CoordinatedPreferences.open(
      await SharedPreferences.getInstance(),
      repository,
    );
    await BackupService(repository).replace(
      _snapshot(),
      expectedFingerprint: (await repository.snapshot()).fingerprint,
    );
    extensions = _AdditiveExtensions(
      ExtensionBackup([_package('one'), _package('two')]),
    );
    backup = BackupService(
      repository,
      configuration: AppConfigurationStore(preferences),
      extensions: extensions,
    );
    remote = _HistoryRemote()..seed(await backup.export());
    engine = SyncEngine(
      uid: 'alice',
      local: BackupSyncLocal(backup: backup, links: SyncLinkStore(preferences)),
      remote: remote,
    );
    expect(await engine.run(enable: true), SyncOutcome.current);
  }

  Future<void> expectStableImage() async {
    final actual = await backup.export();
    expect(backup.fingerprint(actual), backup.fingerprint(remote.bytes!));
    expect(engine.local.link!.fingerprint, backup.fingerprint(actual));
    expect(engine.local.link!.headId, remote.current!.id);
    final publications = remote.publishes;
    expect(await engine.run(), SyncOutcome.current);
    expect(remote.publishes, publications);
    expect((await repository.readChapter('b', 0))!.html, '<p>Offline b</p>');
  }

  test('automatic cloud replacement publishes retained packages and omitted settings without next-sync churn', () async {
    await initialize();
    final recovery = await backup.export();
    remote.seed(
      _snapshot(
        firstNotes: 'Ghi chú cloud',
        extensions: ExtensionBackup([_package('one', version: 2)]),
      ),
      id: '33333333333333333333333333333333',
    );
    expect(await engine.run(), SyncOutcome.downloaded);
    expect(remote.publishes, 1);
    expect((await repository.find('a'))!.notes, 'Ghi chú cloud');
    expect(extensions.value.packages.map((package) => package.version), [
      '2',
      '1',
    ]);
    expect(
      backup.fingerprint((await backup.exportRecovery())!),
      backup.fingerprint(recovery),
    );
    expect((jsonDecode(utf8.decode(remote.bytes!)) as Map)['configuration'], {
      'version': 1,
      'preferences': {'fontSize': 24.0},
    });
    await expectStableImage();
  });

  test('whole-cloud conflict choice retains local installed packages in the published baseline', () async {
    await initialize();
    await repository.save(
      (await repository.find('a'))!.copyWith(notes: 'Ghi chú máy'),
    );
    remote.seed(
      _snapshot(firstNotes: 'Ghi chú cloud'),
      id: '33333333333333333333333333333333',
    );
    expect(await engine.run(), SyncOutcome.conflict);
    expect(await engine.resolve(keepLocal: false), SyncOutcome.downloaded);
    expect((await repository.find('a'))!.notes, 'Ghi chú cloud');
    expect(extensions.value.packages, hasLength(2));
    expect(remote.publishes, 1);
    await expectStableImage();
  });

  test('record resolution retains missing packages while preserving independent book edits', () async {
    await initialize();
    await repository.save(
      (await repository.find('a'))!.copyWith(notes: 'Ghi chú máy'),
    );
    remote.seed(
      _snapshot(
        secondNotes: 'Ghi chú cloud',
        extensions: ExtensionBackup([_package('one', version: 2)]),
        configuration: BackupConfiguration.fromJson({
          'version': 1,
          'preferences': {'fontSize': 24.0},
        }),
      ),
      id: '33333333333333333333333333333333',
    );
    expect(await engine.run(), SyncOutcome.conflict);
    expect(engine.conflict!.mergePlan!.conflicts, isEmpty);
    expect(await engine.resolveRecords({}), SyncOutcome.downloaded);
    expect((await repository.find('a'))!.notes, 'Ghi chú máy');
    expect((await repository.find('b'))!.notes, 'Ghi chú cloud');
    expect(extensions.value.packages.map((package) => package.version), [
      '2',
      '1',
    ]);
    expect(remote.publishes, 1);
    await expectStableImage();
  });

  test('a cloud image containing only package omissions is repaired without unnecessary local replacement', () async {
    await initialize();
    final originalRecovery = await backup.exportRecovery();
    remote.seed(
      _snapshot(extensions: ExtensionBackup(const [])),
      id: '33333333333333333333333333333333',
    );
    expect(await engine.run(), SyncOutcome.downloaded);
    expect(remote.publishes, 1);
    expect(await backup.exportRecovery(), originalRecovery);
    expect(extensions.pending, isNull);
    await expectStableImage();
  });
}
