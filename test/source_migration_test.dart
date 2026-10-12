import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:tachi_books/features/library/data/library_repository.dart';
import 'package:tachi_books/features/library/domain/library_book.dart';
import 'package:tachi_books/features/library/domain/external_backup_metadata.dart';
import 'package:tachi_books/features/sources/domain/catalogue.dart';
import 'package:tachi_books/features/sources/domain/source_migration.dart';

void main() {
  test('matching is one-to-one and refuses duplicate numbers or contradictory titles', () {
    BookChapter c(String id, int i, String title, [double? n]) =>
        BookChapter(id: id, title: title, index: i, number: n);
    final result = matchMigrationChapters(
      [
        c('a', 0, 'One', 1),
        c('b', 1, 'Special'),
        c('c', 2, 'Duplicate A', 2),
        c('d', 3, 'Duplicate B', 2),
        c('e', 4, 'Same title', 5),
        c('f', 5, 'Again'),
        c('g', 6, 'Again'),
      ],
      [
        c('n1', 0, 'First', 1),
        c('n2', 1, '  SPECIAL  '),
        c('n3', 2, 'Duplicate A', 2),
        c('n4', 3, 'Same title', 6),
        c('n5', 4, 'Again'),
      ],
    );
    expect(result, {0: 0, 1: 1});
  });

  test('preview preserves flags/categories/preferences and keeps original offline data by default', () async {
    final repo = await library();
    final before = await repo.snapshot();
    final service = SourceMigration(repo);
    final preview = await service.preview('old', target, chapters);
    expect((await repo.snapshot()).fingerprint, before.fingerprint);
    expect(preview.matches, {0: 1, 1: 0});
    expect(preview.unmatchedBookmarks, 1);
    expect(preview.oldOfflineChapters, 1);
    expect(preview.replacement.chapters.map((c) => c.read), [
      false,
      true,
      false,
    ]);
    expect(preview.replacement.bookmarks, ['1:0.0000']);
    expect(preview.replacement.currentChapter, 0);
    expect(preview.replacement.progress, 0);
    expect(preview.replacement.notes, 'note');
    expect(
      preview.replacement.externalBackupMetadata?.toJson(),
      preview.original.externalBackupMetadata?.toJson(),
    );
    expect(preview.replacement.categories, ['Series', 'Writer']);
    expect(preview.replacement.readerPreferences, {'zoom': true});
    expect(preview.replacement.chapterListPreferences, {'sort': 'number'});
    final saved = await service.commit(preview);
    expect((await repo.list()).length, 3);
    expect(
      (await repo.find('old'))!.toJson(),
      before.entries.firstWhere((e) => e.book.id == 'old').book.toJson(),
    );
    expect(
      (await repo.readChapter('old', 0))!.images.single,
      'data:image/png;base64,AQ==',
    );
    expect(await repo.readChapter(saved.id, 1), isNull);
    expect(saved.chapters.every((c) => !c.downloaded), isTrue);
    final recovery = jsonDecode(utf8.decode((await repo.recoverySnapshot())!));
    expect(recovery['entries'].length, 2);
  });

  test(
    'replace removes old title only after recovery and keeps unrelated book',
    () async {
      final repo = await library();
      final service = SourceMigration(repo);
      final preview = await service.preview('old', target, chapters);
      final saved = await service.commit(preview, replaceOld: true);
      expect(await repo.find('old'), isNull);
      expect(await repo.readChapter('old', 0), isNull);
      expect((await repo.find('unrelated'))!.notes, 'untouched');
      expect((await repo.list()).map((b) => b.id), contains(saved.id));
      expect(await repo.recoverySnapshot(), isNotNull);
    },
  );

  test('edits and downloads after preview reject entire replacement', () async {
    for (final editCache in [false, true]) {
      final repo = await library();
      final service = SourceMigration(repo);
      final preview = await service.preview('old', target, chapters);
      if (editCache) {
        await repo.saveChapter(
          'old',
          0,
          ReaderContent(kind: 'manga', images: ['data:image/png;base64,Ag==']),
        );
      } else {
        await repo.mutateBook(
          'unrelated',
          (book) => book.copyWith(notes: 'new edit'),
        );
      }
      final current = await repo.snapshot();
      await expectLater(
        service.commit(preview, replaceOld: true),
        throwsStateError,
      );
      expect((await repo.snapshot()).fingerprint, current.fingerprint);
      expect(await repo.find('old'), isNotNull);
    }
  });

  test('malformed chapters and existing target never modify library', () async {
    final repo = await library();
    final service = SourceMigration(repo);
    final before = await repo.snapshot();
    await expectLater(
      service.preview('old', target, [chapters.first, chapters.first]),
      throwsFormatException,
    );
    expect((await repo.snapshot()).fingerprint, before.fingerprint);
    final preview = await service.preview('old', target, chapters);
    await service.commit(preview);
    await expectLater(
      service.preview('old', target, chapters),
      throwsStateError,
    );
  });

  test('bulk commit is atomic, rejects mixed previews and duplicate target selections', () async {
    final repo = await library();
    final original = (await repo.find('old'))!;
    await repo.save(
      original.copyWith(
        id: 'old-2',
        sourceRef: '/old-2',
        chapters: [
          for (final c in original.chapters) c.copyWith(downloaded: false),
        ],
      ),
    );
    final service = SourceMigration(repo);
    final first = await service.preview('old', target, chapters);
    final duplicate = await service.preview('old-2', target, chapters);
    final before = await repo.snapshot();
    await expectLater(
      service.commitBatch([first, duplicate]),
      throwsStateError,
    );
    expect((await repo.snapshot()).fingerprint, before.fingerprint);
    const secondTarget = CatalogueBook(
      ref: '/second',
      title: 'Second',
      sourceId: 'new-source',
      kind: ContentKind.manga,
      engine: SourceEngine.tachimanga,
    );
    final second = await service.preview('old-2', secondTarget, chapters);
    final completed = await service.commitBatch([
      first,
      second,
    ], replaceOld: true);
    expect(completed.length, 2);
    expect(await repo.find('old'), isNull);
    expect(await repo.find('old-2'), isNull);
    expect(await repo.find('unrelated'), isNotNull);
    expect(
      jsonDecode(
        utf8.decode((await repo.recoverySnapshot())!),
      )['entries'].length,
      3,
    );
  });

  test(
    'bulk refuses a newly edited library and mismatched preview snapshots',
    () async {
      final repo = await library();
      final service = SourceMigration(repo);
      final first = await service.preview('old', target, chapters);
      await repo.mutateBook('unrelated', (b) => b.copyWith(notes: 'edit'));
      final second = await service.preview('old', target, chapters);
      final before = await repo.snapshot();
      await expectLater(service.commitBatch([first]), throwsStateError);
      await expectLater(service.commitBatch([first, second]), throwsStateError);
      expect((await repo.snapshot()).fingerprint, before.fingerprint);
    },
  );
}

