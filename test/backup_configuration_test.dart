import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:isar_community/isar.dart';
import 'package:shared_preferences/shared_preferences.dart';
// Fault injection uses the same platform boundary as the installed plugin.
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:tachi_books/features/downloads/presentation/download_deletion_controller.dart';
import 'package:tachi_books/features/library/application/backup_service_provider.dart';
import 'package:tachi_books/features/library/data/backup_configuration.dart';
import 'package:tachi_books/features/library/data/backup_service.dart';
import 'package:tachi_books/features/library/data/coordinated_preferences.dart';
import 'package:tachi_books/features/library/data/library_repository.dart';
import 'package:tachi_books/features/library/data/library_snapshot.dart';
import 'package:tachi_books/features/library/domain/library_book.dart';
import 'package:tachi_books/features/library/domain/library_categories.dart';
import 'package:tachi_books/features/library/presentation/library_category_controller.dart';
import 'package:tachi_books/features/library/presentation/library_filter_sheet.dart';
import 'package:tachi_books/features/library/presentation/library_view_model.dart';
import 'package:tachi_books/features/reader/domain/reader_options.dart';
import 'package:tachi_books/features/reader/presentation/reader_options_controller.dart';
import 'package:tachi_books/features/settings/settings_controller.dart';
import 'package:tachi_books/features/sync/data/backup_sync_local.dart';
import 'package:tachi_books/features/sync/data/sync_link_store.dart';
import 'package:tachi_books/features/sync/domain/sync_engine.dart';

import 'support/sync_fakes.dart';

const _png =
    'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jf1kAAAAASUVORK5CYII=';
Future<void> _seed(
  LibraryRepository repository, {
  String id = 'old',
  double progress = .4,
}) async {
  await repository.save(
    LibraryBook(
      id: id,
      title: id,
      kind: 'manga',
      engine: 'local',
      cover: _png,
      progress: progress,
      bookmarks: ['0:0.2'],
      chapters: [
        BookChapter(id: '$id-0', title: '1', index: 0, downloaded: true),
      ],
    ),
  );
  await repository.saveChapter(
    id,
    0,
    ReaderContent(kind: 'manga', images: [_png]),
  );
}

Map<String, Object> _portable() => {
  'dark': false,
  'appearanceV1': 'system',
  'libraryColumns': 4,
  'downloadConcurrency': 3,
  'fontSize': 28.0,
  'lineHeight': 1.8,
  'readerTheme': 'sepia',
  'font': 'NotoSans',
  'mangaMode': 'rtl',
  'pinnedSources': ['tachimanga:9007199254740993', 'vbook:books'],
  'recentSources': ['vbook:books'],
  'libraryGrouping': 'author',
  'readingGoalMinutes': 45,
  'readSeconds:2026-10-8': 1234,
  'sourceCatalogueLayoutV1': 'comfortable',
  'savedSourceFiltersV1': jsonEncode({
    'tachimanga:9007199254740993': {
      'My search': {
        'schema': '1' * 64,
        'filters': [
          {
            'name': 'Tác giả',
            'type': 'text',
            'supported': true,
            'state': 'Writer',
          },
          {
            'name': 'Sort',
            'type': 'sort',
            'supported': true,
            'values': ['Title', 'Date'],
            'state': {'index': 1, 'ascending': false},
          },
        ],
      },
    },
  }),
  'extensionRepositoriesV1': jsonEncode([
    {
      'engine': 'tachimanga',
      'url': 'https://raw.githubusercontent.com/keiyoushi/extensions/repo/index.pb',
    },
    {'engine': 'vbook', 'url': 'https://example.org/plugins.json'},
  ]),
  'libraryCategoriesV1': jsonEncode(
    LibraryCategoryRegistry(
      categories: [
        const LibraryCategory(name: 'Series', update: CategoryPolicy.exclude),
      ],
      defaultCategories: ['Series'],
    ).toJson(),
  ),
  'libraryGroupOrderV1': jsonEncode({
    'author': ['value:Writer', 'unknown'],
  }),
  'libraryFilterV1': jsonEncode({
    'filter': const LibraryFilter(unread: LibraryTriState.include).toJson(),
    'sorts': {
      jsonEncode(['author', 'value:Writer']): const LibraryFilter(
        order: LibraryOrder.title,
      ).toJson(),
    },
  }),
  'readerOptionsV1': jsonEncode(
    const ReaderOptions(gap: 3, grayscale: true, skipRead: true).toJson(),
  ),
  'libraryUpdatePolicyV1': jsonEncode({
    'hours': 24,
    'downloadAhead': 3,
    'downloadNew': true,
    'wifiOnly': true,
  }),
  'downloadDeletionPolicyV1': jsonEncode({
    'afterReading': true,
    'protectBookmarks': true,
  }),
  'automaticBackupPolicyV1': jsonEncode({'hours': 24, 'keep': 5}),
};
Future<({BackupService backup, CoordinatedPreferences prefs})> _service(
  LibraryRepository repository,
  Map<String, Object> values,
) async {
  SharedPreferences.setMockInitialValues(values);
  final prefs = await CoordinatedPreferences.open(
    await SharedPreferences.getInstance(),
    repository,
  );
  return (
    backup: BackupService(
      repository,
      configuration: AppConfigurationStore(prefs),
    ),
    prefs: prefs,
  );
}

