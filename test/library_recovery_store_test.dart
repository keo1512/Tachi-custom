import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:isar_community/isar.dart';
import 'package:tachi_books/features/library/data/library_recovery_store.dart';
import 'package:tachi_books/features/library/data/library_repository.dart';
import 'package:tachi_books/features/library/data/library_snapshot.dart';
import 'package:tachi_books/features/library/domain/library_book.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  setUp(
    () async => root = await Directory.systemTemp.createTemp('tachi-recovery-'),
  );
  tearDown(() async {
    await Isar.getInstance('tachi_books')?.close();
    // Test-owned, resolved temporary root only.
    await root.delete(recursive: true);
  });

  Future<LibraryRepository> fakeOpen(String path) async {
    await File('$path/tachi_books.isar').writeAsString('fixture');
    return repositories.putIfAbsent(path, MemoryLibraryRepository.new);
  }

  setUp(repositories.clear);
  test('explicit recovery can supersede damaged selector while preserving it and every old managed generation', () async {
    final records = Directory('${root.path}/.library-locations');
    await records.create();
    final record = File(
      '${records.path}/active-00000000000000000001-0000000000000000.json',
    );
    await record.writeAsString('original damaged selector');
    final old = File(
      '${root.path}/.library-recovery/00000000000000000000-0000000000000000/library/tachi_books.isar',
    );
    await old.parent.create(recursive: true);
    await old.writeAsString('kept old database');
    final store = LibraryRecoveryStore(root, openRepository: fakeOpen);
    await expectLater(store.selection(), throwsFormatException);
    final selection = await store.selection(forRecovery: true);
    final result = await store.restore(
      snapshot: _image(),
      expectedSelectionToken: selection.token,
    );
    expect((await store.selection()).token, result.selection.token);
    expect(await record.readAsString(), 'original damaged selector');
    expect(await old.readAsString(), 'kept old database');
    expect(
      await File(
        '${result.preservedDirectoryPath}/location-records/${record.uri.pathSegments.last}',
      ).readAsString(),
      'original damaged selector',
    );
    expect(
      await File(
        '${result.preservedDirectoryPath}/previous-generations/00000000000000000000-0000000000000000/library/tachi_books.isar',
      ).readAsString(),
      'kept old database',
    );
  });
  test('fresh database is reopened and verified before publication; corrupt originals retained byte-for-byte', () async {
    final original = File('${root.path}/tachi_books.isar');
    await original.writeAsBytes([0, 255, 5, 3]);
    final asset = File('${root.path}/attachments/raw/file.bin');
    await asset.parent.create(recursive: true);
    await asset.writeAsBytes([4, 3, 2, 1]);
    final store = LibraryRecoveryStore(root, openRepository: fakeOpen);
    final image = _image();
    final result = await store.restore(
      snapshot: image,
      expectedSelectionToken: 'default',
    );
    expect(result.snapshot.fingerprint, image.fingerprint);
    expect(result.copiedFiles, 2);
    expect(await original.readAsBytes(), [0, 255, 5, 3]);
    expect(await asset.readAsBytes(), [4, 3, 2, 1]);
    expect(
      await File('${result.preservedDirectoryPath}/tachi_books.isar')
          .readAsBytes(),
      [0, 255, 5, 3],
    );
    expect(await File(result.originalBackupPath).readAsBytes(), image.encode());
    final selected = await LibraryRecoveryStore(root).selection();
    expect(selected.token, result.selection.token);
    expect(selected.directoryPath, result.selection.directoryPath);
    await expectLater(
      store.restore(snapshot: image, expectedSelectionToken: 'default'),
      throwsStateError,
    );
  });
  test(
    'failure before publication leaves original selection and files intact',
    () async {
      final original = File('${root.path}/tachi_books.isar');
      await original.writeAsString('corrupt but retained');
      final store = LibraryRecoveryStore(
        root,
        openRepository: fakeOpen,
        beforePublish: () async =>
            throw const FileSystemException('fixture no space'),
      );
      await expectLater(
        store.restore(snapshot: _image(), expectedSelectionToken: 'default'),
        throwsA(isA<FileSystemException>()),
      );
      expect((await store.selection()).token, 'default');
      expect(await original.readAsString(), 'corrupt but retained');
    },
  );
  test(
    'failed reopen verification and lost privacy guard never publish',
    () async {
      var count = 0;
      final store = LibraryRecoveryStore(
        root,
        openRepository: (path) async {
          count++;
          await File('$path/tachi_books.isar').writeAsString('fixture');
          return MemoryLibraryRepository();
        },
      );
      await expectLater(
        store.restore(snapshot: _image(), expectedSelectionToken: 'default'),
        throwsStateError,
      );
      expect(count, 2);
      expect((await store.selection()).token, 'default');
      var checks = 0;
      final guarded = LibraryRecoveryStore(root, openRepository: fakeOpen);
      await expectLater(
        guarded.restore(
          snapshot: _image(),
          expectedSelectionToken: 'default',
          guard: () {
            if (++checks > 1) throw StateError('locked');
          },
        ),
        throwsStateError,
      );
      expect((await guarded.selection()).token, 'default');
    },
  );
  test('malformed or escaping location fails closed, never opens default empty data', () async {
    final records = Directory('${root.path}/.library-locations');
    await records.create();
    final file = File(
      '${records.path}/active-00000000000000000001-0000000000000000.json',
    );
    await file.writeAsString(
      jsonEncode({
        'schema': 'tachi-books-library-location',
        'version': 1,
        'directory': '../outside',
      }),
    );
    await expectLater(
      LibraryRecoveryStore(root).selection(),
      throwsFormatException,
    );
    expect(await file.exists(), true);
  });
  test(
    'latest valid recovery skips damaged files without deleting them',
    () async {
      final directory = Directory('${root.path}/backup-recovery');
      await directory.create();
      final good = File('${directory.path}/recovery-1.json');
      final bad = File('${directory.path}/recovery-2.json');
      await good.writeAsBytes(_image().encode());
      await bad.writeAsString('broken');
      final store = LibraryRecoveryStore(root);
      expect(
        await store.latestRecovery(await store.selection()),
        _image().encode(),
      );
      expect(await bad.readAsString(), 'broken');
    },
  );
  test(
    'invalid input is refused before staging; active raw data not touched',
    () async {
      final store = LibraryRecoveryStore(root, openRepository: fakeOpen);
      final invalid = LibrarySnapshot([
        LibrarySnapshotEntry(LibraryBook(id: 'b', title: ''), {}),
      ]);
      await expectLater(
        store.restore(snapshot: invalid, expectedSelectionToken: 'default'),
        throwsFormatException,
      );
      expect(await Directory('${root.path}/.library-recovery').exists(), false);
    },
  );
  test(
    'real Isar rebuild survives reopen and preserves offline manga/novel after corrupt original',
    () async {
      await Isar.initializeIsarCore(
        libraries: {
          Abi.windowsX64: Platform.environment['TACHI_ISAR_TEST_LIBRARY']!,
        },
      );
      final original = File('${root.path}/tachi_books.isar');
      await original.writeAsBytes([6, 7, 8, 9]);
      final store = LibraryRecoveryStore(root);
      final image = _image();
      final result = await store.restore(
        snapshot: image,
        expectedSelectionToken: 'default',
      );
      final restored = await LibraryRepository.open(
        directoryPath: (await store.selection()).directoryPath,
      );
      try {
        expect((await restored.snapshot()).fingerprint, image.fingerprint);
        expect(
          (await restored.readChapter('m', 0))!.images.single,
          startsWith('data:image/png;base64,'),
        );
        expect(
          (await restored.readChapter('n', 0))!.html,
          '<p>Offline EPUB/TXT</p>',
        );
        expect(await original.readAsBytes(), [6, 7, 8, 9]);
        expect(
          await File('${result.preservedDirectoryPath}/tachi_books.isar')
              .readAsBytes(),
          [6, 7, 8, 9],
        );
        await expectLater(
          LibraryRepository.open(directoryPath: root.path),
          throwsStateError,
        );
      } finally {
        await restored.close();
      }
    },
    skip: Platform.environment['TACHI_ISAR_TEST_LIBRARY'] == null
        ? 'Opt-in native Isar DLL'
        : false,
  );
}

final repositories = <String, MemoryLibraryRepository>{};
LibrarySnapshot _image() => LibrarySnapshot([
  LibrarySnapshotEntry(
    LibraryBook(
      id: 'm',
      title: 'Manga',
      kind: 'manga',
      chapters: const [
        BookChapter(id: 'c', title: 'C', index: 0, downloaded: true),
      ],
    ),
    {
      0: ReaderContent(
        kind: 'manga',
        images: [
          'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aG7sAAAAASUVORK5CYII=',
        ],
      ),
    },
  ),
  LibrarySnapshotEntry(
    LibraryBook(
      id: 'n',
      title: 'Novel',
      chapters: const [
        BookChapter(id: 'c', title: 'C', index: 0, downloaded: true),
      ],
    ),
    {0: ReaderContent(kind: 'novel', html: '<p>Offline EPUB/TXT</p>')},
  ),
]);
