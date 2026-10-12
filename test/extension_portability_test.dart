import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
// Fault injection uses the platform boundary of the installed plugin.
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:tachi_books/features/library/data/backup_configuration.dart';
import 'package:tachi_books/features/library/data/coordinated_preferences.dart';
import 'package:tachi_books/features/library/data/backup_service.dart';
import 'package:tachi_books/features/library/data/extension_backup_store.dart';
import 'package:tachi_books/features/library/data/library_repository.dart';
import 'package:tachi_books/features/library/data/library_snapshot.dart';
import 'package:tachi_books/features/library/domain/library_book.dart';
import 'package:tachi_books/features/sources/data/native_tachi_repository.dart';
import 'package:tachi_books/features/sources/data/extension_mutation_queue.dart';
import 'package:tachi_books/features/sources/data/native_vbook_package.dart';
import 'package:tachi_books/features/sources/data/native_vbook_repository.dart';
import 'package:tachi_books/features/sources/domain/catalogue.dart';
import 'package:tachi_books/features/sources/domain/extension_backup.dart';
import 'package:tachi_books/features/sources/domain/native_source_engine.dart';
import 'package:tachi_books/features/sync/data/sync_chunk_plan.dart';
import 'package:tachi_books/features/sync/domain/sync_merge_plan.dart';