Uint8List _encode(Object? value) =>
    Uint8List.fromList(utf8.encode(jsonEncode(value)));
Map<String, dynamic> _decode(Uint8List value) =>
    jsonDecode(utf8.decode(value)) as Map<String, dynamic>;

class _FailingStore extends InMemorySharedPreferencesStore {
  _FailingStore(Map<String, Object> values)
    : super.withData({
        for (final entry in values.entries) 'flutter.${entry.key}': entry.value,
      });
  String? failKey;
  int remainingFailures = 0;
  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    if (key == 'flutter.$failKey' && remainingFailures-- > 0) return false;
    return super.setValue(valueType, key, value);
  }
}

class _FailingCommitRepository extends MemoryLibraryRepository {
  @override
  Future<void> replaceSnapshotWithConfiguration(
    LibrarySnapshot incoming, {
    required String expectedFingerprint,
    required Uint8List recovery,
    required Future<void> Function() beforeCommit,
  }) async {
    await beforeCommit();
    throw StateError('DB commit failed');
  }
}

class _DelayedCommitRepository extends MemoryLibraryRepository {
  final staged = Completer<void>(), resume = Completer<void>();
  @override
  Future<void> replaceSnapshotWithConfiguration(
    LibrarySnapshot incoming, {
    required String expectedFingerprint,
    required Uint8List recovery,
    required Future<void> Function() beforeCommit,
  }) async {
    staged.complete();
    await resume.future;
    return super.replaceSnapshotWithConfiguration(
      incoming,
      expectedFingerprint: expectedFingerprint,
      recovery: recovery,
      beforeCommit: beforeCommit,
    );
  }
}

