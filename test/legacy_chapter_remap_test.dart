import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:isar_community/isar.dart';
import 'package:tachi_books/features/library/data/library_repository.dart';
import 'package:tachi_books/features/library/domain/library_book.dart';

LibraryBook _book({String ref = '/title'}) => LibraryBook(
  id: 'legacy',
  title: 'Truyện',
  kind: 'manga',
  engine: 'tachimanga',
  sourceId: '9223372036854775001',
  sourceRef: ref,
  currentChapter: 1,
  progress: .75,
  bookmarks: ['0:0.5', '1:0.25'],
  chapters: const [
    BookChapter(
      id: '0',
      title: 'Chương 1',
      index: 0,
      read: true,
      downloaded: true,
      number: 1,
    ),
    BookChapter(id: '1', title: 'Chương 2', index: 1, read: false, number: 2),
  ],
);
const _incoming = [
  BookChapter(id: '/c1', title: 'Chương 1', index: 0, number: 1),
  BookChapter(id: '/c2', title: 'Chương 2', index: 1, number: 2),
  BookChapter(id: '/c3', title: 'Chương 3', index: 2, number: 3),
];

Future<MemoryLibraryRepository> _repository(LibraryBook book) async {
  final repo = MemoryLibraryRepository();
  await repo.save(book);
  await repo.saveChapter(
    book.id,
    0,
    ReaderContent(
      kind: 'manga',
      images: [
        'data:image/png;base64,${base64Encode([1, 2, 3])}',
      ],
    ),
  );
  return repo;
}

void main() {
  test('same-source stable URL and unique unchanged ordinals migrate while preserving cache/read/progress/bookmarks', () async {
    final repo = await _repository(_book());
    final old = (await repo.find('legacy'))!;
    final bytes = (await repo.readChapter(old.id, 0))!.toJson();
    final count = await repo.updateChapterOrder(
      old,
      _incoming,
      expectedRevision: repo.replacementRevision,
    );
    expect(count, 1);
    final current = (await repo.find(old.id))!;
    expect(current.chapters.map((c) => c.id), ['/c1', '/c2', '/c3']);
    expect(current.chapters.map((c) => c.read), [true, false, false]);
    expect(current.chapters.first.downloaded, true);
    expect(current.currentChapter, 1);
    expect(current.progress, .5);
    expect(current.bookmarks, ['0:0.5000', '1:0.2500']);
    expect((await repo.readChapter(old.id, 0))!.toJson(), bytes);
  });

  test('unverified numeric manga references, reordered or ambiguous chapters keep original bytes untouched', () async {
    for (final (book, incoming) in [
      (_book(ref: '42'), _incoming),
      (
        _book(),
        [_incoming[1].copyWith(index: 0), _incoming[0].copyWith(index: 1)],
      ),
      (_book(), [_incoming[0], _incoming[1].copyWith(title: 'Chương 1')]),
      (_book(), [_incoming[0], _incoming[1].copyWith(number: 9)]),
      (_book(), [_incoming[0].copyWith(number: 2), _incoming[1]]),
      (_book(), [_incoming[0]]),
    ]) {
      final repo = await _repository(book);
      final before = await repo.snapshot();
      await expectLater(
        repo.updateChapterOrder(
          (await repo.find(book.id))!,
          incoming,
          expectedRevision: repo.replacementRevision,
        ),
        throwsStateError,
      );
      expect((await repo.snapshot()).fingerprint, before.fingerprint);
    }
  });

  test(
    'source change and restored revision reject a verified mapping atomically',
    () async {
      final repo = await _repository(_book());
      final old = (await repo.find('legacy'))!;
      final revision = repo.replacementRevision;
      await repo.mutateBook(
        old.id,
        (book) => book.copyWith(sourceRef: '/other'),
      );
      final changed = await repo.snapshot();
      await expectLater(
        repo.updateChapterOrder(old, _incoming, expectedRevision: revision),
        throwsStateError,
      );
      expect((await repo.snapshot()).fingerprint, changed.fingerprint);
      await repo.replaceSnapshot(
        changed,
        expectedFingerprint: changed.fingerprint,
      );
      final restored = await repo.snapshot();
      await expectLater(
        repo.updateChapterOrder(
          (await repo.find(old.id))!,
          _incoming,
          expectedRevision: revision,
        ),
        throwsStateError,
      );
      expect((await repo.snapshot()).fingerprint, restored.fingerprint);
    },
  );

  final native = Platform.environment['TACHI_ISAR_TEST_LIBRARY'];
  test(
    'Isar numeric remap persists stable IDs and matching offline bytes after reopen',
    () async {
      await Isar.initializeIsarCore(
        libraries: {Abi.current(): native!},
        download: false,
      );
      final directory = await Directory.systemTemp.createTemp(
        'tachi-legacy-remap-',
      );
      LibraryRepository? repo;
      try {
        repo = await LibraryRepository.open(directoryPath: directory.path);
        await repo.save(_book());
        await repo.saveChapter(
          'legacy',
          0,
          ReaderContent(kind: 'manga', images: ['data:image/png;base64,AQID']),
        );
        final old = (await repo.find('legacy'))!;
        final before = await repo.snapshot();
        await expectLater(
          repo.updateChapterOrder(old, [
            _incoming[0],
            _incoming[1].copyWith(title: 'Wrong'),
          ], expectedRevision: repo.replacementRevision),
          throwsStateError,
        );
        expect((await repo.snapshot()).fingerprint, before.fingerprint);
        expect(
          await repo.updateChapterOrder(
            old,
            _incoming,
            expectedRevision: repo.replacementRevision,
          ),
          1,
        );
        await repo.close();
        repo = await LibraryRepository.open(directoryPath: directory.path);
        final saved = (await repo.find('legacy'))!;
        expect(saved.chapters.map((c) => c.id), ['/c1', '/c2', '/c3']);
        expect(saved.currentChapter, 1);
        expect(saved.progress, .5);
        expect(saved.bookmarks, ['0:0.5000', '1:0.2500']);
        expect(saved.chapters.first.read, true);
        expect((await repo.readChapter('legacy', 0))!.images, [
          'data:image/png;base64,AQID',
        ]);
        expect(await repo.readChapter('legacy', 1), isNull);
      } finally {
        await repo?.close();
        await directory.delete(recursive: true);
      }
    },
    skip: native == null
        ? 'Set TACHI_ISAR_TEST_LIBRARY for native persistence.'
        : false,
  );
}