Uint8List _zip({String name = 'Nguồn mẫu', int version = 1}) {
  final archive = Archive();
  final files = {
    'plugin.json': jsonEncode({
      'metadata': {
        'name': name,
        'source': 'https://source.example',
        'type': 'novel',
        'version': version,
      },
      'script': {'detail': 'detail.js', 'toc': 'toc.js', 'chap': 'chap.js'},
    }),
    for (final key in ['detail', 'toc', 'chap'])
      'src/$key.js': 'function execute(){return Response.success("text");}',
  };
  for (final entry in files.entries) {
    archive.add(ArchiveFile.bytes(entry.key, utf8.encode(entry.value)));
  }
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

ExtensionBackupPackage _vbook({String name = 'Nguồn mẫu', int version = 1}) {
  final package = NativeVbookPackage.parse(_zip(name: name, version: version));
  return ExtensionBackupPackage.create(
    engine: SourceEngine.vbook,
    id: package.id,
    name: package.name,
    version: '$version',
    bytes: package.bytes,
    sourceIds: [package.id],
  );
}

LibraryBook _book(String id) => LibraryBook(
  id: id,
  title: 'Truyện $id',
  cover: 'https://cover.example/book.png',
);
ExtensionBackupStore _store(
  NativeExtensionBackupEngine runtime,
  LibraryRepository repository,
  Directory directory,
) => RepositoryExtensionBackupStore(
  runtime: runtime,
  repository: repository,
  engines: {SourceEngine.vbook, SourceEngine.tachimanga},
  directory: directory,
);

class _Runtime implements NativeExtensionBackupEngine {
  ExtensionBackup value = ExtensionBackup(const []);
  bool fail = false, invalid = false;
  int restores = 0, validations = 0;
  Future<void> Function()? afterValidate;
  @override
  Future<ExtensionBackup> captureExtensionBackup() async => value;
  @override
  Future<void> validateExtensionBackup(ExtensionBackup backup) async {
    validations++;
    if (invalid) throw const FormatException('Manifest không khớp');
    await afterValidate?.call();
  }

  @override
  Future<void> restoreExtensionBackup(ExtensionBackup backup) async {
    restores++;
    if (fail) throw StateError('Native unavailable');
    value = ExtensionBackup(
      {
        ...{for (final package in value.packages) package.identity: package},
        for (final package in backup.packages) package.identity: package,
      }.values,
    );
  }
}

class _JournalFailureStore extends InMemorySharedPreferencesStore {
  _JournalFailureStore() : super.withData({'flutter.dark': true});
  bool failPublication = false, failCleanup = false;
  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    if (failPublication &&
        key == 'flutter.${CoordinatedPreferences.journalKey}' &&
        (jsonDecode(value as String) as Map)['phase'] == 'committed') {
      return false;
    }
    return super.setValue(valueType, key, value);
  }

  @override
  Future<bool> remove(String key) async {
    if (failCleanup && key == 'flutter.${CoordinatedPreferences.journalKey}') {
      return false;
    }
    return super.remove(key);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory folder;
  setUp(() async {
    folder = await Directory.systemTemp.createTemp('tachi-portability-');
  });
  tearDown(() async {
    if (await folder.exists()) await folder.delete(recursive: true);
  });

  test('package roundtrip copies original bytes and rejects hash/identity/credential fields', () {
    final bytes = _zip(), parsed = NativeVbookPackage.parse(bytes);
    final package = ExtensionBackupPackage.create(
      engine: SourceEngine.vbook,
      id: parsed.id,
      name: parsed.name,
      bytes: bytes,
      sourceIds: [parsed.id],
      origin: 'https://repo.example/file.zip?token=private',
    );
    bytes[0] = 0;
    expect(package.bytes[0], 0x50);
    final copy = package.bytes;
    copy[0] = 0;
    expect(package.bytes[0], 0x50);
    expect(package.origin, isEmpty);
    expect(
      ExtensionBackup.fromJson(ExtensionBackup([package]).toJson()).fingerprint,
      ExtensionBackup([package]).fingerprint,
    );
    for (final bad in [
      {...package.toJson(), 'sha256': '0' * 64},
      {...package.toJson(), 'id': '../escape'},
      {
        ...package.toJson(),
        'origin': 'https://user:secret@repo.example/package.zip',
      },
      {...package.toJson(), 'cookies': {}},
      {
        ...package.toJson(),
        'preferences': {
          parsed.id: {
            'api_token': {'type': 'list', 'value': 'secret'},
          },
        },
      },
    ]) {
      expect(() => ExtensionBackupPackage.fromJson(bad), throwsFormatException);
    }
  });
  test('public preferences exclude text credentials and validate enum choices again', () {
    final boolean = PublicSourcePreference.fromScreen({
      'type': 'SwitchPreferenceCompat',
      'props': {'key': 'show_latest', 'currentValue': true},
    });
    expect(boolean!.value, isTrue);
    expect(
      PublicSourcePreference.fromScreen({
        'type': 'EditTextPreference',
        'props': {'key': 'base_url', 'currentValue': 'private'},
      }),
      isNull,
    );
    expect(
      PublicSourcePreference.fromScreen({
        'type': 'ListPreference',
        'props': {
          'key': 'auth_token',
          'currentValue': 'a',
          'entryValues': ['a'],
        },
      }),
      isNull,
    );
    final list = PublicSourcePreference.fromScreen({
      'type': 'ListPreference',
      'props': {
        'key': 'quality',
        'currentValue': 'high',
        'entryValues': ['high', 'low'],
      },
    })!;
    expect(
      list.matchesScreen({
        'type': 'ListPreference',
        'props': {
          'key': 'quality',
          'entryValues': ['low'],
        },
      }),
      isFalse,
    );
  });
  test('Tachi capture uses original registry APK, String64 IDs, public prefs and preflight before install', () async {
    final bytes = _zip(),
        digest = sha256.convert(bytes).toString(),
        id = 'eu.kanade.tachiyomi.extension.vi.fixture',
        sourceId = '9223372036854775806';
    await Directory('${folder.path}/packages').create();
    await File('${folder.path}/packages/$digest.apk').writeAsBytes(bytes);
    await File('${folder.path}/registry.json').writeAsString(
      jsonEncode({
        'version': 1,
        'packages': {
          id: {
            'id': id,
            'name': 'Nguồn APK',
            'version': '1.6.1',
            'apk': '$digest.apk',
            'apkSha256': digest,
            'sourceIds': [sourceId],
            'packageUrl': 'https://repo.example/file.apk?token=secret',
          },
        },
      }),
    );
    final calls = <String>[], writes = <Map>[];
    var inspectId = id;
    final repository = NativeTachiRepository(
      storageDirectory: folder,
      client: MockClient((_) async => throw StateError('No HTTP')),
      executor: (raw) async {
        final request = jsonDecode(raw) as Map,
            method = request['method'] as String,
            args = request['args'] as Map;
        calls.add(method);
        final result = switch (method) {
          'initialize' => {},
          'sources' => [
            {'id': sourceId, 'name': 'Nguồn APK', 'lang': 'vi'},
          ],
          'preferences' => [
            {
              'type': 'SwitchPreferenceCompat',
              'props': {'key': 'show_latest', 'currentValue': true},
            },
            {
              'type': 'EditTextPreference',
              'props': {'key': 'user_password', 'currentValue': 'secret'},
            },
            {
              'type': 'ListPreference',
              'props': {
                'key': 'quality',
                'currentValue': 'high',
                'entryValues': ['high', 'low'],
              },
            },
          ],
          'inspectPackage' => {'id': inspectId, 'apkSha256': digest},
          'install' => {
            'id': id,
            'name': 'Nguồn APK',
            'installed': true,
            'apkSha256': digest,
            'sourceIds': [sourceId],
          },
          'setPreference' => true,
          _ => throw StateError('Unexpected $method'),
        };
        if (method == 'setPreference') writes.add(args);
        return jsonEncode({'ok': true, 'result': result});
      },
    );
    final backup = await repository.captureExtensionBackup();
    expect(backup.packages.single.sourceIds, [sourceId]);
    expect(backup.packages.single.origin, isEmpty);
    expect(
      backup.packages.single.preferences[sourceId]!.keys,
      unorderedEquals(['show_latest', 'quality']),
    );
    expect(jsonEncode(backup.toJson()), isNot(contains('secret')));
    inspectId = 'eu.kanade.tachiyomi.extension.vi.forged';
    await expectLater(
      repository.restoreExtensionBackup(backup),
      throwsFormatException,
    );
    expect(calls, isNot(contains('install')));
    inspectId = id;
    await repository.restoreExtensionBackup(backup);
    expect(writes.map((write) => write['key']), ['show_latest', 'quality']);
    expect(writes.every((write) => write['sourceId'] == sourceId), isTrue);
    repository.dispose();
  });
  test('vBook backup installs offline on new directory, retains local package and never exports localStorage', () async {
    Future<Map<String, dynamic>> execute(
      String method,
      Map<String, dynamic> args,
    ) async => method == 'health'
        ? {'engine': 'vbook'}
        : {
            'data': {'name': 'Truyện mở được'},
            'storage': {'token': 'private-token'},
          };
    final old = NativeVbookRepository(
      storageDirectory: Directory('${folder.path}/old'),
      executor: execute,
    );
    await old.installBytes(_zip());
    final source = (await old.listSources()).single;
    await old.detail(
      CatalogueBook(
        ref: 'https://source.example/story',
        title: 'Truyện',
        sourceId: source.id,
        kind: ContentKind.novel,
        engine: SourceEngine.vbook,
      ),
    );
    final backup = await old.captureExtensionBackup();
    expect(jsonEncode(backup.toJson()), isNot(contains('private-token')));
    final next = NativeVbookRepository(
      storageDirectory: Directory('${folder.path}/new'),
      executor: execute,
      client: MockClient((_) async => throw StateError('No HTTP')),
    );
    await next.installBytes(_zip(name: 'Nguồn khác'));
    await next.restoreExtensionBackup(backup);
    final restart = NativeVbookRepository(
      storageDirectory: Directory('${folder.path}/new'),
      executor: execute,
    );
    expect(
      (await restart.listSources()).map((source) => source.name),
      unorderedEquals(['Nguồn mẫu', 'Nguồn khác']),
    );
    expect(
      await File('${folder.path}/new/extensions/${source.id}/storage.json')
          .exists(),
      isFalse,
    );
  });
  test('full snapshot restore opts into packages and preflights before atomic library write', () async {
    final runtime = _Runtime()..value = ExtensionBackup([_vbook()]);
    final old = MemoryLibraryRepository();
    await old.save(_book('old'));
    final bytes = await BackupService(
      old,
      extensions: _store(runtime, old, Directory('${folder.path}/old-plan')),
    ).export();
    final next = MemoryLibraryRepository();
    await next.save(_book('keep'));
    final targetRuntime = _Runtime(),
        service = BackupService(
          next,
          extensions: _store(
            targetRuntime,
            next,
            Directory('${folder.path}/next-plan'),
          ),
        );
    final preview = await service.preview(bytes);
    expect(preview.hasConfiguration, isTrue);
    await service.mergePreview(preview);
    expect(targetRuntime.restores, 0);
    final fingerprint = (await next.snapshot()).fingerprint;
    targetRuntime.invalid = true;
    await expectLater(
      service.replace(
        bytes,
        expectedFingerprint: service.fingerprint(await service.export()),
      ),
      throwsFormatException,
    );
    expect((await next.snapshot()).fingerprint, fingerprint);
    targetRuntime.invalid = false;
    await service.replace(
      bytes,
      expectedFingerprint: service.fingerprint(await service.export()),
    );
    expect(
      targetRuntime.value.packages.single.digest,
      runtime.value.packages.single.digest,
    );
    expect((await next.list()).map((book) => book.id), ['old']);
    expect(await service.exportRecovery(), isNotNull);
  });
  test('failed installation after commit preserves durable plan and recovery; restart finishes without deleting unrelated packages', () async {
    final repo = MemoryLibraryRepository();
    await repo.save(_book('before'));
    final runtime = _Runtime()..fail = true;
    final directory = Directory('${folder.path}/plan');
    final reported = <Object>[];
    final service = BackupService(
      repo,
      extensions: _store(runtime, repo, directory),
      onExtensionRestoreIncomplete: (error, _) => reported.add(error),
    );
    final incoming = LibrarySnapshot([
      LibrarySnapshotEntry(_book('after'), {}),
    ], extensions: ExtensionBackup([_vbook()]));
    final before = service.fingerprint(await service.export());
    await expectLater(
      service.replace(incoming.encode(), expectedFingerprint: before),
      throwsStateError,
    );
    expect((await repo.list()).single.id, 'after');
    expect(reported, hasLength(1));
    expect(
      (jsonDecode(await File('${directory.path}/pending.json').readAsString())
          as Map)['stage'],
      'committed',
    );
    expect(await service.exportRecovery(), isNotNull);
    runtime
      ..fail = false
      ..value = ExtensionBackup([_vbook(name: 'Khác')]);
    await BackupService(
      repo,
      extensions: _store(runtime, repo, directory),
    ).recoverPendingExtensions();
    expect(runtime.value.packages.length, 2);
    expect(await File('${directory.path}/pending.json').exists(), isFalse);
  });
  test(
    'uncommitted journal is discarded on restart without installing packages',
    () async {
      final repo = MemoryLibraryRepository();
      await repo.save(_book('old'));
      final runtime = _Runtime(), directory = Directory('${folder.path}/plan');
      final store = _store(runtime, repo, directory);
      await store.prepare(
        ExtensionBackup([_vbook()]),
        oldLibraryFingerprint: (await repo.snapshot()).fingerprint,
        newLibraryFingerprint: LibrarySnapshot([
          LibrarySnapshotEntry(_book('new'), {}),
        ]).fingerprint,
      );
      await _store(runtime, repo, directory).recoverPending();
      expect(runtime.restores, 0);
      expect(await File('${directory.path}/pending.json').exists(), isFalse);
    },
  );
  test('stale preview after an extension update rejects before any package validation or library write', () async {
    final repo = MemoryLibraryRepository();
    await repo.save(_book('old'));
    final runtime = _Runtime()..value = ExtensionBackup([_vbook(version: 1)]);
    final directory = Directory('${folder.path}/plan');
    final service = BackupService(
      repo,
      extensions: _store(runtime, repo, directory),
    );
    final preview = await service.preview(
      LibrarySnapshot([
        LibrarySnapshotEntry(_book('new'), {}),
      ], extensions: ExtensionBackup([_vbook(version: 3)])).encode(),
    );
    runtime.value = ExtensionBackup([_vbook(version: 2)]);
    await expectLater(
      service.mergePreview(preview, restoreConfiguration: true),
      throwsStateError,
    );
    expect(runtime.validations, 0);
    expect(runtime.restores, 0);
    expect((await repo.list()).single.id, 'old');
    expect(await File('${directory.path}/pending.json').exists(), false);
  });
  test('runtime mutation during asynchronous preflight is rejected by commit CAS with the prepared plan discarded', () async {
    final repo = MemoryLibraryRepository();
    await repo.save(_book('old'));
    final runtime = _Runtime()..value = ExtensionBackup([_vbook(version: 1)]);
    runtime.afterValidate = () async {
      runtime.value = ExtensionBackup([_vbook(version: 2)]);
    };
    final directory = Directory('${folder.path}/plan');
    final service = BackupService(
      repo,
      extensions: _store(runtime, repo, directory),
    );
    final before = service.fingerprint(await service.export());
    await expectLater(
      service.replace(
        LibrarySnapshot([
          LibrarySnapshotEntry(_book('new'), {}),
        ], extensions: ExtensionBackup([_vbook(version: 3)])).encode(),
        expectedFingerprint: before,
      ),
      throwsStateError,
    );
    expect(runtime.restores, 0);
    expect((await repo.list()).single.id, 'old');
    expect(await File('${directory.path}/pending.json').exists(), false);
  });
  for (final failPublication in [true, false]) {
    test(
      'configuration journal ${failPublication ? 'publication' : 'cleanup'} failure after library commit retains extension plan and restart replays it',
      () async {
        SharedPreferences.setMockInitialValues({});
        final fault = _JournalFailureStore();
        SharedPreferencesStorePlatform.instance = fault;
        final repo = MemoryLibraryRepository();
        await repo.save(_book('before'));
        final prefs = await CoordinatedPreferences.open(
          await SharedPreferences.getInstance(),
          repo,
        );
        final runtime = _Runtime(),
            directory = Directory('${folder.path}/plan');
        final service = BackupService(
          repo,
          configuration: AppConfigurationStore(prefs),
          extensions: _store(runtime, repo, directory),
        );
        final before = service.fingerprint(await service.export());
        fault
          ..failPublication = failPublication
          ..failCleanup = !failPublication;
        await expectLater(
          service.replace(
            LibrarySnapshot(
              [LibrarySnapshotEntry(_book('after'), {})],
              configuration: BackupConfiguration.fromJson({
                'version': 1,
                'preferences': {'dark': false},
              }),
              extensions: ExtensionBackup([_vbook()]),
            ).encode(),
            expectedFingerprint: before,
          ),
          throwsStateError,
        );
        expect((await repo.list()).single.id, 'after');
        expect(runtime.restores, 0);
        expect(await File('${directory.path}/pending.json').exists(), true);
        fault
          ..failPublication = false
          ..failCleanup = false;
        await CoordinatedPreferences.open(prefs, repo);
        await _store(runtime, repo, directory).recoverPending();
        expect(prefs.getBool('dark'), false);
        expect(runtime.restores, 1);
        expect(await File('${directory.path}/pending.json').exists(), false);
        expect(await service.exportRecovery(), isNotNull);
      },
    );
  }
  test('prepared journal whose new library already committed promotes and replays after restart', () async {
    final repo = MemoryLibraryRepository();
    await repo.save(_book('old'));
    final runtime = _Runtime(), directory = Directory('${folder.path}/plan');
    final old = (await repo.snapshot()).fingerprint;
    final next = LibrarySnapshot([LibrarySnapshotEntry(_book('new'), {})]);
    await _store(runtime, repo, directory).prepare(
      ExtensionBackup([_vbook()]),
      oldLibraryFingerprint: old,
      newLibraryFingerprint: next.fingerprint,
    );
    await repo.replaceSnapshot(next, expectedFingerprint: old);
    await _store(runtime, repo, directory).recoverPending();
    expect(runtime.restores, 1);
    expect(await File('${directory.path}/pending.json').exists(), false);
  });
  test('same-library interruption remains explicit and retry completes without inferring a commit', () async {
    final repo = MemoryLibraryRepository(), runtime = _Runtime();
    final directory = Directory('${folder.path}/plan');
    final store = _store(runtime, repo, directory),
        fingerprint = (await repo.snapshot()).fingerprint;
    await store.prepare(
      ExtensionBackup([_vbook()]),
      oldLibraryFingerprint: fingerprint,
      newLibraryFingerprint: fingerprint,
    );
    final bytes = await File('${directory.path}/pending.json').readAsBytes();
    await expectLater(
      _store(runtime, repo, directory).recoverPending(),
      throwsStateError,
    );
    expect(runtime.restores, 0);
    expect(await File('${directory.path}/pending.json').readAsBytes(), bytes);
    await store.complete();
    expect(runtime.restores, 1);
    expect(await File('${directory.path}/pending.json').exists(), false);
  });
  test('changed library and malformed journal preserve every byte without installing a stale plan', () async {
    final repo = MemoryLibraryRepository(), runtime = _Runtime();
    await repo.save(_book('old'));
    final directory = Directory('${folder.path}/plan'),
        store = _store(runtime, repo, Directory('${folder.path}/plan'));
    await store.prepare(
      ExtensionBackup([_vbook()]),
      oldLibraryFingerprint: (await repo.snapshot()).fingerprint,
      newLibraryFingerprint: LibrarySnapshot([
        LibrarySnapshotEntry(_book('new'), {}),
      ]).fingerprint,
    );
    await repo.save(_book('changed'));
    final journal = File('${directory.path}/pending.json'),
        bytes = await File('${directory.path}/pending.json').readAsBytes();
    await expectLater(store.recoverPending(), throwsStateError);
    await expectLater(store.complete(), throwsStateError);
    expect(await journal.readAsBytes(), bytes);
    for (final raw in [
      '{broken',
      jsonEncode({
        ...jsonDecode(utf8.decode(bytes)) as Map,
        'cookie': 'private',
      }),
    ]) {
      await journal.writeAsString(raw);
      await expectLater(store.recoverPending(), throwsFormatException);
      expect(await journal.readAsString(), raw);
    }
    expect(runtime.restores, 0);
  });
  test('runtime mutation leases serialize across handles, reenter during restore, and release after errors', () async {
    final held = Completer<void>(),
        release = Completer<void>(),
        order = <String>[];
    final first = ExtensionMutationQueue.run('fixture', () async {
      order.add('capture');
      held.complete();
      await release.future;
      await ExtensionMutationQueue.run('fixture', () async {
        order.add('restore');
      });
    });
    await held.future;
    final second = ExtensionMutationQueue.run('fixture', () async {
      order.add('edit');
    });
    await Future<void>.delayed(Duration.zero);
    expect(order, ['capture']);
    release.complete();
    await Future.wait([first, second]);
    expect(order, ['capture', 'restore', 'edit']);
    await expectLater(
      ExtensionMutationQueue.run('fixture', () async {
        throw StateError('fail');
      }),
      throwsStateError,
    );
    await ExtensionMutationQueue.run('fixture', () async {
      order.add('released');
    });
    expect(order.last, 'released');
  });
  test('vBook restore lease holds competing package publication but allows source reads', () async {
    final directory = Directory('${folder.path}/runtime');
    Future<Map<String, dynamic>> execute(
      String method,
      Map<String, dynamic> args,
    ) async => {'engine': 'vbook'};
    final original = NativeVbookRepository(
      storageDirectory: directory,
      executor: execute,
    );
    await original.installBytes(_zip());
    final other = NativeVbookRepository(
      storageDirectory: directory,
      executor: execute,
    );
    await other.listSources();
    final held = Completer<void>(), release = Completer<void>();
    final operation = original.exclusiveExtensionBackup(() async {
      held.complete();
      await release.future;
      await original.restoreExtensionBackup(
        ExtensionBackup([_vbook(version: 2)]),
      );
    });
    await held.future;
    var installed = false;
    final competing = other
        .installBytes(_zip(name: 'Khác'))
        .then((_) => installed = true);
    expect((await other.listSources()).single.name, 'Nguồn mẫu');
    expect(installed, false);
    release.complete();
    await Future.wait([operation, competing]);
    expect(
      (await other.listSources()).map((source) => source.name),
      unorderedEquals(['Nguồn mẫu', 'Khác']),
    );
  });
  test('extension bytes stay in bounded reusable sync chunks; old clients preserve packages; conflicts are per package', () {
    Uint8List snapshot(ExtensionBackup? bundle) =>
        LibrarySnapshot([], extensions: bundle).encode();
    final oldPackage = _vbook(version: 1),
        nextPackage = _vbook(version: 2),
        another = _vbook(name: 'Khác');
    final local = snapshot(ExtensionBackup([oldPackage]));
    final plan = SyncChunkPlan.build(local);
    expect(plan.manifest.length, lessThan(local.length));
    expect(SyncChunkPlan.assemble(plan.manifest, plan.chunks), local);
    final retained = SyncMergePlan.tryBuild(
      snapshot(null),
      local,
      baseline: local,
    )!.encode({});
    expect(
      (jsonDecode(utf8.decode(retained)) as Map)['extensions'],
      ExtensionBackup([oldPackage]).toJson(),
    );
    final union = SyncMergePlan.tryBuild(
      local,
      snapshot(ExtensionBackup([another])),
    )!.encode({});
    expect(
      ((jsonDecode(utf8.decode(union)) as Map)['extensions']
          as Map)['packages'],
      hasLength(2),
    );
    final conflict = SyncMergePlan.tryBuild(
      local,
      snapshot(ExtensionBackup([nextPackage])),
    )!;
    expect(conflict.conflicts.single.key, 'extension:${oldPackage.identity}');
    final selected = conflict.encode({conflict.conflicts.single.key: false});
    expect(
      ExtensionBackup.fromJson(
        (jsonDecode(utf8.decode(selected)) as Map)['extensions'],
      ).packages.single.digest,
      nextPackage.digest,
    );
  });
}
