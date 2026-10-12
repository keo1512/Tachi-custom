import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:isar_community/isar.dart';
import 'package:tachi_books/features/library/data/attachment_gc.dart';
import 'package:tachi_books/features/library/data/backup_validation.dart';
import 'package:tachi_books/features/library/data/isar_models.dart';
import 'package:tachi_books/features/library/data/library_cache_maintenance.dart';
import 'package:tachi_books/features/library/data/library_repository.dart';
import 'package:tachi_books/features/library/domain/library_book.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('invalid downloaded flag with remote media blocks cleanup and retains all bytes', () async {
    final repo = MemoryLibraryRepository();
    await _seed(repo);
    await repo.saveChapter(
      'online',
      2,
      ReaderContent(
        kind: 'novel',
        html: '<p>Partial</p><img src="https://example.org/partial.png">',
      ),
    );
    final image = await repo.snapshot();
    await expectLater(
      repo.clearTransientChapterCache(expectedFingerprint: image.fingerprint),
      throwsFormatException,
    );
    expect((await repo.snapshot()).fingerprint, image.fingerprint);
    expect(await repo.recoverySnapshot(), isNull);
    expect(await repo.readChapter('online', 0), isNotNull);
  });
  test('transient cache deletion retains local, all offline and flagged partial downloads with recovery', () async {
    final repo = MemoryLibraryRepository();
    await _seed(repo);
    final image = await repo.snapshot();
    expect((await repo.inspectStorage()).transientChapters, 1);
    final result = await repo.clearTransientChapterCache(
      expectedFingerprint: image.fingerprint,
    );
    expect(result.removedChapters, 1);
    expect(await repo.readChapter('online', 0), isNull);
    expect(await repo.readChapter('online', 1), isNotNull);
    expect(await repo.readChapter('online', 2), isNotNull);
    expect(await repo.readChapter('local', 0), isNotNull);
    expect(
      (await repo.find('online'))!.toJson(),
      image.entries.firstWhere((e) => e.book.id == 'online').book.toJson(),
    );
    expect(
      BackupValidator(repo)
          .validateSnapshot((await repo.recoverySnapshot())!)
          .fingerprint,
      image.fingerprint,
    );
  });

  test(
    'stale preview and failed privacy guard do not remove or create recovery',
    () async {
      final repo = MemoryLibraryRepository();
      await _seed(repo);
      final image = await repo.snapshot();
      await repo.mutateBook('online', (book) => book.copyWith(notes: 'later'));
      await expectLater(
        repo.clearTransientChapterCache(expectedFingerprint: image.fingerprint),
        throwsStateError,
      );
      await expectLater(
        repo.clearTransientChapterCache(
          expectedFingerprint: (await repo.snapshot()).fingerprint,
          guard: () => throw StateError('locked'),
        ),
        throwsStateError,
      );
      expect(await repo.readChapter('online', 0), isNotNull);
      expect(await repo.recoverySnapshot(), isNull);
    },
  );

  test('raw references include unknown nested payload, original cover, header and HTML values', () {
    final folder = 'a' * 64;
    final digest = 'b' * 64;
    final ref = 'tachi-asset://$folder/$digest?type=image%2Fpng';
    expect(
      rawAttachmentKeys({
        'originalCover': ref,
        'unknown': [
          {'memo': ref},
        ],
        'html': '<img src="$ref">',
      }),
      {'$folder/$digest'},
    );
    expect(
      () => rawAttachmentKeys('tachi-asset://$folder/../bad'),
      throwsFormatException,
    );
  });

  test('hash GC enumerator only selects unreferenced valid content-addressed files', () async {
    final root = await Directory.systemTemp.createTemp('tachi-gc-');
    addTearDown(() => root.delete(recursive: true));
    final folder = Directory('${root.path}/${'a' * 64}');
    await folder.create();
    final keep = await _file(folder, [1, 2]);
    final remove = await _file(folder, [3, 4]);
    final unknown = File('${folder.path}/unknown.txt');
    await unknown.writeAsString('leave intact');
    final candidates = await findUnusedAttachments(root, {
      '${'a' * 64}/${keep.uri.pathSegments.last}',
    });
    expect(
      candidates.single.file.absolute.uri.normalizePath(),
      remove.absolute.uri.normalizePath(),
    );
    await verifyUnusedAttachment(candidates.single, root);
    expect(await unknown.readAsString(), 'leave intact');
    await remove.writeAsBytes([5, 6]);
    await expectLater(
      verifyUnusedAttachment(candidates.single, root),
      throwsA(isA<FileSystemException>()),
    );
  });

  test(
    'native Isar GC retains raw unknown reference and both covers; removes orphan file after recovery',
    () async {
      await Isar.initializeIsarCore(
        libraries: {
          Abi.windowsX64: Platform.environment['TACHI_ISAR_TEST_LIBRARY']!,
        },
      );
      final root = await Directory.systemTemp.createTemp('tachi-cache-native-');
      LibraryRepository? repository;
      try {
        repository = await LibraryRepository.open(directoryPath: root.path);
        await _seed(repository);
        final bytes = Uint8List.fromList(base64Decode(_png.split(',').last));
        final cover = await repository.storeAttachment(
          'online',
          bytes,
          'image/png',
        );
        final original = await repository.storeAttachment(
          'online',
          Uint8List.fromList([8, 9]),
          'image/png',
        );
        final opaque = await repository.storeAttachment(
          'online',
          Uint8List.fromList([6, 7]),
          'image/png',
        );
        final orphan = await repository.storeAttachment(
          'online',
          Uint8List.fromList([3, 5]),
          'image/png',
        );
        final isar = Isar.getInstance('tachi_books')!;
        final row = (await isar.libraryRecords.where().findAll()).firstWhere(
          (row) => row.bookId == 'online',
        );
        final payload = jsonDecode(row.payload) as Map<String, dynamic>;
        payload['cover'] = cover;
        payload['customCover'] = true;
        payload['originalCover'] = original;
        payload['futureOpaque'] = {
          'nested': [opaque],
        };
        row.payload = jsonEncode(payload);
        await isar.writeTxn(() => isar.libraryRecords.put(row));
        final before = await repository.snapshot();
        final report = await repository.inspectStorage();
        expect(report.unusedAttachmentFiles, 1);
        expect(report.downloadedBytes, greaterThan(0));
        final result = await repository.collectUnusedAttachments(
          expectedFingerprint: before.fingerprint,
        );
        expect(result.removedFiles, 1);
        for (final retained in [cover, original, opaque]) {
          expect(await _assetFile(root, retained).exists(), true);
        }
        expect(await _assetFile(root, orphan).exists(), false);
        expect(
          jsonDecode(
            (await isar.libraryRecords.where().findAll())
                .firstWhere((row) => row.bookId == 'online')
                .payload,
          )['futureOpaque'],
          payload['futureOpaque'],
        );
        expect((await repository.snapshot()).fingerprint, before.fingerprint);
        expect(await repository.recoverySnapshot(), isNotNull);
        final sidecars = await Directory('${root.path}/backup-recovery')
            .list()
            .where(
              (file) => file.uri.pathSegments.last.startsWith('raw-recovery-'),
            )
            .toList();
        final raw =
            jsonDecode(await File(sidecars.single.path).readAsString()) as Map;
        final rawBook = (raw['books'] as List).cast<Map>().firstWhere(
          (row) => row['bookId'] == 'online',
        );
        expect(
          jsonDecode(rawBook['payload'] as String)['futureOpaque'],
          payload['futureOpaque'],
        );
        final cleared = await repository.clearTransientChapterCache(
          expectedFingerprint: before.fingerprint,
        );
        expect(cleared.removedChapters, 1);
        await repository.close();
        repository = null;
        repository = await LibraryRepository.open(directoryPath: root.path);
        expect(await repository.readChapter('online', 0), isNull);
        expect(await repository.readChapter('online', 1), isNotNull);
        expect(await repository.readChapter('online', 2), isNotNull);
        expect(await repository.readChapter('local', 0), isNotNull);
      } finally {
        await repository?.close();
        await root.delete(recursive: true);
      }
    },
    skip: Platform.environment['TACHI_ISAR_TEST_LIBRARY'] == null
        ? 'Provide real native Isar DLL'
        : false,
  );
}