void main() {
  test(
    'public repository names are portable while malformed names are rejected',
    () {
      Map<String, Object> config(Object name) => {
        'version': 1,
        'preferences': {
          'extensionRepositoriesV1': jsonEncode([
            {
              'url': 'https://repo.test/index.pb',
              'engine': 'tachimanga',
              'name': name,
            },
          ]),
        },
      };
      expect(
        BackupConfiguration.fromJson(config('Kho của tôi'))
            .values['extensionRepositoriesV1'],
        contains('Kho của tôi'),
      );
      for (final invalid in [42, 'a' * 101, 'name\nnew']) {
        expect(
          () => BackupConfiguration.fromJson(config(invalid)),
          throwsFormatException,
        );
      }
    },
  );
  TestWidgetsFlutterBinding.ensureInitialized();

  test('v1 config contains all public settings and original media, never credentials/device state/queue', () async {
    final repo = MemoryLibraryRepository();
    await _seed(repo);
    final source = await _service(repo, {
      ..._portable(),
      'syncLinkV1': 'uid/token',
      'tachimangaUrl': 'https://user:secret@example.com',
      'vbookUrl': 'secret',
      'incognitoMode': true,
      'privacyV1': 'PIN',
      'downloadQueueV1': 'active',
      'lastAutomaticBackup': 123,
      'oauthToken': 'private',
    });
    final bytes = await source.backup.export(), json = _decode(bytes);
    expect(json['version'], 1);
    expect(
      (json['configuration']['preferences'] as Map).keys.toSet(),
      _portable().keys.toSet(),
    );
    expect(utf8.decode(bytes), isNot(contains('secret')));
    expect(utf8.decode(bytes), isNot(contains('uid/token')));
    expect(json['entries'][0]['contents']['0']['images'], [_png]);
    expect(
      source.backup.fingerprint(bytes),
      isNot((await repo.snapshot()).fingerprint),
    );
    final legacy = BackupService(repo);
    expect(
      legacy.fingerprint(await legacy.export()),
      (await repo.snapshot()).fingerprint,
    );
  });

  test('manual merge defaults keep configuration; opt-in applies and recovery includes prior full image', () async {
    final sourceRepo = MemoryLibraryRepository();
    await _seed(sourceRepo, id: 'new');
    final source = await _service(sourceRepo, _portable());
    final bytes = await source.backup.export();
    final repo = MemoryLibraryRepository();
    await _seed(repo);
    final target = await _service(repo, {
      'dark': true,
      'fontSize': 20.0,
      'readSeconds:2026-1-1': 9,
      'privacyV1': 'keep-me',
      'downloadQueueV1': 'do-not-change',
    });
    final original = await target.backup.export();
    final preview = await target.backup.preview(bytes);
    expect(preview.configurationCount, _portable().length);
    expect(preview.hasConfiguration, true);
    expect(await target.backup.mergePreview(preview), 1);
    expect(target.prefs.getBool('dark'), true);
    expect(target.prefs.getDouble('fontSize'), 20);
    expect(
      target.backup.fingerprint((await target.backup.exportRecovery())!),
      target.backup.fingerprint(original),
    );
    expect(
      await target.backup.mergePreview(
        await target.backup.preview(bytes),
        restoreConfiguration: true,
      ),
      0,
    );
    expect(BackupConfiguration.capture(target.prefs).values, _portable());
    expect(target.prefs.get('privacyV1'), 'keep-me');
    expect(target.prefs.get('downloadQueueV1'), 'do-not-change');
    expect((await repo.find('old'))!.progress, .4);
    expect((await repo.find('new'))!.bookmarks, ['0:0.2']);
    expect(target.prefs.containsKey(CoordinatedPreferences.journalKey), false);
  });

  test('legacy backups leave settings untouched while full recovery remains self-contained', () async {
    final source = MemoryLibraryRepository();
    await _seed(source, id: 'new');
    final repo = MemoryLibraryRepository();
    await _seed(repo);
    final target = await _service(repo, _portable());
    final original = await target.backup.export();
    await target.backup.replace(
      await BackupService(source).export(),
      expectedFingerprint: target.backup.fingerprint(original),
    );
    expect(BackupConfiguration.capture(target.prefs).values, _portable());
    expect(
      target.backup.fingerprint((await target.backup.exportRecovery())!),
      target.backup.fingerprint(original),
    );
    expect((await repo.readChapter('new', 0))!.images, [_png]);
    expect(await repo.find('old'), isNull);
  });

  test('invalid/secret/nested malformed configurations cause zero writes', () async {
    final repo = MemoryLibraryRepository();
    await _seed(repo);
    final target = await _service(repo, {'dark': true});
    final original = await target.backup.export();
    for (final bad in [
      null,
      {'version': 2, 'preferences': {}},
      {
        'version': 1,
        'preferences': {'oauthToken': 'no'},
      },
      {
        'version': 1,
        'preferences': {'readerOptionsV1': '{bad'},
      },
      {
        'version': 1,
        'preferences': {'downloadDeletionPolicyV1': '{"afterReading":"yes"}'},
      },
      {
        'version': 1,
        'preferences': {'readSeconds:2026-2-30': 12},
      },
      {
        'version': 1,
        'preferences': {
          'extensionRepositoriesV1':
              '[{"engine":"vbook","url":"https://site/plugins?token=secret"}]',
        },
      },
    ]) {
      final json = _decode(original)..['configuration'] = bad;
      await expectLater(
        target.backup.replace(
          _encode(json),
          expectedFingerprint: target.backup.fingerprint(original),
        ),
        throwsFormatException,
      );
      expect(await target.backup.export(), original);
      expect(await repo.recoverySnapshot(), isNull);
      expect(
        target.prefs.containsKey(CoordinatedPreferences.journalKey),
        false,
      );
    }
  });

  test(
    'corrupt saved public configuration is retained and blocks export',
    () async {
      final repo = MemoryLibraryRepository();
      final target = await _service(repo, {'libraryCategoriesV1': '{bad'});
      await expectLater(target.backup.export(), throwsFormatException);
      expect(target.prefs.getString('libraryCategoriesV1'), '{bad');
      expect(await repo.recoverySnapshot(), isNull);
    },
  );

  test(
    'joint fingerprint rejects configuration and book changes after preview',
    () async {
      final sourceRepo = MemoryLibraryRepository();
      await _seed(sourceRepo, id: 'new');
      final source = await _service(sourceRepo, {'dark': false});
      final bytes = await source.backup.export();
      final repo = MemoryLibraryRepository();
      await _seed(repo);
      final target = await _service(repo, {'dark': true});
      final preview = await target.backup.preview(bytes);
      await target.prefs.setBool('dark', false);
      await expectLater(
        target.backup.mergePreview(preview, restoreConfiguration: true),
        throwsStateError,
      );
      expect(await repo.find('new'), isNull);
      expect(await repo.recoverySnapshot(), isNull);
      final newer = await target.backup.preview(bytes);
      await repo.mutateBook(
        'old',
        (book) => book.copyWith(notes: 'unseen edit'),
      );
      await expectLater(
        target.backup.mergePreview(newer, restoreConfiguration: true),
        throwsStateError,
      );
      expect((await repo.find('old'))!.notes, 'unseen edit');
      expect(target.prefs.getBool('dark'), false);
    },
  );

  test('CAS rechecks a book edit while native-style staging awaits, without applying preferences', () async {
    final sourceRepo = MemoryLibraryRepository();
    await _seed(sourceRepo, id: 'new');
    final source = await _service(sourceRepo, {'dark': false});
    final bytes = await source.backup.export();
    final repo = _DelayedCommitRepository();
    await _seed(repo);
    final target = await _service(repo, {'dark': true});
    final original = await target.backup.export();
    final operation = target.backup.replace(
      bytes,
      expectedFingerprint: target.backup.fingerprint(original),
    );
    final check = expectLater(operation, throwsStateError);
    await repo.staged.future;
    await repo.mutateBook('old', (book) => book.copyWith(notes: 'latest'));
    repo.resume.complete();
    await check;
    expect(target.prefs.getBool('dark'), true);
    expect((await repo.find('old'))!.notes, 'latest');
    expect(await repo.find('new'), isNull);
    expect(target.prefs.containsKey(CoordinatedPreferences.journalKey), false);
  });

  test(
    'DB failure after configuration callback rolls all public prefs back',
    () async {
      final sourceRepo = MemoryLibraryRepository();
      await _seed(sourceRepo, id: 'new');
      final source = await _service(sourceRepo, _portable());
      final bytes = await source.backup.export();
      final repo = _FailingCommitRepository();
      await _seed(repo);
      final target = await _service(repo, {'dark': true, 'fontSize': 20.0});
      final before = await target.backup.export();
      await expectLater(
        target.backup.replace(
          bytes,
          expectedFingerprint: target.backup.fingerprint(before),
        ),
        throwsStateError,
      );
      expect(await target.backup.export(), before);
      expect(
        target.prefs.containsKey(CoordinatedPreferences.journalKey),
        false,
      );
    },
  );

  test('partial preference write failure rolls back books and config; failed rollback keeps journal for startup', () async {
    final sourceRepo = MemoryLibraryRepository();
    await _seed(sourceRepo, id: 'new');
    final source = await _service(sourceRepo, {
      'dark': false,
      'fontSize': 30.0,
    });
    final bytes = await source.backup.export();
    for (final failures in [1, 2]) {
      final repo = MemoryLibraryRepository();
      await _seed(repo);
      SharedPreferences.setMockInitialValues({});
      final store = _FailingStore({'dark': true, 'fontSize': 20.0})
        ..failKey = 'fontSize'
        ..remainingFailures = failures;
      SharedPreferencesStorePlatform.instance = store;
      final prefs = await CoordinatedPreferences.open(
        await SharedPreferences.getInstance(),
        repo,
      );
      final backup = BackupService(
        repo,
        configuration: AppConfigurationStore(prefs),
      );
      final before = await backup.export();
      await expectLater(
        backup.replace(bytes, expectedFingerprint: backup.fingerprint(before)),
        throwsStateError,
      );
      expect(await repo.find('new'), isNull);
      expect((await repo.find('old'))!.progress, .4);
      if (failures == 2) {
        expect(prefs.containsKey(CoordinatedPreferences.journalKey), true);
        await expectLater(backup.export(), throwsStateError);
      }
      SharedPreferences.resetStatic();
      final restarted = await CoordinatedPreferences.open(
        await SharedPreferences.getInstance(),
        repo,
      );
      expect(BackupConfiguration.capture(restarted).values, {
        'dark': true,
        'fontSize': 20.0,
      });
      expect(restarted.containsKey(CoordinatedPreferences.journalKey), false);
    }
  });

  test('normal edits during restore are refused and cannot overwrite committed settings', () async {
    final sourceRepo = MemoryLibraryRepository();
    await _seed(sourceRepo, id: 'new');
    final source = await _service(sourceRepo, {'dark': false});
    final bytes = await source.backup.export();
    final repo = _DelayedCommitRepository();
    await _seed(repo);
    final target = await _service(repo, {'dark': true});
    final original = await target.backup.export();
    final operation = target.backup.replace(
      bytes,
      expectedFingerprint: target.backup.fingerprint(original),
    );
    await repo.staged.future;
    final stale = target.prefs.setBool('dark', true),
        rejected = expectLater(stale, throwsStateError);
    repo.resume.complete();
    await operation;
    await rejected;
    expect(target.prefs.getBool('dark'), false);
    expect(await repo.find('new'), isNotNull);
    await target.prefs.setBool('dark', true);
    expect(target.prefs.getBool('dark'), true);
  });

  test('prepared crash journal chooses old/new committed DB; ambiguous/corrupt journal never erased', () async {
    final old = MemoryLibraryRepository();
    await _seed(old);
    final newer = MemoryLibraryRepository();
    await _seed(newer, id: 'new');
    final oldFp = (await old.snapshot()).fingerprint,
        newFp = (await newer.snapshot()).fingerprint;
    final journal = {
      'version': 1,
      'phase': 'prepared',
      'oldLibrary': oldFp,
      'newLibrary': newFp,
      'before': {
        'version': 1,
        'preferences': {'dark': true, 'fontSize': 20},
      },
      'after': {
        'version': 1,
        'preferences': {'dark': false, 'fontSize': 30},
      },
    };
    for (final entry in [(old, true, 20.0), (newer, false, 30.0)]) {
      final service = await _service(entry.$1, {
        'dark': false,
        'fontSize': 999.0,
        CoordinatedPreferences.journalKey: jsonEncode(journal),
      });
      expect(service.prefs.getBool('dark'), entry.$2);
      expect(service.prefs.getDouble('fontSize'), entry.$3);
      expect(
        service.prefs.containsKey(CoordinatedPreferences.journalKey),
        false,
      );
    }
    final other = MemoryLibraryRepository();
    await _seed(other, id: 'other');
    for (final raw in [jsonEncode(journal), '{bad']) {
      SharedPreferences.setMockInitialValues({
        'dark': true,
        CoordinatedPreferences.journalKey: raw,
      });
      final prefs = await SharedPreferences.getInstance();
      await expectLater(
        CoordinatedPreferences.open(prefs, other),
        raw == '{bad' ? throwsFormatException : throwsStateError,
      );
      expect(prefs.getString(CoordinatedPreferences.journalKey), raw);
      expect(prefs.getBool('dark'), true);
    }
  });

  test(
    'committed journal cleanup preserves a later configuration/book edit',
    () async {
      final repo = MemoryLibraryRepository();
      await _seed(repo, id: 'later');
      final unknown = '0' * 64;
      final target = await _service(repo, {
        'dark': true,
        CoordinatedPreferences.journalKey: jsonEncode({
          'version': 1,
          'phase': 'committed',
          'oldLibrary': unknown,
          'newLibrary': unknown,
          'before': {
            'version': 1,
            'preferences': {'dark': true},
          },
          'after': {
            'version': 1,
            'preferences': {'dark': false},
          },
        }),
      });
      expect(target.prefs.getBool('dark'), true);
      expect(await repo.find('later'), isNotNull);
      expect(
        target.prefs.containsKey(CoordinatedPreferences.journalKey),
        false,
      );
    },
  );

  test('restore refreshes settings/category/reader/deletion providers already in use', () async {
    final sourceRepo = MemoryLibraryRepository();
    final source = await _service(sourceRepo, _portable());
    final bytes = await source.backup.export();
    final repo = MemoryLibraryRepository();
    final target = await _service(repo, {'dark': true});
    final container = ProviderContainer(
      overrides: [
        preferencesProvider.overrideWithValue(target.prefs),
        libraryRepositoryProvider.overrideWithValue(repo),
      ],
    );
    addTearDown(container.dispose);
    expect(container.read(settingsProvider).dark, true);
    expect(container.read(readerOptionsProvider).grayscale, false);
    expect(container.read(libraryCategoriesProvider).categories, isEmpty);
    expect(container.read(downloadDeletionProvider).afterReading, false);
    final backup = container.read(backupServiceProvider);
    final old = await backup.export();
    await backup.replace(bytes, expectedFingerprint: backup.fingerprint(old));
    expect(container.read(settingsProvider).dark, false);
    expect(container.read(readerOptionsProvider).grayscale, true);
    expect(
      container.read(libraryCategoriesProvider).categories.single.name,
      'Series',
    );
    expect(container.read(downloadDeletionProvider).afterReading, true);
  });

  test('config-only sync detects changes and cloud resolution transfers full config with recovery', () async {
    final sourceRepo = MemoryLibraryRepository();
    await _seed(sourceRepo);
    final source = await _service(sourceRepo, _portable());
    final bytes = await source.backup.export();
    final repo = MemoryLibraryRepository();
    await _seed(repo);
    final target = await _service(repo, {'dark': true});
    final backup = target.backup, original = await backup.export();
    final remote = FakeSyncRemote()..seed(bytes);
    final engine = SyncEngine(
      uid: 'alice',
      local: BackupSyncLocal(
        backup: backup,
        links: SyncLinkStore(target.prefs),
      ),
      remote: remote,
    );
    expect(await engine.run(enable: true), SyncOutcome.conflict);
    expect(await engine.resolve(keepLocal: false), SyncOutcome.downloaded);
    expect(
      backup.fingerprint(await backup.export()),
      backup.fingerprint(bytes),
    );
    expect(
      backup.fingerprint((await backup.exportRecovery())!),
      backup.fingerprint(original),
    );
    await target.prefs.setInt('readingGoalMinutes', 60);
    remote.nextId = '44444444444444444444444444444444';
    expect(await engine.run(), SyncOutcome.uploaded);
    expect(
      _decode(
        remote.bytes!,
      )['configuration']['preferences']['readingGoalMinutes'],
      60,
    );
  });

  test(
    'real native Isar callback rollback and restart full configuration/offline recovery',
    () async {
      final libraryPath = Platform.environment['TACHI_ISAR_TEST_LIBRARY'];
      if (libraryPath == null) return;
      Isar.initializeIsarCore(libraries: {Abi.windowsX64: libraryPath});
      final directory = await Directory.systemTemp.createTemp(
        'configuration-backup-',
      );
      LibraryRepository? repo;
      try {
        repo = await LibraryRepository.open(directoryPath: directory.path);
        await _seed(repo);
        final target = await _service(repo, {
          'dark': true,
          'readingGoalMinutes': 20,
        });
        final before = await target.backup.export();
        final current = await repo.snapshot();
        await expectLater(
          repo.replaceSnapshotWithConfiguration(
            LibrarySnapshot([]),
            expectedFingerprint: current.fingerprint,
            recovery: before,
            beforeCommit: () async {
              throw StateError('before DB commit');
            },
          ),
          throwsStateError,
        );
        expect(await target.backup.export(), before);
        expect((await repo.readChapter('old', 0))!.images, [_png]);
        final sourceRepo = MemoryLibraryRepository();
        await _seed(sourceRepo, id: 'new');
        final source = await _service(sourceRepo, _portable());
        final incoming = await source.backup.export();
        await target.backup.replace(
          incoming,
          expectedFingerprint: target.backup.fingerprint(before),
        );
        expect(target.prefs.getInt('readingGoalMinutes'), 45);
        expect(await repo.find('old'), isNull);
        final recovery = await target.backup.exportRecovery();
        expect(
          target.backup.fingerprint(recovery!),
          target.backup.fingerprint(before),
        );
        await repo.close();
        repo = null;
        repo = await LibraryRepository.open(directoryPath: directory.path);
        final restarted = BackupService(
          repo,
          configuration: AppConfigurationStore(target.prefs),
        );
        expect(
          restarted.fingerprint(await restarted.export()),
          restarted.fingerprint(incoming),
        );
        expect((await repo.readChapter('new', 0))!.images, [_png]);
        expect(
          restarted.fingerprint((await restarted.exportRecovery())!),
          restarted.fingerprint(before),
        );
      } finally {
        await repo?.close();
        await directory.delete(recursive: true);
      }
    },
    skip: Platform.environment['TACHI_ISAR_TEST_LIBRARY'] == null
        ? 'Set the verified native Isar library path.'
        : false,
  );
}
