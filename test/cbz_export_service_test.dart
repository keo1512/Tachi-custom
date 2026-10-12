import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:isar_community/isar.dart';
import 'package:tachi_books/features/downloads/data/cbz_export_service.dart';
import 'package:tachi_books/features/library/data/library_mutation.dart';
import 'package:tachi_books/features/library/data/library_repository.dart';
import 'package:tachi_books/features/library/domain/library_book.dart';

final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jf1kAAAAASUVORK5CYII=',
);
// Real one-pixel RGB JPEG, with a deliberately wrong MIME on one cached page.
final _jpeg = base64Decode(
  '/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAgGBgcGBQgHBwcJCQgKDBQNDAsLDBkSEw8UHRofHh0aHBwgJC4nICIsIxwcKDcpLDAxNDQ0Hyc5PTgyPC4zNDL/2wBDAQkJCQwLDBgNDRgyIRwhMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjL/wAARCAABAAEDASIAAhEBAxEB/8QAHwAAAQUBAQEBAQEAAAAAAAAAAAECAwQFBgcICQoL/8QAtRAAAgEDAwIEAwUFBAQAAAF9AQIDAAQRBRIhMUEGE1FhByJxFDKBkaEII0KxwRVS0fAkM2JyggkKFhcYGRolJicoKSo0NTY3ODk6Q0RFRkdISUpTVFVWV1hZWmNkZWZnaGlqc3R1dnd4eXqDhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uHi4+Tl5ufo6erx8vP09fb3+Pn6/8QAHwEAAwEBAQEBAQEBAQAAAAAAAAECAwQFBgcICQoL/8QAtREAAgECBAQDBAcFBAQAAQJ3AAECAxEEBSExBhJBUQdhcRMiMoEIFEKRobHBCSMzUvAVYnLRChYkNOEl8RcYGRomJygpKjU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6goOEhYaHiImKkpOUlZaXmJmaoqOkpaanqKmqsrO0tba3uLm6wsPExcbHyMnK0tPU1dbX2Nna4uPk5ebn6Onq8vP09fb3+Pn6/9oADAMBAAIRAxEAPwDnKKKK948Q/9k=',
);
String _image(List<int> bytes, [String mime = 'image/png']) =>
    'data:$mime;base64,${base64Encode(bytes)}';
LibraryBook _book() => LibraryBook(
  id: 'manga',
  title: '../Sách: gốc',
  kind: 'manga',
  engine: 'tachimanga',
  sourceId: 'source',
  sourceRef: '/book',
  currentChapter: 1,
  progress: .4,
  bookmarks: ['1:.4'],
  notes: 'Keep notes',
  chapters: const [
    BookChapter(
      id: '/first',
      title: 'One',
      index: 101,
      downloaded: true,
      read: true,
    ),
    BookChapter(
      id: '/second',
      title: 'Two',
      index: 97,
      downloaded: true,
      read: false,
    ),
    BookChapter(id: '/third', title: 'Three', index: 42, read: false),
  ],
);

Future<void> _cache(LibraryRepository repo, LibraryBook book) async {
  await repo.save(book);
  await repo.saveChapter(
    book.id,
    0,
    ReaderContent(
      kind: 'manga',
      images: [_image(_png), _image(_jpeg, 'image/png'), _image(_png)],
    ),
  );
  await repo.saveChapter(
    book.id,
    1,
    ReaderContent(kind: 'manga', images: [_image(_jpeg, 'image/jpeg')]),
  );
}

