import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:isar_community/isar.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tachi_books/features/library/application/backup_source_availability.dart';
import 'package:tachi_books/features/library/data/backup_service.dart';
import 'package:tachi_books/features/library/data/coordinated_preferences.dart';
import 'package:tachi_books/features/library/data/extension_backup_store.dart';
import 'package:tachi_books/features/library/data/library_repository.dart';
import 'package:tachi_books/features/library/data/library_snapshot.dart';
import 'package:tachi_books/features/sources/data/native_tachi_repository.dart';
import 'package:tachi_books/features/sources/data/native_vbook_repository.dart';
import 'package:tachi_books/features/sources/data/on_device_source_repository.dart';
import 'package:tachi_books/features/sources/domain/catalogue.dart';

import 'support/backup_fixtures.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late NativeTachiRepository tachi;
  late OnDeviceSourceRepository sources;
  late List<String> calls;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('tachi-empty-inventory-');
    calls = [];
    tachi = NativeTachiRepository(
      storageDirectory: directory,
      executor: (request) async {
        final method = jsonDecode(request)['method'] as String;
        calls.add(method);
        return jsonEncode({
          'ok': true,
          'result': method == 'sources'
              ? [
                  {'id': '9007199254740993', 'name': 'Fixture'},
                ]
              : method == 'extensions'
              ? []
              : <String, Object>{},
        });
      },
    );
    sources = OnDeviceSourceRepository(
      tachimangaUrl: '',
      vbookUrl: '',
      runtimes: {SourceEngine.tachimanga: tachi},
    );
  });
  tearDown(() async {
    sources.dispose();
    await directory.delete(recursive: true);
  });

  for (final registryExists in [false, true]) {
    test(
      'empty installation enumerates and captures without starting Java; registry=$registryExists',
      () async {
        if (registryExists) {
          await File('${directory.path}/registry.json')
              .writeAsString(jsonEncode({'version': 1, 'packages': {}}));
        }
        expect(await sources.listSources(SourceEngine.tachimanga), isEmpty);
        expect(await sources.extensions(SourceEngine.tachimanga), isEmpty);
        expect((await tachi.captureExtensionBackup()).packages, isEmpty);
        expect(calls, isEmpty);
      },
    );
  }

  test('installing after an empty enumeration still loads the newly installed source', () async {
    expect(await sources.listSources(SourceEngine.tachimanga), isEmpty);
    final file = File('${directory.path}/registry.json');
    await file.writeAsString(
      jsonEncode({
        'version': 1,
        'packages': {'fixture': {}},
      }),
    );
    expect(
      (await sources.listSources(SourceEngine.tachimanga)).single.id,
      '9007199254740993',
    );
    expect(calls, ['initialize', 'sources']);
    await file.writeAsString(jsonEncode({'version': 1, 'packages': {}}));
    expect(await sources.listSources(SourceEngine.tachimanga), isEmpty);
    expect(calls, ['initialize', 'sources']);
  });

  for (final contents in [
    '{broken',
    '{"version":2,"packages":{}}',
    '{"version":1,"packages":[]}',
  ]) {
    test(
      'invalid inventory is preserved and reported instead of silently treated as empty: $contents',
      () async {
        final file = File('${directory.path}/registry.json');
        await file.writeAsString(contents);
        await expectLater(
          sources.listSources(SourceEngine.tachimanga),
          throwsFormatException,
        );
        expect(await file.readAsString(), contents);
        expect(calls, isEmpty);
      },
    );
  }

  test('oversized inventory is rejected before Java startup', () async {
    final file = File('${directory.path}/registry.json');
    await file.writeAsBytes(List.filled(2 * 1024 * 1024 + 1, 32));
    await expectLater(
      sources.listSources(SourceEngine.tachimanga),
      throwsFormatException,
    );
    expect(await file.length(), 2 * 1024 * 1024 + 1);
    expect(calls, isEmpty);
  });

  test(
    'directory in place of inventory is reported without starting Java',
    () async {
      await Directory('${directory.path}/registry.json').create();
      await expectLater(
        sources.listSources(SourceEngine.tachimanga),
        throwsFormatException,
      );
      expect(calls, isEmpty);
    },
  );

  test('TMB source availability and library restore on a new installation do not require a VM', () async {
    final target = MemoryLibraryRepository();
    final service = BackupService(
      target,
      extensions: RepositoryExtensionBackupStore(
        runtime: sources,
        repository: target,
        engines: {SourceEngine.tachimanga},
        directory: Directory('${directory.path}/recovery'),
      ),
    );
    final preview = await service.preview(tmbFixture());
    final report = await checkBackupSourceAvailability(
      preview.snapshot,
      sources.listSources,
    );
    expect(report.missing, isNotEmpty);
    expect(report.unverified, isEmpty);
    expect(await service.mergePreview(preview), preview.books);
    expect((await target.list()).length, preview.books);
    expect(calls, isEmpty);
  });

  final sample = Platform.environment['TACHI_RESTORE_TMB_SAMPLE'];
  final nativeLibrary = Platform.environment['TACHI_ISAR_TEST_LIBRARY'];
  test(
    'private TMB completes real Isar restore, recovery and reopen on an empty installation without any VM call',
    () async {
      await Isar.initializeIsarCore(libraries: {Abi.current(): nativeLibrary!});
      final file = File(sample!);
      final input = await file.readAsBytes();
      final checksum = sha256.convert(input);
      final modified = file.statSync().modified;
      SharedPreferences.setMockInitialValues({'dark': true});
      final libraryPath = '${directory.path}/library';
      await Directory(libraryPath).create();
      final target = await LibraryRepository.open(directoryPath: libraryPath);
      var closed = false;
      var scriptCalls = 0;
      final vbook = NativeVbookRepository(
        storageDirectory: Directory('${directory.path}/vbook'),
        executor: (_, _) async {
          scriptCalls++;
          throw StateError('Unexpected VM call');
        },
      );
      sources.runtimes[SourceEngine.vbook] = vbook;
      try {
        final preferences = await CoordinatedPreferences.open(
          await SharedPreferences.getInstance(),
          target,
          journalDirectoryPath: '${directory.path}/configuration',
        );
        final service = BackupService(
          target,
          configuration: AppConfigurationStore(preferences),
          extensions: RepositoryExtensionBackupStore(
            runtime: sources,
            repository: target,
            engines: SourceEngine.values.toSet(),
            directory: Directory('${directory.path}/recovery'),
          ),
        );
        final preview = await service.preview(input);
        final chapterCount = preview.snapshot.entries.fold<int>(
          0,
          (n, e) => n + e.book.chapters.length,
        );
        final expectedBooks = int.tryParse(
          Platform.environment['TACHI_RESTORE_EXPECT_BOOKS'] ?? '',
        );
        final expectedChapters = int.tryParse(
          Platform.environment['TACHI_RESTORE_EXPECT_CHAPTERS'] ?? '',
        );
        if (expectedBooks != null) expect(preview.books, expectedBooks);
        if (expectedChapters != null) expect(chapterCount, expectedChapters);
        final inventory = await checkBackupSourceAvailability(
          preview.snapshot,
          sources.listSources,
        );
        expect(inventory.missing, isNotEmpty);
        expect(inventory.unverified, isEmpty);
        expect(await service.mergePreview(preview), preview.books);
        expect(
          (await target.snapshot()).fingerprint,
          LibrarySnapshot(preview.snapshot.entries).fingerprint,
        );
        expect(await service.exportRecovery(), isNotNull);
        expect(preferences.getBool('dark'), isTrue);
        await target.close();
        closed = true;
        final reopened = await LibraryRepository.open(
          directoryPath: libraryPath,
        );
        try {
          final books = await reopened.list();
          expect(books.length, preview.books);
          expect(
            books.fold<int>(0, (n, book) => n + book.chapters.length),
            chapterCount,
          );
          expect(
            (await reopened.snapshot()).fingerprint,
            LibrarySnapshot(preview.snapshot.entries).fingerprint,
          );
        } finally {
          await reopened.close();
        }
        expect(calls, isEmpty);
        expect(scriptCalls, 0);
        expect(sha256.convert(await file.readAsBytes()), checksum);
        expect(file.statSync().modified, modified);
      } finally {
        if (!closed) await target.close();
      }
    },
    skip: sample == null || nativeLibrary == null
        ? 'Opt-in read-only private TMB and actual Isar core.'
        : false,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
