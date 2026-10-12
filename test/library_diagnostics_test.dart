import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:tachi_books/features/library/application/library_diagnostics.dart';
import 'package:tachi_books/features/library/data/library_repository.dart';
import 'package:tachi_books/features/library/data/library_snapshot.dart';
import 'package:tachi_books/features/library/domain/library_book.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('repair missing-download flags keeps cache/reading metadata and saves recovery', () async {
    final repo = MemoryLibraryRepository();
    final book = LibraryBook(
      id: 'b',
      title: 'Riêng tư',
      sourceRef: 'https://private.example',
      chapters: const [
        BookChapter(
          id: '0',
          title: 'Một',
          index: 0,
          downloaded: true,
          read: true,
        ),
        BookChapter(id: '1', title: 'Hai', index: 1, downloaded: true),
      ],
      progress: .5,
      bookmarks: ['0:0.2'],
      favorite: true,
      notes: 'Ghi chú',
      categories: ['A', 'B'],
    );
    await repo.save(book);
    await repo.saveChapter(
      'b',
      0,
      ReaderContent(kind: 'novel', html: '<p>Offline</p>'),
    );
    final health = LibraryDiagnostics(repo),
        preview = await LibraryDiagnostics(repo).inspect();
    expect(preview.books, 1);
    expect(preview.chapters, 2);
    expect(preview.missingDownloads, 1);
    final exported = utf8.decode(preview.exportSummary());
    expect(exported, isNot(contains('Riêng tư')));
    expect(exported, isNot(contains('private.example')));
    expect(await health.repairMissingDownloads(preview), 1);
    final repaired = (await repo.find('b'))!;
    expect(
      repaired.toJson(),
      book
          .copyWith(
            chapters: [
              book.chapters[0],
              book.chapters[1].copyWith(downloaded: false),
            ],
          )
          .toJson(),
    );
    expect((await repo.readChapter('b', 0))!.html, '<p>Offline</p>');
    expect(
      jsonDecode(
        utf8.decode((await repo.recoverySnapshot())!),
      )['entries'][0]['book']['chapters'][1]['downloaded'],
      true,
    );
  });
  test(
    'an edit or restore after inspection rejects repair without changing data',
    () async {
      final repo = MemoryLibraryRepository();
      await repo.save(
        LibraryBook(
          id: 'b',
          title: 'B',
          chapters: const [
            BookChapter(id: '0', title: 'Một', index: 0, downloaded: true),
          ],
        ),
      );
      final service = LibraryDiagnostics(repo),
          preview = await LibraryDiagnostics(repo).inspect();
      await repo.mutateBook('b', (book) => book.copyWith(notes: 'Mới'));
      await expectLater(
        service.repairMissingDownloads(preview),
        throwsStateError,
      );
      expect((await repo.find('b'))!.notes, 'Mới');
      expect((await repo.find('b'))!.chapters.single.downloaded, true);
      expect(await repo.recoverySnapshot(), isNull);
    },
  );
  test('decode scan reports unreadable local images without changing content or requesting remote images', () async {
    final repository = MemoryLibraryRepository();
    await repository.save(
      LibraryBook(
        id: 'b',
        title: 'Private title',
        kind: 'manga',
        cover: 'data:image/png;base64,SGVsbG8=',
        chapters: const [
          BookChapter(id: 'c', title: 'Private chapter', index: 0),
        ],
      ),
    );
    await repository.saveChapter(
      'b',
      0,
      ReaderContent(
        kind: 'manga',
        images: [
          'data:image/png;base64,SGVsbG8=',
          'https://never-request.example/image.png',
        ],
      ),
    );
    final before = (await repository.snapshot()).fingerprint;
    final result = await LibraryDiagnostics(repository).inspect();
    expect(result.checkedImages, 1);
    expect(result.damagedCovers, 1);
    expect(result.unreadableChapters.single.chapterIndex, 0);
    expect((await repository.snapshot()).fingerprint, before);
    final report = utf8.decode(result.exportSummary());
    expect(report, isNot(contains('Private')));
    expect(report, isNot(contains('never-request')));
  });
  test(
    'unreadable storage returns a safe report and cannot fabricate a snapshot',
    () async {
      final repository = _UnreadableRepository();
      final report = await LibraryDiagnostics(repository).inspect();
      expect(report.snapshot, isNull);
      expect(report.storageUnreadable, true);
      expect(report.validationError, isNot(contains('/private/')));
      expect(
        await LibraryDiagnostics(repository).repairMissingDownloads(report),
        0,
      );
      expect(await repository.recoverySnapshot(), isNull);
    },
  );
  test('valid decoded offline image is not reported unreadable', () async {
    const image =
        'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=';
    final repository = MemoryLibraryRepository();
    await repository.save(
      LibraryBook(
        id: 'b',
        title: 'Valid',
        kind: 'manga',
        cover: image,
        chapters: const [
          BookChapter(id: 'c', title: 'C', index: 0, downloaded: true),
        ],
      ),
    );
    await repository.saveChapter(
      'b',
      0,
      ReaderContent(kind: 'manga', images: [image]),
    );
    final report = await LibraryDiagnostics(repository).inspect();
    expect(report.validationError, isNull);
    expect(report.checkedImages, 1);
    expect(report.damagedCovers, 0);
    expect(report.unreadableChapters, isEmpty);
  });
  test('malformed negative cache index is reported without crashing or modifying storage', () async {
    final repository = _MalformedCacheRepository();
    final before = (await repository.snapshot()).fingerprint;
    final report = await LibraryDiagnostics(repository).inspect();
    expect(report.validationError, isNotNull);
    expect(report.unreadableChapters.single.chapterIndex, -1);
    expect(
      report.unreadableChapters.single.chapterTitle,
      'Chương không thuộc mục lục',
    );
    expect((await repository.snapshot()).fingerprint, before);
    expect(await repository.recoverySnapshot(), isNull);
  });
}

class _UnreadableRepository extends MemoryLibraryRepository {
  @override
  Future<Never> snapshot() async =>
      throw const FormatException('/private/account/file-corrupt');
}

class _MalformedCacheRepository extends MemoryLibraryRepository {
  @override
  Future<LibrarySnapshot> snapshot() async => LibrarySnapshot([
    LibrarySnapshotEntry(
      LibraryBook(
        id: 'b',
        title: 'Malformed',
        kind: 'manga',
        chapters: const [BookChapter(id: 'c', title: 'C', index: 0)],
      ),
      {
        -1: ReaderContent(
          kind: 'manga',
          images: ['data:image/png;base64,SGVsbG8='],
        ),
      },
    ),
  ]);
}