const _png =
    'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jf1kAAAAASUVORK5CYII=';

Future<void> _seed(LibraryRepository repository) async {
  await repository.save(
    LibraryBook(
      id: 'online',
      title: 'Online',
      engine: 'tachimanga',
      sourceId: '1',
      sourceRef: '/book',
      chapters: const [
        BookChapter(id: 'c0', title: 'Temporary', index: 0),
        BookChapter(id: 'c1', title: 'Offline', index: 1),
        BookChapter(
          id: 'c2',
          title: 'Flagged offline',
          index: 2,
          downloaded: true,
        ),
      ],
    ),
  );
  await repository.saveChapter(
    'online',
    0,
    ReaderContent(
      kind: 'novel',
      html: '<p>Temp</p><img src="https://example.org/temp.png">',
    ),
  );
  await repository.saveChapter(
    'online',
    1,
    ReaderContent(kind: 'novel', html: '<p>Offline</p>'),
  );
  await repository.saveChapter(
    'online',
    2,
    ReaderContent(kind: 'novel', html: '<p>Offline flagged</p>'),
  );
  await repository.save(
    LibraryBook(
      id: 'local',
      title: 'Local',
      chapters: const [BookChapter(id: 'local0', title: '1', index: 0)],
    ),
  );
  await repository.saveChapter(
    'local',
    0,
    ReaderContent(
      kind: 'novel',
      html: '<p>Keep local</p><img src="https://example.org/local.png">',
    ),
  );
}

Future<File> _file(Directory folder, List<int> bytes) async {
  final file = File('${folder.path}/${sha256.convert(bytes)}');
  await file.writeAsBytes(bytes);
  return file;
}

File _assetFile(Directory root, String reference) {
  final uri = Uri.parse(reference);
  return File('${root.path}/attachments/${uri.host}${uri.path}');
}
