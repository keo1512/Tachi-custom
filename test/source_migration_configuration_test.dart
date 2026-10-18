import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:isar_community/isar.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:tachi_books/features/library/data/backup_configuration.dart';
import 'package:tachi_books/features/library/data/backup_service.dart';
import 'package:tachi_books/features/library/data/coordinated_preferences.dart';
import 'package:tachi_books/features/library/data/library_repository.dart';
import 'package:tachi_books/features/library/data/library_snapshot.dart';
import 'package:tachi_books/features/library/domain/book_reading_times.dart';
import 'package:tachi_books/features/library/domain/book_daily_reading_times.dart';
import 'package:tachi_books/features/library/domain/library_book.dart';
import 'package:tachi_books/features/library/domain/library_folders.dart';
import 'package:tachi_books/features/library/presentation/library_folders_controller.dart';
import 'package:tachi_books/features/library/presentation/library_view_model.dart';
import 'package:tachi_books/features/settings/settings_controller.dart';
import 'package:tachi_books/features/sources/application/source_migration_service.dart';
import 'package:tachi_books/features/sources/domain/catalogue.dart';
import 'package:tachi_books/features/sources/domain/source_migration.dart';

const _target = CatalogueBook(
  ref: '/new',
  title: 'New',
  sourceId: 'new',
  kind: ContentKind.manga,
  engine: SourceEngine.tachimanga,
);
const _chapters = [
  CatalogueChapter(ref: '/new/1', title: 'One', index: 0, number: 1),
];
String _targetId(CatalogueBook target) =>
    sha256.convert(utf8.encode(target.identity)).toString();

Map<String, Object> _configuration() => {
  BookDailyReadingTimes.preferenceKey: BookDailyReadingTimes({
    '2026-10-17': {'old': 90},
    '2026-10-18': {'old': 30, 'other': 30},
  }).encode(),
  BookReadingTimes.preferenceKey: BookReadingTimes({'old': 120, 'other': 30})
      .encode(),
  LibraryFolders.preferenceKey: LibraryFolders({
    'old': 'Legacy',
    'other': 'Other',
  }).encode(),
  LibraryFolders.categoryPreferenceKey: jsonEncode({
    'Shelf': {'old': 'Scoped'},
    'Second': {'old': null},
  }),
  'readSeconds:2026-10-18': 150,
  'fontSize': 22.0,
};

Future<
  ({
    LibraryRepository repo,
    CoordinatedPreferences prefs,
    SourceMigration migration,
  })
>
_open({
  LibraryRepository? repository,
  Map<String, Object>? values,
  void Function()? changed,
}) async {
  final repo = repository ?? MemoryLibraryRepository();
  await repo.save(
    LibraryBook(
      id: 'old',
      title: 'Old',
      kind: 'manga',
      engine: 'tachimanga',
      sourceId: 'old',
      sourceRef: '/old',
      categories: ['Shelf', 'Second'],
      notes: 'Retained',
      bookmarks: ['0:0.2000'],
      chapters: const [
        BookChapter(
          id: '/old/1',
          title: 'One',
          index: 0,
          number: 1,
          read: true,
          downloaded: true,
        ),
      ],
    ),
  );
  await repo.saveChapter(
    'old',
    0,
    ReaderContent(kind: 'manga', images: ['data:image/png;base64,AQ==']),
  );
  await repo.save(LibraryBook(id: 'other', title: 'Other'));
  SharedPreferences.setMockInitialValues(values ?? _configuration());
  final prefs = await CoordinatedPreferences.open(
    await SharedPreferences.getInstance(),
    repo,
  );
  return (
    repo: repo,
    prefs: prefs,
    migration: SourceMigration(
      repo,
      configuration: AppConfigurationStore(prefs),
      onConfigurationChanged: changed,
    ),
  );
}

LibraryFolders _folders(CoordinatedPreferences prefs) =>
    LibraryFolders.decodeWithCategories(
      prefs.getString(LibraryFolders.preferenceKey),
      prefs.getString(LibraryFolders.categoryPreferenceKey),
    );