const target = CatalogueBook(
  ref: '/new',
  title: 'New title',
  sourceId: 'new-source',
  kind: ContentKind.manga,
  engine: SourceEngine.tachimanga,
);
const chapters = [
  CatalogueChapter(ref: 'b-new', title: 'Two', index: 0, number: 2),
  CatalogueChapter(ref: 'a-new', title: 'One', index: 1, number: 1),
  CatalogueChapter(ref: 'c-new', title: 'Unmatched', index: 2, number: 4),
];
Future<MemoryLibraryRepository> library() async {
  final repo = MemoryLibraryRepository();
  await repo.save(
    LibraryBook(
      id: 'old',
      title: 'Old title',
      kind: 'manga',
      engine: 'tachimanga',
      sourceId: 'old-source',
      sourceRef: '/old',
      notes: 'note',
      externalBackupMetadata: ExternalBackupMetadata(
        format: 'mihon-protobuf-v0.20.4',
        engine: 'tachimanga',
        sourceId: '123',
        sourceRef: '/old',
        memo: base64Encode(utf8.encode('{"source":"old"}')),
      ),
      categories: ['Series', 'Writer'],
      readerPreferences: {'zoom': true},
      chapterListPreferences: {'sort': 'number'},
      currentChapter: 1,
      progress: .5,
      lastRead: DateTime(2026, 10, 10),
      bookmarks: ['0:0.25', '2:0.75'],
      chapters: const [
        BookChapter(
          id: 'a',
          title: 'Chapter one',
          index: 0,
          number: 1,
          downloaded: true,
          read: true,
        ),
        BookChapter(
          id: 'b',
          title: 'Chapter two',
          index: 1,
          number: 2,
          read: false,
        ),
        BookChapter(id: 'c', title: 'Bonus', index: 2, read: false),
      ],
    ),
  );
  await repo.saveChapter(
    'old',
    0,
    ReaderContent(kind: 'manga', images: ['data:image/png;base64,AQ==']),
  );
  await repo.save(
    LibraryBook(id: 'unrelated', title: 'Other', notes: 'untouched'),
  );
  return repo;
}
