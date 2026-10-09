import 'dart:convert';
import 'dart:io';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:isar_community/isar.dart';
import 'package:tachi_books/features/library/data/attachment_store_native.dart';
import 'package:tachi_books/features/library/data/backup_service.dart';
import 'package:tachi_books/features/library/data/document_importer.dart';
import 'package:tachi_books/features/library/data/library_repository.dart';
import 'package:tachi_books/features/library/domain/library_book.dart';

Uint8List archiveBytes(Map<String, List<int>> entries) {
  final archive = Archive();
  for (final entry in entries.entries) {
    archive.add(ArchiveFile.bytes(entry.key, entry.value));
  }
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

Map<String, List<int>> epubEntries({
  bool missingSpine = false,
  String chapterHref = 'chapter.xhtml',
}) => {
  'mimetype': utf8.encode('application/epub+zip'),
  'META-INF/container.xml': utf8.encode(
    '''<?xml version="1.0"?>
    <container xmlns="urn:oasis:names:tc:opendocument:xmlns:container" version="1.0">
    <rootfiles><rootfile full-path="OPS/book.opf" media-type="application/oebps-package+xml"/></rootfiles></container>''',
  ),
  'OPS/book.opf': utf8.encode(
    '''<package xmlns="http://www.idpf.org/2007/opf" version="3.0">
    <metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>Sách kiểm thử</dc:title><dc:creator>Tác giả</dc:creator></metadata>
    <manifest><item id="one" href="$chapterHref" media-type="application/xhtml+xml"/>
      <item id="cover" href="../images/cover.png" media-type="image/png" properties="cover-image"/></manifest>
    ${missingSpine ? '' : '<spine><itemref idref="one"/></spine>'}</package>''',
  ),
  'OPS/chapter.xhtml': utf8.encode(
    '''<html xmlns="http://www.w3.org/1999/xhtml"><head><title>Chương đầu</title></head>
    <body><h1>Xin chào</h1><p onclick="bad()">Nội dung offline.</p><script>bad()</script><img src="../images/cover.png"/></body></html>''',
  ),
  'images/cover.png': base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jf1kAAAAASUVORK5CYII=',
  ),
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final isarLibrary = Platform.environment['TACHI_ISAR_TEST_LIBRARY'];
  test(
    'Native Isar metadata and chapter attachments survive closing and reopening',
    () async {
      await Isar.initializeIsarCore(
        libraries: {Abi.current(): isarLibrary!},
        download: false,
      );
      final directory = await Directory.systemTemp.createTemp(
        'tachi-native-repository-test-',
      );
      LibraryRepository? repo;
      try {
        repo = await LibraryRepository.open(directoryPath: directory.path);
        final book = await DocumentImporter().import(
          'persist.epub',
          archiveBytes(epubEntries()),
          repo,
        );
        await repo.save(book.copyWith(progress: .37, bookmarks: ['0:0.37']));
        await repo.close();
        repo = await LibraryRepository.open(directoryPath: directory.path);
        final reopened = (await repo.find(book.id))!;
        expect(reopened.title, 'Sách kiểm thử');
        expect(reopened.progress, .37);
        expect(reopened.bookmarks, ['0:0.37']);
        expect(reopened.cover, startsWith('data:image/png;base64,'));
        final content = (await repo.readChapter(book.id, 0))!;
        expect(content.html, contains('data:image/png;base64,'));
        expect(content.html, isNot(contains('tachi-asset://')));
        await repo.saveChapter(
          book.id,
          1,
          ReaderContent(kind: 'manga', images: [reopened.cover]),
        );
        await repo.close();
        repo = await LibraryRepository.open(directoryPath: directory.path);
        expect(
          (await repo.readChapter(book.id, 1))!.images.single,
          reopened.cover,
        );
        await repo.remove(book.id);
        expect(await repo.find(book.id), isNull);
        expect(await repo.readChapter(book.id, 0), isNull);
      } finally {
        await repo?.close();
        await directory.delete(recursive: true);
      }
    },
    skip: isarLibrary == null
        ? 'Set TACHI_ISAR_TEST_LIBRARY to an official installed Isar Core library.'
        : false,
  );
  test(
    'Native backup moves all EPUB TXT CBZ content to a separate empty storage directory',
    () async {
      await Isar.initializeIsarCore(
        libraries: {Abi.current(): isarLibrary!},
        download: false,
      );
      final sourceDirectory = await Directory.systemTemp.createTemp(
        'tachi-backup-source-',
      );
      final destinationDirectory = await Directory.systemTemp.createTemp(
        'tachi-backup-destination-',
      );
      LibraryRepository? repository;
      try {
        repository = await LibraryRepository.open(
          directoryPath: sourceDirectory.path,
        );
        final importer = DocumentImporter();
        final epub = await importer.import(
          'offline.epub',
          archiveBytes(epubEntries()),
          repository,
        );
        final txt = await importer.import(
          'offline.txt',
          Uint8List.fromList(utf8.encode('Chương 1\nCó thể đọc ngay.')),
          repository,
        );
        final cbz = await importer.import(
          'offline.cbz',
          archiveBytes({'page1.png': epubEntries()['images/cover.png']!}),
          repository,
        );
        await repository.save(
          epub.copyWith(
            series: 'Bộ truyện mẫu',
            progress: .4,
            bookmarks: ['0:0.4'],
          ),
        );
        final sourceService = BackupService(repository);
        final bytes = await sourceService.export();
        final fingerprint = sourceService.fingerprint(bytes);
        await repository.close();
        repository = null;
        // Destination has neither source files nor attachment references.
        repository = await LibraryRepository.open(
          directoryPath: destinationDirectory.path,
        );
        var service = BackupService(repository);
        expect(await service.merge(bytes), 3);
        expect(service.fingerprint(await service.export()), fingerprint);
        await repository.close();
        repository = await LibraryRepository.open(
          directoryPath: destinationDirectory.path,
        );
        service = BackupService(repository);
        expect((await repository.find(epub.id))!.series, 'Bộ truyện mẫu');
        expect((await repository.find(epub.id))!.bookmarks, ['0:0.4']);
        expect(
          (await repository.readChapter(epub.id, 0))!.html,
          contains('data:image/png;base64,'),
        );
        expect(
          (await repository.readChapter(txt.id, 0))!.html,
          contains('Có thể đọc ngay.'),
        );
        expect(
          (await repository.readChapter(cbz.id, 0))!.images.single,
          startsWith('data:image/png;base64,'),
        );
        final recovered = await service.exportRecovery();
        expect(recovered, isNotNull);
        expect(
          service.fingerprint(recovered!),
          BackupService(MemoryLibraryRepository()).fingerprint(
            await BackupService(MemoryLibraryRepository()).export(),
          ),
        );
        // Cloud replacement updates existing state/content and saves all prior
        // offline media in a flushed, self-contained recovery image.
        final incomingRepository = MemoryLibraryRepository();
        final incoming = (await repository.find(txt.id))!
            .copyWith(progress: .8);
        await incomingRepository.save(incoming);
        await incomingRepository.saveChapter(
          txt.id,
          0,
          ReaderContent(kind: 'novel', html: '<p>Bản đồng bộ mới</p>'),
        );
        final remoteBytes = await BackupService(incomingRepository).export();
        final beforeReplace = await service.export();
        await service.replace(
          remoteBytes,
          expectedFingerprint: service.fingerprint(beforeReplace),
        );
        expect(
          service.fingerprint(await service.export()),
          service.fingerprint(remoteBytes),
        );
        expect(
          service.fingerprint((await service.exportRecovery())!),
          service.fingerprint(beforeReplace),
        );
        await repository.close();
        repository = await LibraryRepository.open(
          directoryPath: destinationDirectory.path,
        );
        service = BackupService(repository);
        expect((await repository.find(txt.id))!.progress, .8);
        expect(
          (await repository.readChapter(txt.id, 0))!.html,
          '<p>Bản đồng bộ mới</p>',
        );
        final recoveryBytes = (await service.exportRecovery())!;
        await service.replace(
          recoveryBytes,
          expectedFingerprint: service.fingerprint(await service.export()),
        );
        expect(
          (await repository.readChapter(epub.id, 0))!.html,
          contains('data:image/png;base64,'),
        );
        expect(
          (await repository.readChapter(cbz.id, 0))!.images.single,
          startsWith('data:image/png;base64,'),
        );
      } finally {
        await repository?.close();
        await sourceDirectory.delete(recursive: true);
        await destinationDirectory.delete(recursive: true);
      }
    },
    skip: isarLibrary == null
        ? 'Set TACHI_ISAR_TEST_LIBRARY for native persistence.'
        : false,
  );

  test(
    'Native stale full-content replacement and failed recovery write preserve current library',
    () async {
      await Isar.initializeIsarCore(
        libraries: {Abi.current(): isarLibrary!},
        download: false,
      );
      final directory = await Directory.systemTemp.createTemp(
        'tachi-backup-atomic-',
      );
      LibraryRepository? repository;
      try {
        repository = await LibraryRepository.open(
          directoryPath: directory.path,
        );
        final book = await DocumentImporter().import(
          'book.epub',
          archiveBytes(epubEntries()),
          repository,
        );
        final service = BackupService(repository);
        final initial = await service.export();
        final oldFingerprint = service.fingerprint(initial);
        await repository.saveChapter(
          book.id,
          0,
          ReaderContent(kind: 'novel', html: '<p>Thay đổi sau preview</p>'),
        );
        final current = await service.export();
        await expectLater(
          service.replace(initial, expectedFingerprint: oldFingerprint),
          throwsStateError,
        );
        expect(
          service.fingerprint(await service.export()),
          service.fingerprint(current),
        );
        expect(await service.exportRecovery(), isNull);
        // A directory creation failure occurs before the first Isar mutation.
        await File('${directory.path}/backup-recovery')
            .writeAsString('blocked');
        await expectLater(
          service.replace(
            initial,
            expectedFingerprint: service.fingerprint(current),
          ),
          throwsA(isA<FileSystemException>()),
        );
        expect(
          service.fingerprint(await service.export()),
          service.fingerprint(current),
        );
        await repository.close();
        repository = await LibraryRepository.open(
          directoryPath: directory.path,
        );
        expect(
          (await repository.readChapter(book.id, 0))!.html,
          contains('Thay đổi sau preview'),
        );
        expect(
          (await repository.find(book.id))!.cover,
          startsWith('data:image/png;base64,'),
        );
      } finally {
        await repository?.close();
        await directory.delete(recursive: true);
      }
    },
    skip: isarLibrary == null
        ? 'Set TACHI_ISAR_TEST_LIBRARY for native atomic restore.'
        : false,
  );
  test('TXT UTF8 BOM imports real chapters and escapes text', () async {
    final repo = MemoryLibraryRepository();
    final book = await DocumentImporter().import(
      'truyện.txt',
      Uint8List.fromList(
        utf8.encode('\uFEFFChương 1\nA < B.\n\nChương 2\nTiếng Việt.'),
      ),
      repo,
    );
    expect(book.title, 'truyện');
    expect(book.chapters.length, 2);
    expect(book.chapters.first.title, 'Chương 1');
    expect((await repo.readChapter(book.id, 0))!.html, contains('A &lt; B.'));
    expect((await repo.readChapter(book.id, 1))!.html, contains('Tiếng Việt.'));
    expect(book.chapters.every((chapter) => chapter.downloaded), isTrue);
  });
  test(
    'Reimport content under another filename preserves all reading state',
    () async {
      final repo = MemoryLibraryRepository();
      final bytes = Uint8List.fromList(utf8.encode('Nội dung.'));
      final book = await DocumentImporter().import('one.txt', bytes, repo);
      final date = DateTime.utc(2026, 10, 8);
      await repo.save(
        book.copyWith(
          progress: .42,
          favorite: true,
          collection: 'Đang đọc',
          lastRead: date,
          bookmarks: ['0:0.42'],
        ),
      );
      final duplicate = await DocumentImporter().import('two.txt', bytes, repo);
      expect((await repo.list()).length, 1);
      expect(duplicate.title, 'one');
      expect(duplicate.progress, .42);
      expect(duplicate.favorite, isTrue);
      expect(duplicate.lastRead, date);
      expect(duplicate.bookmarks, ['0:0.42']);
    },
  );
  test(
    'EPUB parses container OPF spine cover and relative images offline',
    () async {
      final repo = MemoryLibraryRepository();
      final book = await DocumentImporter().import(
        'sample.epub',
        archiveBytes(epubEntries()),
        repo,
      );
      expect(book.title, 'Sách kiểm thử');
      expect(book.author, 'Tác giả');
      expect(book.chapters.single.title, 'Chương đầu');
      expect(book.cover, startsWith('data:image/png;base64,'));
      final content = (await repo.readChapter(book.id, 0))!;
      expect(content.html, contains('Nội dung offline.'));
      expect(content.html, contains('data:image/png;base64,'));
      expect(content.html, isNot(contains('<script')));
      expect(content.html, isNot(contains('onclick')));
    },
  );
  test(
    'EPUB imports a single explicit series from calibre or EPUB3 metadata only',
    () async {
      for (final metadata in [
        '<meta name="calibre:series" content="Bộ truyện mẫu"/>',
        '<meta property="belongs-to-collection" id="series">Bộ truyện mẫu</meta><meta refines="#series" property="collection-type">series</meta>',
      ]) {
        final entries = epubEntries();
        entries['OPS/book.opf'] = utf8.encode(
          utf8
              .decode(entries['OPS/book.opf']!)
              .replaceFirst('</metadata>', '$metadata</metadata>'),
        );
        final book = await DocumentImporter().import(
          'series.epub',
          archiveBytes(entries),
          MemoryLibraryRepository(),
        );
        expect(book.series, 'Bộ truyện mẫu');
      }
      final entries = epubEntries();
      entries['OPS/book.opf'] = utf8.encode(
        utf8
            .decode(entries['OPS/book.opf']!)
            .replaceFirst(
              '</metadata>',
              '<meta name="calibre:series" content="A"/><meta name="calibre:series" content="B"/></metadata>',
            ),
      );
      expect(
        (await DocumentImporter().import(
          'ambiguous.epub',
          archiveBytes(entries),
          MemoryLibraryRepository(),
        )).series,
        '',
      );
    },
  );
  test(
    'EPUB missing spine or chapter fails without a visible partial book',
    () async {
      final repo = MemoryLibraryRepository();
      for (final entries in [
        epubEntries(missingSpine: true),
        epubEntries(chapterHref: 'missing.xhtml'),
      ]) {
        await expectLater(
          DocumentImporter().import('sample.epub', archiveBytes(entries), repo),
          throwsA(isA<FormatException>()),
        );
      }
      expect(await repo.list(), isEmpty);
    },
  );
  test('EPUB rejects references escaping archive root', () async {
    await expectLater(
      DocumentImporter().import(
        'sample.epub',
        archiveBytes(epubEntries(chapterHref: '../../outside.xhtml')),
        MemoryLibraryRepository(),
      ),
      throwsA(isA<FormatException>()),
    );
  });
  test('CBZ sorts page2 before page10 and persists real page bytes', () async {
    final repo = MemoryLibraryRepository();
    final book = await DocumentImporter().import(
      'comic.cbz',
      archiveBytes({
        'page10.png': [10],
        'page2.png': [2],
        'page1.png': [1],
      }),
      repo,
    );
    final content = (await repo.readChapter(book.id, 0))!;
    expect(book.kind, 'manga');
    expect(
      content.images.map(
        (image) => UriData.parse(image).contentAsBytes().single,
      ),
      [1, 2, 10],
    );
  });
  test(
    'ZIP path traversal and excessive declared expansion are rejected',
    () async {
      final importer = DocumentImporter();
      await expectLater(
        importer.import(
          'bad.cbz',
          archiveBytes({
            '../page.png': [1],
          }),
          MemoryLibraryRepository(),
        ),
        throwsA(isA<FormatException>()),
      );
      final bytes = archiveBytes({
        'page.png': [1],
      });
      final data = ByteData.sublistView(bytes);
      for (var offset = 0; offset + 46 <= bytes.length; offset++) {
        if (data.getUint32(offset, Endian.little) == 0x02014b50) {
          data.setUint32(
            offset + 24,
            DocumentImporter.maxEntryBytes + 1,
            Endian.little,
          );
          break;
        }
      }
      await expectLater(
        importer.import('huge.cbz', bytes, MemoryLibraryRepository()),
        throwsA(isA<FormatException>()),
      );
    },
  );
  test('Forged small ZIP expansion size is bounded during inflation', () async {
    final bytes = archiveBytes({'page.png': List<int>.filled(1024 * 1024, 0)});
    final data = ByteData.sublistView(bytes);
    for (var offset = 0; offset + 46 <= bytes.length; offset++) {
      if (data.getUint32(offset, Endian.little) == 0x02014b50) {
        data.setUint32(offset + 24, 1, Endian.little);
        break;
      }
    }
    await expectLater(
      DocumentImporter().import('forged.cbz', bytes, MemoryLibraryRepository()),
      throwsA(isA<FormatException>()),
    );
  });
  test(
    'Browser metadata and content survive reopening preferences repository',
    () async {
      SharedPreferences.setMockInitialValues({});
      final repo = await LibraryRepository.openWebPreview();
      final book = await DocumentImporter().import(
        'stored.txt',
        Uint8List.fromList(utf8.encode('Nội dung bền vững.')),
        repo,
      );
      await repo.save(book.copyWith(progress: .7, bookmarks: ['0:0.7']));
      final reopened = await LibraryRepository.openWebPreview();
      expect((await reopened.find(book.id))!.progress, .7);
      expect(
        (await reopened.readChapter(book.id, 0))!.html,
        contains('bền vững'),
      );
      await reopened.remove(book.id);
      expect(await reopened.readChapter(book.id, 0), isNull);
    },
  );
  test(
    'Browser preview storage cap rolls back a failed first import',
    () async {
      SharedPreferences.setMockInitialValues({});
      final repo = await LibraryRepository.openWebPreview();
      await expectLater(
        DocumentImporter().import(
          'large.txt',
          Uint8List.fromList(
            utf8.encode('a' * (LibraryRepository.webPreviewBytes + 1)),
          ),
          repo,
        ),
        throwsA(isA<FormatException>()),
      );
      expect(await repo.list(), isEmpty);
    },
  );
  test(
    'Native attachment files persist and are removed only for the target book',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'tachi-attachment-test-',
      );
      try {
        final store = await AttachmentStore.open(directory.path);
        final reference = await store.store(
          'book1',
          Uint8List.fromList([1, 2, 3]),
          'image/png',
        );
        final other = await store.store(
          'book2',
          Uint8List.fromList([4]),
          'image/png',
        );
        final reopened = await AttachmentStore.open(directory.path);
        expect(
          UriData.parse(await reopened.resolve(reference)).contentAsBytes(),
          [1, 2, 3],
        );
        await reopened.removeBook('book1');
        expect(UriData.parse(await reopened.resolve(other)).contentAsBytes(), [
          4,
        ]);
        await expectLater(
          reopened.resolve(reference),
          throwsA(isA<FileSystemException>()),
        );
      } finally {
        await directory.delete(recursive: true);
      }
    },
  );
  test('Book serialization includes bookmarks and explicit history clear', () {
    final book = LibraryBook(
      id: 'one',
      title: 'Title',
      lastRead: DateTime.utc(2026),
      bookmarks: ['0:0.2'],
    ).copyWith(clearLastRead: true);
    final restored = LibraryBook.fromJson(book.toJson());
    expect(restored.lastRead, isNull);
    expect(restored.bookmarks, ['0:0.2']);
  });
}
