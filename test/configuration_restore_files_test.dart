import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:isar_community/isar.dart';
import 'package:shared_preferences/shared_preferences.dart';
// Exercise the same platform boundary used by SharedPreferences.
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:tachi_books/features/library/data/backup_configuration.dart';
import 'package:tachi_books/features/library/data/backup_service.dart';
import 'package:tachi_books/features/library/data/configuration_restore_files.dart';
import 'package:tachi_books/features/library/data/coordinated_preferences.dart';
import 'package:tachi_books/features/library/data/library_repository.dart';
import 'package:tachi_books/features/library/data/library_snapshot.dart';
import 'package:tachi_books/features/library/domain/library_book.dart';

BackupConfiguration _configuration(bool dark, {double fontSize = 20}) =>
    BackupConfiguration.fromJson({
      'version': 1,
      'preferences': {'dark': dark, 'fontSize': fontSize},
    });

Future<void> _seed(LibraryRepository repo, String id) =>
    repo.save(LibraryBook(id: id, title: id, kind: 'manga', engine: 'local'));

Map<String, dynamic> _journal({
  required String beforeFingerprint,
  required String afterFingerprint,
  String phase = 'prepared',
}) => {
  'version': 1,
  'phase': phase,
  'oldLibrary': beforeFingerprint,
  'newLibrary': afterFingerprint,
  'before': _configuration(true).toJson(),
  'after': _configuration(false, fontSize: 30).toJson(),
};

class _FaultStore extends InMemorySharedPreferencesStore {
  _FaultStore(Map<String, Object> values)
    : super.withData({
        for (final entry in values.entries) 'flutter.${entry.key}': entry.value,
      });
  String? failKey;
  int failures = 0;
  Future<void> Function()? afterSet, afterClear;
  bool clearResult = true;
  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    if (key == 'flutter.$failKey' && failures-- > 0) return false;
    final result = await super.setValue(valueType, key, value);
    await afterSet?.call();
    return result;
  }

  @override
  Future<bool> clear() async {
    await super.clear();
    await afterClear?.call();
    return clearResult;
  }
}

class _CommitFailure extends MemoryLibraryRepository {
  @override
  Future<void> replaceSnapshotWithConfiguration(
    LibrarySnapshot incoming, {
    required String expectedFingerprint,
    required Uint8List recovery,
    required Future<void> Function() beforeCommit,
  }) async {
    await beforeCommit();
    throw StateError('Simulated database commit failure.');
  }
}

Future<CoordinatedPreferences> _open(
  LibraryRepository repo,
  Directory directory,
  Map<String, Object> values,
) async {
  SharedPreferences.setMockInitialValues(values);
  return CoordinatedPreferences.open(
    await SharedPreferences.getInstance(),
    repo,
    journalDirectoryPath: directory.path,
  );
}