void main() {
  for (final replace in [false, true]) {
    test(
      'disabled category transfer ${replace ? 'replaces' : 'keeps'} old membership without assigning target folders',
      () async {
        final fixture = await _open();
        final preview = await fixture.migration.preview(
          'old',
          _target,
          _chapters,
          options: const SourceMigrationOptions(
            chapters: false,
            categories: false,
          ),
        );
        final saved = (await fixture.migration.commitBatch(
          [preview],
          replaceOld: replace,
          expectedRevision: fixture.repo.replacementRevision,
        )).single;
        expect(saved.categories, ['Mặc định']);
        expect(saved.chapters.single.read, isFalse);
        expect(saved.bookmarks, isEmpty);
        final folders = _folders(fixture.prefs);
        expect(folders.names.containsKey(saved.id), isFalse);
        expect(folders.names.containsKey('old'), !replace);
        expect(folders.categoryNames['Shelf']!.containsKey(saved.id), isFalse);
        expect(folders.categoryNames['Shelf']!.containsKey('old'), !replace);
      },
    );
  }
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final replace in [false, true]) {
    test(
      'single ${replace ? 'replace' : 'keep'} atomically preserves folder assignment without duplicating duration',
      () async {
        var notices = 0;
        final f = await _open(changed: () => notices++);
        final before = BackupConfiguration.capture(f.prefs);
        final original = (await f.repo.find('old'))!;
        final preview = await f.migration.preview('old', _target, _chapters);
        expect(preview.before.configuration!.fingerprint, before.fingerprint);
        expect(
          BackupConfiguration.capture(f.prefs).fingerprint,
          before.fingerprint,
        );
        final next = await f.migration.commit(preview, replaceOld: replace);
        final times = BookReadingTimes.decode(
          f.prefs.getString(BookReadingTimes.preferenceKey),
        );
        expect(times.of('old'), replace ? 0 : 120);
        expect(times.of(next.id), replace ? 120 : 0);
        expect(times.seconds.values.fold(0, (a, b) => a + b), 150);
        final daily = BookDailyReadingTimes.decode(
          f.prefs.getString(BookDailyReadingTimes.preferenceKey),
        );
        expect(daily.totalOf('old'), replace ? 0 : 120);
        expect(daily.totalOf(next.id), replace ? 120 : 0);
        expect(daily.onDay(next.id, DateTime(2026, 10, 17)), replace ? 90 : 0);
        expect(f.prefs.getInt('readSeconds:2026-10-18'), 150);
        expect(f.prefs.getDouble('fontSize'), 22.0);
        final folders = _folders(f.prefs);
        expect(folders.names[next.id], 'Legacy');
        expect(folders.namesIn('Shelf')[next.id], 'Scoped');
        expect(folders.namesIn('Second').containsKey(next.id), false);
        expect(folders.names.containsKey('old'), !replace);
        expect(folders.categoryNames['Second']!.containsKey('old'), !replace);
        expect(next.notes, original.notes);
        expect(next.chapters.single.read, true);
        expect(next.chapters.single.downloaded, false);
        expect(await f.repo.readChapter(next.id, 0), isNull);
        expect(await f.repo.find('old'), replace ? isNull : isNotNull);
        expect(notices, 1);
        final recovery = jsonDecode(
          utf8.decode((await f.repo.recoverySnapshot())!),
        ) as Map<String, dynamic>;
        expect(
          BackupConfiguration.fromJson(recovery['configuration']).fingerprint,
          before.fingerprint,
        );
        expect(
          (recovery['entries'] as List)
              .where((e) => e['book']['id'] == 'old')
              .single['contents'],
          isNotEmpty,
        );
        // The normal backup path can restore both the old library and config.
        final backup = BackupService(
          f.repo,
          configuration: AppConfigurationStore(f.prefs),
        );
        final current = backup.fingerprint(await backup.export());
        await backup.replace(
          (await f.repo.recoverySnapshot())!,
          expectedFingerprint: current,
        );
        expect((await f.repo.find('old'))!.toJson(), original.toJson());
        expect(
          BackupConfiguration.capture(f.prefs).fingerprint,
          before.fingerprint,
        );
        expect(await f.repo.find(next.id), isNull);
      },
    );
  }

  test(
    'batch moves each duration once and copies scoped/legacy folders together',
    () async {
      final f = await _open();
      final old = (await f.repo.find('old'))!;
      await f.repo.save(old.copyWith(id: 'old-two', sourceRef: '/old-two'));
      await f.repo.saveChapter(
        'old-two',
        0,
        (await f.repo.readChapter('old', 0))!,
      );
      await f.prefs.setString(
        BookReadingTimes.preferenceKey,
        BookReadingTimes({'old': 120, 'old-two': 80, 'other': 30}).encode(),
      );
      await f.prefs.setString(
        LibraryFolders.preferenceKey,
        LibraryFolders({'old': 'First', 'old-two': 'Second'}).encode(),
      );
      const second = CatalogueBook(
        ref: '/new-two',
        title: 'Two',
        sourceId: 'new',
        kind: ContentKind.manga,
        engine: SourceEngine.tachimanga,
      );
      final a = await f.migration.preview('old', _target, _chapters);
      final b = (await f.migration.preview(
        'old-two',
        second,
        _chapters,
      )).sharingSnapshot(a);
      final books = await f.migration.commitBatch([a, b], replaceOld: true);
      expect(books.length, 2);
      expect(
        BookReadingTimes.decode(
          f.prefs.getString(BookReadingTimes.preferenceKey),
        ).seconds,
        {_targetId(_target): 120, _targetId(second): 80, 'other': 30},
      );
      expect(_folders(f.prefs).names[_targetId(_target)], 'First');
      expect(_folders(f.prefs).names[_targetId(second)], 'Second');
      expect(await f.repo.find('old'), isNull);
      expect(await f.repo.find('old-two'), isNull);
    },
  );

  test('legacy configuration without optional keys stays absent', () async {
    final f = await _open(values: {'fontSize': 22.0});
    final preview = await f.migration.preview('old', _target, _chapters);
    await f.migration.commit(preview, replaceOld: true);
    expect(BackupConfiguration.capture(f.prefs).values, {'fontSize': 22.0});
  });

  test('production provider invalidates the open folder controller after joint migration', () async {
    final f = await _open();
    final container = ProviderContainer(
      overrides: [
        preferencesProvider.overrideWithValue(f.prefs),
        libraryRepositoryProvider.overrideWithValue(f.repo),
      ],
    );
    addTearDown(container.dispose);
    final subscription = container.listen(libraryFoldersProvider, (_, _) {});
    addTearDown(subscription.close);
    expect(container.read(libraryFoldersProvider).names['old'], 'Legacy');
    final migration = container.read(sourceMigrationProvider);
    final preview = await migration.preview('old', _target, _chapters);
    await migration.commit(preview, replaceOld: true);
    expect(
      container.read(libraryFoldersProvider).names.containsKey('old'),
      false,
    );
    expect(
      container.read(libraryFoldersProvider).namesIn('Shelf')[_targetId(
        _target,
      )],
      'Scoped',
    );
  });

  test(
    'batch keep copies folders but duration stays only on original books',
    () async {
      final f = await _open();
      final old = (await f.repo.find('old'))!;
      await f.repo.save(
        old.copyWith(
          id: 'old-two',
          sourceRef: '/old-two',
          chapters: old.chapters
              .map((c) => c.copyWith(downloaded: false))
              .toList(),
        ),
      );
      await f.prefs.setString(
        BookReadingTimes.preferenceKey,
        BookReadingTimes({'old': 120, 'old-two': 80}).encode(),
      );
      await f.prefs.setString(
        LibraryFolders.preferenceKey,
        LibraryFolders({'old': 'First', 'old-two': 'Second'}).encode(),
      );
      const second = CatalogueBook(
        ref: '/new-two',
        title: 'Two',
        sourceId: 'new',
        kind: ContentKind.manga,
        engine: SourceEngine.tachimanga,
      );
      final a = await f.migration.preview('old', _target, _chapters);
      final b = await f.migration.preview('old-two', second, _chapters);
      await f.migration.commitBatch([a, b]);
      expect(
        BookReadingTimes.decode(
          f.prefs.getString(BookReadingTimes.preferenceKey),
        ).seconds,
        {'old': 120, 'old-two': 80},
      );
      expect(_folders(f.prefs).names, {
        'old': 'First',
        'old-two': 'Second',
        _targetId(_target): 'First',
        _targetId(second): 'Second',
      });
      expect(await f.repo.find('old'), isNotNull);
      expect(await f.repo.find('old-two'), isNotNull);
    },
  );

  test('batch previews reject intervening configuration edits and same-byte restores', () async {
    for (final restored in [false, true]) {
      final f = await _open();
      final old = (await f.repo.find('old'))!;
      await f.repo.save(
        old.copyWith(
          id: 'old-two',
          sourceRef: '/old-two',
          chapters: old.chapters
              .map((c) => c.copyWith(downloaded: false))
              .toList(),
        ),
      );
      final a = await f.migration.preview('old', _target, _chapters);
      if (restored) {
        final backup = BackupService(
          f.repo,
          configuration: AppConfigurationStore(f.prefs),
        );
        final bytes = await backup.export();
        await backup.replace(
          bytes,
          expectedFingerprint: backup.fingerprint(bytes),
        );
      } else {
        await f.prefs.setDouble('fontSize', 24);
      }
      const second = CatalogueBook(
        ref: '/new-two',
        title: 'Two',
        sourceId: 'new',
        kind: ContentKind.manga,
        engine: SourceEngine.tachimanga,
      );
      final b = await f.migration.preview('old-two', second, _chapters);
      expect(() => b.sharingSnapshot(a), throwsStateError);
      await expectLater(
        f.migration.commitBatch([a, b], replaceOld: true),
        throwsStateError,
      );
      expect(await f.repo.find(_targetId(_target)), isNull);
      expect(await f.repo.find(_targetId(second)), isNull);
    }
  });

  test(
    'duration merge overflow rejects without mutating either store',
    () async {
      final id = _targetId(_target);
      final f = await _open(
        values: {
          ..._configuration(),
          BookReadingTimes.preferenceKey: BookReadingTimes({
            'old': 1,
            id: 9007199254740991,
          }).encode(),
        },
      );
      final before = await f.repo.snapshot();
      final settings = BackupConfiguration.capture(f.prefs);
      final preview = await f.migration.preview('old', _target, _chapters);
      await expectLater(
        f.migration.commit(preview, replaceOld: true),
        throwsFormatException,
      );
      expect((await f.repo.snapshot()).fingerprint, before.fingerprint);
      expect(
        BackupConfiguration.capture(f.prefs).fingerprint,
        settings.fingerprint,
      );
    },
  );

  test('orphan target duration is preserved by addition but conflicting folder rejects without writes', () async {
    final f = await _open();
    final id = _targetId(_target);
    await f.prefs.setString(
      BookReadingTimes.preferenceKey,
      BookReadingTimes({'old': 120, id: 10}).encode(),
    );
    final preview = await f.migration.preview('old', _target, _chapters);
    await f.migration.commit(preview, replaceOld: true);
    expect(
      BookReadingTimes.decode(f.prefs.getString(BookReadingTimes.preferenceKey))
          .seconds,
      {id: 130},
    );
    final conflict = await _open(
      values: {
        ..._configuration(),
        LibraryFolders.preferenceKey: LibraryFolders({
          'old': 'Original',
          id: 'Existing',
        }).encode(),
      },
    );
    final before = await conflict.repo.snapshot();
    final config = BackupConfiguration.capture(conflict.prefs);
    await expectLater(
      conflict.migration.preview('old', _target, _chapters),
      throwsStateError,
    );
    expect((await conflict.repo.snapshot()).fingerprint, before.fingerprint);
    expect(
      BackupConfiguration.capture(conflict.prefs).fingerprint,
      config.fingerprint,
    );
  });

  for (final edit in [
    'time',
    'folder',
    'other-pref',
    'same-byte-restore',
    'library',
  ]) {
    test('$edit change after preview rejects old joint publication', () async {
      final f = await _open();
      final preview = await f.migration.preview('old', _target, _chapters);
      switch (edit) {
        case 'time':
          await f.prefs.setString(
            BookReadingTimes.preferenceKey,
            BookReadingTimes({'old': 121}).encode(),
          );
        case 'folder':
          await f.prefs.setString(
            LibraryFolders.preferenceKey,
            LibraryFolders({'old': 'Changed'}).encode(),
          );
        case 'other-pref':
          await f.prefs.setDouble('fontSize', 24.0);
        case 'same-byte-restore':
          final backup = BackupService(
            f.repo,
            configuration: AppConfigurationStore(f.prefs),
          );
          final bytes = await backup.export();
          await backup.replace(
            bytes,
            expectedFingerprint: backup.fingerprint(bytes),
          );
        case 'library':
          await f.repo.mutateBook('old', (b) => b.copyWith(notes: 'New edit'));
      }
      final after = await f.repo.snapshot();
      final settings = BackupConfiguration.capture(f.prefs);
      await expectLater(
        f.migration.commit(preview, replaceOld: true),
        throwsStateError,
      );
      expect((await f.repo.snapshot()).fingerprint, after.fingerprint);
      expect(
        BackupConfiguration.capture(f.prefs).fingerprint,
        settings.fingerprint,
      );
    });
  }

  test(
    'queued preference write wins before publication instead of being lost',
    () async {
      final f = await _open();
      final preview = await f.migration.preview('old', _target, _chapters);
      final entered = Completer<void>(), release = Completer<void>();
      final held = f.prefs.exclusive(() async {
        entered.complete();
        await release.future;
      });
      await entered.future;
      final edit = f.prefs.setString(
        BookReadingTimes.preferenceKey,
        BookReadingTimes({'old': 122}).encode(),
      );
      final rejected = expectLater(
        f.migration.commit(preview, replaceOld: true),
        throwsStateError,
      );
      release.complete();
      await held;
      await edit;
      await rejected;
      expect(
        BookReadingTimes.decode(
          f.prefs.getString(BookReadingTimes.preferenceKey),
        ).of('old'),
        122,
      );
      expect(await f.repo.find('old'), isNotNull);
      expect(await f.repo.find(_targetId(_target)), isNull);
    },
  );

  test('library failure after applying config rolls preferences back and keeps recovery', () async {
    var notices = 0;
    final f = await _open(repository: _FailCommit(), changed: () => notices++);
    final before = await f.repo.snapshot();
    final settings = BackupConfiguration.capture(f.prefs);
    final preview = await f.migration.preview('old', _target, _chapters);
    await expectLater(
      f.migration.commit(preview, replaceOld: true),
      throwsStateError,
    );
    expect((await f.repo.snapshot()).fingerprint, before.fingerprint);
    expect(
      BackupConfiguration.capture(f.prefs).fingerprint,
      settings.fingerprint,
    );
    expect(f.prefs.containsKey(CoordinatedPreferences.journalKey), false);
    expect(notices, 0);
  });

  test(
    'preference setter failure rolls both images back without writing new book',
    () async {
      final values = _configuration();
      final store = _FailPreference(values);
      SharedPreferencesStorePlatform.instance = store;
      SharedPreferences.resetStatic();
      final repo = MemoryLibraryRepository();
      final original = LibraryBook(
        id: 'old',
        title: 'Old',
        kind: 'manga',
        engine: 'tachimanga',
        sourceId: 'old',
        chapters: const [
          BookChapter(id: 'a', title: 'One', index: 0, number: 1),
        ],
      );
      await repo.save(original);
      final prefs = await CoordinatedPreferences.open(
        await SharedPreferences.getInstance(),
        repo,
      );
      final migration = SourceMigration(
        repo,
        configuration: AppConfigurationStore(prefs),
      );
      final preview = await migration.preview('old', _target, _chapters);
      store.failNext = true;
      await expectLater(
        migration.commit(preview, replaceOld: true),
        throwsStateError,
      );
      expect((await repo.find('old'))!.toJson(), original.toJson());
      expect(await repo.find(_targetId(_target)), isNull);
      expect(BackupConfiguration.capture(prefs).values, values);
    },
  );

  for (final afterConfig in [false, true]) {
    test(
      'library edit ${afterConfig ? 'after' : 'before'} config apply wins and rolls migration back',
      () async {
        final repo = _BlockedCommit(afterConfig);
        final f = await _open(repository: repo);
        final settings = BackupConfiguration.capture(f.prefs);
        final preview = await f.migration.preview('old', _target, _chapters);
        final rejected = expectLater(
          f.migration.commit(preview, replaceOld: true),
          throwsStateError,
        );
        await repo.entered.future;
        await repo.mutateBook(
          'old',
          (b) => b.copyWith(notes: 'Concurrent edit'),
        );
        repo.release.complete();
        await rejected;
        expect((await repo.find('old'))!.notes, 'Concurrent edit');
        expect(await repo.find(_targetId(_target)), isNull);
        expect(
          BackupConfiguration.capture(f.prefs).fingerprint,
          settings.fingerprint,
        );
      },
    );
  }

  test('preference edit submitted during joint commit is refused after publication', () async {
    final repo = _BlockedCommit(false);
    final f = await _open(repository: repo);
    final preview = await f.migration.preview('old', _target, _chapters);
    final commit = f.migration.commit(preview, replaceOld: true);
    await repo.entered.future;
    final staleWrite = expectLater(
      f.prefs.setString(
        BookReadingTimes.preferenceKey,
        BookReadingTimes({'old': 999}).encode(),
      ),
      throwsStateError,
    );
    repo.release.complete();
    await commit;
    await staleWrite;
    expect(
      BookReadingTimes.decode(f.prefs.getString(BookReadingTimes.preferenceKey))
          .of(_targetId(_target)),
      120,
    );
    expect(
      BookReadingTimes.decode(f.prefs.getString(BookReadingTimes.preferenceKey))
          .of('old'),
      0,
    );
  });

  test('journal failure after committed library keeps recovery and reconciles on reopen', () async {
    final store = _FailPreference(_configuration());
    SharedPreferencesStorePlatform.instance = store;
    SharedPreferences.resetStatic();
    final repo = MemoryLibraryRepository();
    await repo.save(
      LibraryBook(
        id: 'old',
        title: 'Old',
        kind: 'manga',
        engine: 'tachimanga',
        sourceId: 'old',
        chapters: const [
          BookChapter(id: 'a', title: 'One', index: 0, number: 1),
        ],
      ),
    );
    final prefs = await CoordinatedPreferences.open(
      await SharedPreferences.getInstance(),
      repo,
    );
    var notices = 0;
    final migration = SourceMigration(
      repo,
      configuration: AppConfigurationStore(prefs),
      onConfigurationChanged: () => notices++,
    );
    final preview = await migration.preview('old', _target, _chapters);
    store.failJournalCommit = true;
    await expectLater(
      migration.commit(preview, replaceOld: true),
      throwsA(isA<SourceMigrationRecoveryRequired>()),
    );
    expect(await repo.find(_targetId(_target)), isNotNull);
    expect(await repo.find('old'), isNull);
    expect(notices, 1);
    expect(await repo.recoverySnapshot(), isNotNull);
    expect(prefs.containsKey(CoordinatedPreferences.journalKey), true);
    // Reopen against the durable journal, not the failing setter's cached value.
    SharedPreferences.resetStatic();
    final restarted = await CoordinatedPreferences.open(
      await SharedPreferences.getInstance(),
      repo,
    );
    expect(restarted.containsKey(CoordinatedPreferences.journalKey), false);
    expect(
      BookReadingTimes.decode(
        restarted.getString(BookReadingTimes.preferenceKey),
      ).of(_targetId(_target)),
      120,
    );
    expect(_folders(restarted).namesIn('Shelf')[_targetId(_target)], 'Scoped');
  });

  final native = Platform.environment['TACHI_ISAR_TEST_LIBRARY'];
  test('real Isar joint migration retains source cache only in recovery and restores config', () async {
    await Isar.initializeIsarCore(
      libraries: {Abi.current(): native!},
      download: false,
    );
    final folder = await Directory.systemTemp.createTemp(
      'tachi-migration-config-',
    );
    final repo = await LibraryRepository.open(directoryPath: folder.path);
    try {
      final f = await _open(repository: repo);
      final preview = await f.migration.preview('old', _target, _chapters);
      await f.migration.commit(
        preview,
        replaceOld: true,
        expectedRevision: repo.replacementRevision,
      );
      expect(await repo.find('old'), isNull);
      expect(await repo.readChapter(_targetId(_target), 0), isNull);
      expect(
        BookReadingTimes.decode(
          f.prefs.getString(BookReadingTimes.preferenceKey),
        ).of(_targetId(_target)),
        120,
      );
      final recovery = (await repo.recoverySnapshot())!;
      expect(jsonDecode(utf8.decode(recovery))['configuration'], isNotNull);
      final service = BackupService(
        repo,
        configuration: AppConfigurationStore(f.prefs),
      );
      await service.replace(
        recovery,
        expectedFingerprint: service.fingerprint(await service.export()),
      );
      expect(await repo.readChapter('old', 0), isNotNull);
      expect(
        BookReadingTimes.decode(
          f.prefs.getString(BookReadingTimes.preferenceKey),
        ).of('old'),
        120,
      );
    } finally {
      await repo.close();
      await folder.delete(recursive: true);
    }
  }, skip: native == null ? 'Opt-in native Isar library.' : false);
}