class _DelayedChapter extends MemoryLibraryRepository {
  final entered = Completer<void>(), release = Completer<void>();
  @override
  Future<LibraryChapterRead?> openChapter(
    String bookId,
    String chapterId,
  ) async {
    final read = await super.openChapter(bookId, chapterId);
    if (!entered.isCompleted) entered.complete();
    await release.future;
    return read;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('CBZ keeps original bytes, duplicate pages and stable TOC order without modifying library', () async {
    final repo = MemoryLibraryRepository(), book = _book();
    await _cache(repo, book);
    final before = (await repo.snapshot()).encode();
    final export = await CbzExportService(repo).exportBook(book);
    final archive = ZipDecoder().decodeBytes(export.bytes, verify: true);
    expect(export.chapters, 2);
    expect(export.pages, 4);
    expect(export.fileName, '.._Sách_ gốc.cbz');
    expect(archive.files.map((file) => file.name), [
      '00001/00001.png',
      '00001/00002.jpg',
      '00001/00003.png',
      '00002/00001.jpg',
    ]);
    expect(archive.files.map((file) => file.content).toList(), [
      _png,
      _jpeg,
      _png,
      _jpeg,
    ]);
    expect((await repo.snapshot()).encode(), before);
    final subset = await CbzExportService(repo)
        .exportBook(book, chapterIds: ['/second', '/first']);
    expect(
      ZipDecoder()
          .decodeBytes(subset.bytes)
          .files
          .map((file) => file.content)
          .toList(),
      [_png, _jpeg, _png, _jpeg],
    );
    final single = await CbzExportService(repo)
        .exportBook(book, chapterIds: ['/second']);
    expect(single.chapters, 1);
    expect(single.pages, 1);
    expect(ZipDecoder().decodeBytes(single.bytes).files.single.content, _jpeg);
  });

  test('partial remote, missing cache, unresolved attachment and bad image bytes cannot produce a fake complete CBZ', () async {
    final repo = MemoryLibraryRepository(), book = _book();
    await _cache(repo, book);
    for (final source in [
      'https://source.invalid/not-downloaded.png',
      'tachi-asset://unresolved',
      'data:image/png;base64,',
      _image(utf8.encode('not an image')),
    ]) {
      await repo.saveChapter(
        book.id,
        0,
        ReaderContent(kind: 'manga', images: [_image(_png), source]),
      );
      await expectLater(
        CbzExportService(repo).exportBook(book, chapterIds: ['/first']),
        throwsA(anyOf(isStateError, isFormatException)),
      );
    }
    await repo.deleteChapter(book.id, 0);
    await expectLater(
      CbzExportService(repo).exportBook(book, chapterIds: ['/first']),
      throwsStateError,
    );
    expect((await repo.find(book.id))!.notes, book.notes);
  });

  test('explicit selection rejects unknown or not-downloaded chapters and incompatible source snapshots', () async {
    final repo = MemoryLibraryRepository(), book = _book();
    await _cache(repo, book);
    final service = CbzExportService(repo);
    await expectLater(
      service.exportBook(book, chapterIds: ['/third']),
      throwsStateError,
    );
    await expectLater(
      service.exportBook(book, chapterIds: ['gone']),
      throwsStateError,
    );
    await expectLater(
      service.exportBook(book, chapterIds: []),
      throwsArgumentError,
    );
    await expectLater(
      service.exportBook(book.copyWith(sourceRef: '/another')),
      throwsStateError,
    );
    await repo.save(book.copyWith(kind: 'novel'));
    await expectLater(
      service.exportBook(book.copyWith(kind: 'novel')),
      throwsStateError,
    );
  });

  test('restore while collecting cached pages rejects old bytes and leaves restored data intact', () async {
    final repo = _DelayedChapter(), book = _book();
    await _cache(repo, book);
    final revision = repo.replacementRevision;
    final pending = CbzExportService(repo)
        .exportBook(book, expectedRevision: revision);
    final rejected = expectLater(pending, throwsStateError);
    await repo.entered.future;
    await repo.clear();
    await _cache(
      repo,
      book.copyWith(title: 'Restored', notes: 'Restored notes'),
    );
    final restored = (await repo.snapshot()).encode();
    repo.release.complete();
    await rejected;
    expect((await repo.snapshot()).encode(), restored);
    await expectLater(
      CbzExportService(repo).exportBook(book, expectedRevision: revision),
      throwsStateError,
    );
  });

  test('CBZ bounds decoded single-image and total byte sizes before writing an archive', () async {
    final repo = MemoryLibraryRepository();
    final large = Uint8List(LibraryRepository.maxImageBytes + 1)
      ..setRange(0, 8, _png);
    final book = _book().copyWith(
      chapters: const [
        BookChapter(id: 'one', title: 'One', index: 0, downloaded: true),
      ],
    );
    await repo.save(book);
    await repo.saveChapter(
      book.id,
      0,
      ReaderContent(kind: 'manga', images: [_image(large)]),
    );
    await expectLater(
      CbzExportService(repo).exportBook(book),
      throwsFormatException,
    );
    final bounded = Uint8List(LibraryRepository.maxImageBytes)
      ..setRange(0, 8, _png);
    final data = _image(bounded);
    final many = book.copyWith(
      chapters: List.generate(
        9,
        (i) => BookChapter(id: '$i', title: '$i', index: i, downloaded: true),
      ),
    );
    await repo.save(many);
    for (var i = 0; i < 9; i++) {
      await repo.saveChapter(
        book.id,
        i,
        ReaderContent(kind: 'manga', images: [data]),
      );
    }
    await expectLater(
      CbzExportService(repo).exportBook(many),
      throwsFormatException,
    );
  });

  test('CBZ bounds page count without truncating or exporting only the first pages', () async {
    final repo = MemoryLibraryRepository();
    final book = _book().copyWith(
      chapters: const [
        BookChapter(id: 'one', title: 'One', index: 0, downloaded: true),
      ],
    );
    await repo.save(book);
    await repo.saveChapter(
      book.id,
      0,
      ReaderContent(
        kind: 'manga',
        images: List.filled(CbzExportService.maxPages + 1, _image(_png)),
      ),
    );
    await expectLater(
      CbzExportService(repo).exportBook(book),
      throwsFormatException,
    );
  });

  final library = Platform.environment['TACHI_ISAR_TEST_LIBRARY'];
  test('native attachment hydration exports original cached page bytes after repository restart', () async {
    await Isar.initializeIsarCore(
      libraries: {Abi.current(): library!},
      download: false,
    );
    final dir = await Directory.systemTemp.createTemp('tachi-cbz-export-');
    final book = _book();
    var repo = await LibraryRepository.open(directoryPath: dir.path);
    try {
      await _cache(repo, book);
      await repo.close();
      repo = await LibraryRepository.open(directoryPath: dir.path);
      final export = await CbzExportService(repo).exportBook(book);
      expect(
        ZipDecoder()
            .decodeBytes(export.bytes, verify: true)
            .files
            .map((file) => file.content)
            .toList(),
        [_png, _jpeg, _png, _jpeg],
      );
      expect((await repo.find(book.id))!.toJson(), book.toJson());
    } finally {
      await repo.close();
      await dir.delete(recursive: true);
    }
  }, skip: library == null ? 'Opt-in official Windows Isar library.' : false);
}