Future<CoordinatedPreferences> _restart(
  LibraryRepository repo,
  Directory directory,
) async {
  SharedPreferences.resetStatic();
  return CoordinatedPreferences.open(
    await SharedPreferences.getInstance(),
    repo,
    journalDirectoryPath: directory.path,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late ConfigurationRestoreFiles files;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('config-journal-');
    files = ConfigurationRestoreFiles(directory.path);
    SharedPreferences.setMockInitialValues({});
  });
  tearDown(() async {
    // Only delete the independently allocated test directory.
    await directory.delete(recursive: true);
  });

  test(
    'Apple system alias and physical directory reopen the same checkpoint',
    () async {
      final physical = ConfigurationRestoreFiles(
        await directory.resolveSymbolicLinks(),
      );
      await files.writeCheckpoint(_configuration(true));
      expect(physical.directory.path, files.directory.path);
      expect(
        (await physical.readCheckpoint())!.values,
        _configuration(true).values,
      );
      await physical.writeCheckpoint(_configuration(false));
      expect(
        (await files.readCheckpoint())!.values,
        _configuration(false).values,
      );
    },
    skip: !(Platform.isMacOS || Platform.isIOS),
  );

  test(
    'caller-owned symlink parents remain rejected without touching targets',
    () async {
      final target = Directory('${directory.path}/original');
      await target.create();
      final original = File('${target.path}/input.txt');
      await original.writeAsString('original bytes');
      final link = Link('${directory.path}/redirect');
      await link.create(target.path);
      try {
        final redirected = ConfigurationRestoreFiles('${link.path}/nested');
        await expectLater(
          redirected.writeCheckpoint(_configuration(true)),
          throwsA(isA<FileSystemException>()),
        );
        expect(await Directory('${target.path}/nested').exists(), false);
        expect(await original.readAsString(), 'original bytes');
      } finally {
        await link.delete();
      }
    },
    skip: Platform.isWindows
        ? 'Symlink creation requires Windows privileges.'
        : false,
  );

  test(
    'file checkpoints replace the previous image and leave no pending file',
    () async {
      final unrelated = File('${directory.path}/original-source.txt');
      await unrelated.writeAsString('input bytes stay unchanged');
      await files.writeCheckpoint(_configuration(true));
      await files.writeCheckpoint(_configuration(false, fontSize: 30));
      expect((await files.readCheckpoint())!.values, {
        'dark': false,
        'fontSize': 30.0,
      });
      expect(await File('${files.checkpointPath}.pending').exists(), false);
      expect(await unrelated.readAsString(), 'input bytes stay unchanged');
    },
  );

  test(
    'oversized and malformed checkpoint/journal files are retained',
    () async {
      for (final entry in [
        (
          files.checkpointPath,
          BackupConfiguration.maxBytes,
          files.readCheckpoint,
        ),
        (
          files.journalPath,
          BackupConfiguration.maxBytes * 2 + 4096,
          files.readJournal,
        ),
      ]) {
        final input = File(entry.$1);
        await input.writeAsBytes(List<int>.filled(entry.$2 + 1, 32));
        await expectLater(entry.$3(), throwsFormatException);
        expect(await input.length(), entry.$2 + 1);
      }
      await File(files.checkpointPath).writeAsString('{malformed');
      await expectLater(files.readCheckpoint(), throwsFormatException);
      expect(await File(files.checkpointPath).readAsString(), '{malformed');
      await File(files.journalPath).writeAsBytes([0xff]);
      await expectLater(files.readJournal(), throwsFormatException);
      expect(await File(files.journalPath).readAsBytes(), [0xff]);
    },
  );

  test('destination/pending/directory collisions are rejected without overwriting them', () async {
    final pending = Directory('${files.checkpointPath}.pending');
    await pending.create();
    await expectLater(
      files.writeCheckpoint(_configuration(true)),
      throwsA(isA<FileSystemException>()),
    );
    expect(await pending.exists(), true);
    await pending.delete();
    await Directory(files.checkpointPath).create();
    await expectLater(
      files.readCheckpoint(),
      throwsA(isA<FileSystemException>()),
    );
    await expectLater(
      files.writeCheckpoint(_configuration(true)),
      throwsA(isA<FileSystemException>()),
    );
    expect(await Directory(files.checkpointPath).exists(), true);
    final blockedParent = File('${directory.path}/file-as-directory');
    await blockedParent.writeAsString('not a directory');
    await expectLater(
      ConfigurationRestoreFiles('${blockedParent.path}/nested').readJournal(),
      throwsA(isA<FileSystemException>()),
    );
    expect(await blockedParent.readAsString(), 'not a directory');
  });

  test('checkpoint replays portable settings after a stale preference restart, preserving local secrets', () async {
    final repo = MemoryLibraryRepository();
    final prefs = await _open(repo, directory, {
      'dark': true,
      'fontSize': 20.0,
      'privacyV1': 'this device',
      'oauthToken': 'session token',
    });
    await prefs.setBool('dark', false);
    await prefs.setDouble('fontSize', 30);
    SharedPreferences.setMockInitialValues({
      'dark': true,
      'fontSize': 20.0,
      'privacyV1': 'this device',
      'oauthToken': 'session token',
    });
    final restarted = await _restart(repo, directory);
    expect(restarted.getBool('dark'), false);
    expect(restarted.getDouble('fontSize'), 30);
    expect(restarted.getString('privacyV1'), 'this device');
    expect(restarted.getString('oauthToken'), 'session token');
    expect(
      await File(files.checkpointPath).readAsString(),
      isNot(contains('token')),
    );
  });

  test('prepared file journal selects before/after using the actual committed book fingerprint', () async {
    final old = MemoryLibraryRepository(), newer = MemoryLibraryRepository();
    await _seed(old, 'old');
    await _seed(newer, 'new');
    final journal = _journal(
      beforeFingerprint: (await old.snapshot()).fingerprint,
      afterFingerprint: (await newer.snapshot()).fingerprint,
    );
    for (final entry in [(old, true, 20.0), (newer, false, 30.0)]) {
      // Simulate a crash with an incoming checkpoint and stale raw preferences.
      await files.writeJournal(journal);
      await files.writeCheckpoint(_configuration(false, fontSize: 30));
      final prefs = await _open(entry.$1, directory, {
        'dark': true,
        'fontSize': 999.0,
        'privacyV1': 'local',
      });
      expect(prefs.getBool('dark'), entry.$2);
      expect(prefs.getDouble('fontSize'), entry.$3);
      expect(prefs.getString('privacyV1'), 'local');
      expect((await files.readCheckpoint())!.values['dark'], entry.$2);
      expect(await files.readJournal(), isNull);
    }
  });

  test(
    'configuration-only prepared restart follows its durable checkpoint',
    () async {
      final repo = MemoryLibraryRepository();
      await _seed(repo, 'same');
      final fingerprint = (await repo.snapshot()).fingerprint;
      for (final checkpoint in [
        _configuration(true),
        _configuration(false, fontSize: 30),
      ]) {
        await files.writeJournal(
          _journal(
            beforeFingerprint: fingerprint,
            afterFingerprint: fingerprint,
          ),
        );
        await files.writeCheckpoint(checkpoint);
        final prefs = await _open(repo, directory, {
          'dark': true,
          'fontSize': 999.0,
          'oauthToken': 'local',
        });
        expect(BackupConfiguration.capture(prefs).values, checkpoint.values);
        expect(prefs.getString('oauthToken'), 'local');
        expect(await files.readJournal(), isNull);
      }
    },
  );

  test(
    'configuration-only prepared restart without a checkpoint restores before',
    () async {
      final repo = MemoryLibraryRepository();
      final fingerprint = (await repo.snapshot()).fingerprint;
      final journal = _journal(
        beforeFingerprint: fingerprint,
        afterFingerprint: fingerprint,
      );
      for (final useFile in [true, false]) {
        if (useFile) await files.writeJournal(journal);
        SharedPreferences.setMockInitialValues({
          'dark': false,
          'fontSize': 30.0,
          if (!useFile) CoordinatedPreferences.journalKey: jsonEncode(journal),
        });
        final prefs = await CoordinatedPreferences.open(
          await SharedPreferences.getInstance(),
          repo,
          journalDirectoryPath: useFile ? directory.path : null,
        );
        expect(
          BackupConfiguration.capture(prefs).values,
          _configuration(true).values,
        );
        expect(prefs.containsKey(CoordinatedPreferences.journalKey), false);
      }
    },
  );

  test('configuration-only prepared checkpoint mismatch preserves evidence and blocks startup', () async {
    final repo = MemoryLibraryRepository();
    final fingerprint = (await repo.snapshot()).fingerprint;
    await files.writeJournal(
      _journal(beforeFingerprint: fingerprint, afterFingerprint: fingerprint),
    );
    await files.writeCheckpoint(_configuration(true, fontSize: 40));
    final checkpointBytes = await File(files.checkpointPath).readAsBytes();
    final journalBytes = await File(files.journalPath).readAsBytes();
    await expectLater(_open(repo, directory, {'dark': true}), throwsStateError);
    expect(await File(files.checkpointPath).readAsBytes(), checkpointBytes);
    expect(await File(files.journalPath).readAsBytes(), journalBytes);
  });

  test('configuration-only interrupted rollback chooses before even with incoming checkpoint', () async {
    final repo = MemoryLibraryRepository();
    final fingerprint = (await repo.snapshot()).fingerprint;
    await files.writeJournal(
      _journal(
        beforeFingerprint: fingerprint,
        afterFingerprint: fingerprint,
        phase: 'rollback',
      ),
    );
    await files.writeCheckpoint(_configuration(false, fontSize: 30));
    final prefs = await _open(repo, directory, {'dark': false});
    expect(
      BackupConfiguration.capture(prefs).values,
      _configuration(true).values,
    );
    expect((await files.readCheckpoint())!.values, _configuration(true).values);
    expect(await files.readJournal(), isNull);
  });

  test('ambiguous or corrupt file journal blocks startup and keeps all bytes unchanged', () async {
    final repo = MemoryLibraryRepository();
    await _seed(repo, 'other');
    await files.writeCheckpoint(_configuration(true));
    final checkpointBytes = await File(files.checkpointPath).readAsBytes();
    for (final raw in [
      jsonEncode(
        _journal(beforeFingerprint: '0' * 64, afterFingerprint: '1' * 64),
      ),
      '{malformed',
    ]) {
      await File(files.journalPath).writeAsString(raw);
      SharedPreferences.setMockInitialValues({
        'dark': true,
        'oauthToken': 'local',
      });
      final prefs = await SharedPreferences.getInstance();
      await expectLater(
        CoordinatedPreferences.open(
          prefs,
          repo,
          journalDirectoryPath: directory.path,
        ),
        raw.startsWith('{malformed') ? throwsFormatException : throwsStateError,
      );
      expect(await File(files.journalPath).readAsString(), raw);
      expect(await File(files.checkpointPath).readAsBytes(), checkpointBytes);
      expect(prefs.getBool('dark'), true);
      expect(prefs.getString('oauthToken'), 'local');
    }
  });

  test(
    'committed journal cleanup preserves the newest durable checkpoint',
    () async {
      final repo = MemoryLibraryRepository();
      await _seed(repo, 'later-book');
      await files.writeJournal(
        _journal(
          beforeFingerprint: '0' * 64,
          afterFingerprint: '1' * 64,
          phase: 'committed',
        ),
      );
      await files.writeCheckpoint(_configuration(true, fontSize: 40));
      final prefs = await _open(repo, directory, {
        'dark': false,
        'fontSize': 20.0,
      });
      expect(prefs.getBool('dark'), true);
      expect(prefs.getDouble('fontSize'), 40);
      expect(await repo.find('later-book'), isNotNull);
      expect(await files.readJournal(), isNull);
    },
  );

  test('failed portable platform write restores cache without changing the checkpoint', () async {
    final repo = MemoryLibraryRepository();
    final store = _FaultStore({'dark': true, 'fontSize': 20.0});
    SharedPreferencesStorePlatform.instance = store;
    final prefs = await _restart(repo, directory);
    store.failKey = 'dark';
    store.failures = 1;
    expect(await prefs.setBool('dark', false), false);
    expect(prefs.getBool('dark'), true);
    expect((await files.readCheckpoint())!.values['dark'], true);
    expect((await _restart(repo, directory)).getBool('dark'), true);
  });

  test('checkpoint write failure rolls a normal edit back and restart replays the old image', () async {
    final repo = MemoryLibraryRepository();
    final store = _FaultStore({
      'dark': true,
      'fontSize': 20.0,
      'privacyV1': 'local',
    });
    SharedPreferencesStorePlatform.instance = store;
    final prefs = await _restart(repo, directory);
    final pending = Directory('${files.checkpointPath}.pending');
    store.afterSet = () async {
      if (!await pending.exists()) await pending.create();
    };
    await expectLater(
      prefs.setBool('dark', false),
      throwsA(isA<FileSystemException>()),
    );
    expect(prefs.getBool('dark'), true);
    expect(prefs.getString('privacyV1'), 'local');
    expect((await files.readCheckpoint())!.values['dark'], true);
    store.afterSet = null;
    await pending.delete();
    final restarted = await _restart(repo, directory);
    expect(restarted.getBool('dark'), true);
    expect(restarted.getString('privacyV1'), 'local');
  });

  test('failed clear restores public settings and every local secret without exporting secrets', () async {
    final repo = MemoryLibraryRepository();
    final original = <String, Object>{
      'dark': true,
      'fontSize': 20.0,
      'privacyV1': 'device lock',
      'oauthToken': 'private token',
      'syncLinkV1': 'local link',
      'nonportableList': ['a', 'b'],
    };
    final store = _FaultStore(original);
    SharedPreferencesStorePlatform.instance = store;
    final prefs = await _restart(repo, directory);
    final pending = Directory('${files.checkpointPath}.pending');
    store.afterClear = pending.create;
    await expectLater(prefs.clear(), throwsA(isA<FileSystemException>()));
    expect({for (final key in prefs.getKeys()) key: prefs.get(key)}, original);
    expect(
      await File(files.checkpointPath).readAsString(),
      isNot(contains('private')),
    );
    store.afterClear = null;
    await pending.delete();
    final restarted = await _restart(repo, directory);
    expect({
      for (final key in restarted.getKeys()) key: restarted.get(key),
    }, original);
  });

  test(
    'false clear result restores local secrets even without file persistence',
    () async {
      final store = _FaultStore({'dark': true, 'oauthToken': 'local'})
        ..clearResult = false;
      SharedPreferencesStorePlatform.instance = store;
      SharedPreferences.resetStatic();
      final prefs = await CoordinatedPreferences.open(
        await SharedPreferences.getInstance(),
        MemoryLibraryRepository(),
      );
      expect(await prefs.clear(), false);
      expect(prefs.getBool('dark'), true);
      expect(prefs.getString('oauthToken'), 'local');
    },
  );

  test('database commit failure restores both raw and durable configuration, removing the prepared journal', () async {
    final repo = _CommitFailure();
    await _seed(repo, 'old');
    final prefs = await _open(repo, directory, {
      'dark': true,
      'fontSize': 20.0,
      'privacyV1': 'local',
    });
    final backup = BackupService(
      repo,
      configuration: AppConfigurationStore(prefs),
    );
    final before = await backup.export();
    final source = MemoryLibraryRepository();
    await _seed(source, 'new');
    SharedPreferences.setMockInitialValues({'dark': false, 'fontSize': 30.0});
    final sourcePrefs = await CoordinatedPreferences.open(
      await SharedPreferences.getInstance(),
      source,
    );
    final incoming = await BackupService(
      source,
      configuration: AppConfigurationStore(sourcePrefs),
    ).export();
    await expectLater(
      backup.replace(incoming, expectedFingerprint: backup.fingerprint(before)),
      throwsStateError,
    );
    expect(await backup.export(), before);
    expect((await files.readCheckpoint())!.values, _configuration(true).values);
    expect(await files.readJournal(), isNull);
    expect(prefs.getString('privacyV1'), 'local');
  });

  test('configuration-only failed commit and failed rollback recover before on restart', () async {
    final repo = _CommitFailure();
    await _seed(repo, 'same');
    final store = _FaultStore({
      'dark': true,
      'fontSize': 20.0,
      'oauthToken': 'local',
    });
    SharedPreferencesStorePlatform.instance = store;
    final prefs = await _restart(repo, directory);
    final before = BackupConfiguration.capture(prefs);
    final fingerprint = (await repo.snapshot()).fingerprint;
    final pending = Directory('${files.checkpointPath}.pending');
    store.afterSet = () async {
      if (!await pending.exists()) await pending.create();
    };
    await expectLater(
      prefs.exclusive(
        () => prefs.restoreLocked(
          incoming: _configuration(false, fontSize: 30),
          expectedFingerprint: before.fingerprint,
          oldLibraryFingerprint: fingerprint,
          newLibraryFingerprint: fingerprint,
          commit: (beforeCommit) async {
            await beforeCommit();
            throw StateError('Simulated same-library commit failure.');
          },
        ),
      ),
      throwsStateError,
    );
    // The old image could not be written, but the rollback decision survived.
    expect((await files.readCheckpoint())!.values['dark'], false);
    expect(jsonDecode((await files.readJournal())!)['phase'], 'rollback');
    await expectLater(prefs.setBool('dark', true), throwsStateError);
    store.afterSet = null;
    await pending.delete();
    final restarted = await _restart(repo, directory);
    expect(
      BackupConfiguration.capture(restarted).fingerprint,
      before.fingerprint,
    );
    expect(restarted.getString('oauthToken'), 'local');
    expect((await repo.snapshot()).fingerprint, fingerprint);
    expect(await files.readJournal(), isNull);
  });

  test('partial preference/rollback failure keeps a rollback file journal and restart repairs it', () async {
    final source = MemoryLibraryRepository();
    await _seed(source, 'new');
    SharedPreferences.setMockInitialValues({'dark': false, 'fontSize': 30.0});
    final sourcePrefs = await CoordinatedPreferences.open(
      await SharedPreferences.getInstance(),
      source,
    );
    final incoming = await BackupService(
      source,
      configuration: AppConfigurationStore(sourcePrefs),
    ).export();
    final repo = MemoryLibraryRepository();
    await _seed(repo, 'old');
    final store = _FaultStore({
      'dark': true,
      'fontSize': 20.0,
      'oauthToken': 'local',
    });
    SharedPreferencesStorePlatform.instance = store;
    final prefs = await _restart(repo, directory);
    final backup = BackupService(
      repo,
      configuration: AppConfigurationStore(prefs),
    );
    final before = await backup.export();
    store.failKey = 'fontSize';
    store.failures = 2;
    await expectLater(
      backup.replace(incoming, expectedFingerprint: backup.fingerprint(before)),
      throwsStateError,
    );
    expect(await repo.find('new'), isNull);
    expect(jsonDecode((await files.readJournal())!)['phase'], 'rollback');
    await expectLater(backup.export(), throwsStateError);
    final repaired = await _restart(repo, directory);
    expect(
      BackupConfiguration.capture(repaired).values,
      _configuration(true).values,
    );
    expect(repaired.getString('oauthToken'), 'local');
    expect(await files.readJournal(), isNull);
  });

  test(
    'real Isar and file checkpoint reopen after full restore with cached offline contents',
    () async {
      final libraryPath = Platform.environment['TACHI_ISAR_TEST_LIBRARY']!;
      Isar.initializeIsarCore(libraries: {Abi.windowsX64: libraryPath});
      LibraryRepository? repo;
      final books = Directory('${directory.path}/books');
      await books.create();
      try {
        repo = await LibraryRepository.open(directoryPath: books.path);
        await _seed(repo, 'old');
        final prefs = await _open(
          repo,
          Directory('${directory.path}/configuration'),
          {'dark': true, 'fontSize': 20.0, 'privacyV1': 'local'},
        );
        final backup = BackupService(
          repo,
          configuration: AppConfigurationStore(prefs),
        );
        final before = await backup.export();
        final source = MemoryLibraryRepository();
        await source.save(
          LibraryBook(
            id: 'new',
            title: 'new',
            kind: 'novel',
            engine: 'local',
            chapters: [
              BookChapter(
                id: 'new-0',
                title: 'chapter',
                index: 0,
                downloaded: true,
              ),
            ],
          ),
        );
        await source.saveChapter(
          'new',
          0,
          ReaderContent(kind: 'novel', html: '<p>Full offline content.</p>'),
        );
        SharedPreferences.setMockInitialValues({
          'dark': false,
          'fontSize': 30.0,
        });
        final sourcePrefs = await CoordinatedPreferences.open(
          await SharedPreferences.getInstance(),
          source,
        );
        final incoming = await BackupService(
          source,
          configuration: AppConfigurationStore(sourcePrefs),
        ).export();
        await backup.replace(
          incoming,
          expectedFingerprint: backup.fingerprint(before),
        );
        await repo.close();
        repo = null;
        repo = await LibraryRepository.open(directoryPath: books.path);
        SharedPreferences.setMockInitialValues({
          'dark': true,
          'fontSize': 20.0,
          'privacyV1': 'local',
        });
        final restarted = await _restart(
          repo,
          Directory('${directory.path}/configuration'),
        );
        final reopened = BackupService(
          repo,
          configuration: AppConfigurationStore(restarted),
        );
        expect(
          reopened.fingerprint(await reopened.export()),
          reopened.fingerprint(incoming),
        );
        expect(
          (await repo.readChapter('new', 0))!.html,
          '<p>Full offline content.</p>',
        );
        expect(
          reopened.fingerprint((await reopened.exportRecovery())!),
          reopened.fingerprint(before),
        );
        expect(restarted.getString('privacyV1'), 'local');
      } finally {
        await repo?.close();
      }
    },
    skip: Platform.environment['TACHI_ISAR_TEST_LIBRARY'] == null
        ? 'Set the verified Isar native library path.'
        : false,
  );
}