class _FailCommit extends MemoryLibraryRepository {
  @override
  Future<void> replaceSnapshotWithConfiguration(
    LibrarySnapshot incoming, {
    required String expectedFingerprint,
    required Uint8List recovery,
    required Future<void> Function() beforeCommit,
  }) => super.replaceSnapshotWithConfiguration(
    incoming,
    expectedFingerprint: expectedFingerprint,
    recovery: recovery,
    beforeCommit: () async {
      await beforeCommit();
      throw StateError('Injected DB commit failure');
    },
  );
}

class _BlockedCommit extends MemoryLibraryRepository {
  _BlockedCommit(this.afterConfig);
  final bool afterConfig;
  final entered = Completer<void>(), release = Completer<void>();
  @override
  Future<void> replaceSnapshotWithConfiguration(
    LibrarySnapshot incoming, {
    required String expectedFingerprint,
    required Uint8List recovery,
    required Future<void> Function() beforeCommit,
  }) async {
    if (!afterConfig) {
      entered.complete();
      await release.future;
    }
    await super.replaceSnapshotWithConfiguration(
      incoming,
      expectedFingerprint: expectedFingerprint,
      recovery: recovery,
      beforeCommit: () async {
        await beforeCommit();
        if (afterConfig) {
          entered.complete();
          await release.future;
        }
      },
    );
  }
}

class _FailPreference extends InMemorySharedPreferencesStore {
  _FailPreference(Map<String, Object> values)
    : super.withData({
        for (final entry in values.entries) 'flutter.${entry.key}': entry.value,
      });
  bool failNext = false;
  bool failJournalCommit = false;
  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    if (failJournalCommit &&
        key == 'flutter.${CoordinatedPreferences.journalKey}' &&
        value is String &&
        jsonDecode(value)['phase'] == 'committed') {
      failJournalCommit = false;
      return false;
    }
    if (failNext && key == 'flutter.${BookReadingTimes.preferenceKey}') {
      failNext = false;
      return false;
    }
    return super.setValue(valueType, key, value);
  }
}
