import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:isar_community/isar.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tachi_books/features/library/data/library_repository.dart';
import 'package:tachi_books/features/library/domain/library_book.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final isarLibrary = Platform.environment['TACHI_ISAR_TEST_LIBRARY'];

  for (final storage in ['memory', 'preferences', 'native']) {
    test(
      '$storage batch metadata validates all titles before commit and preserves latest progress and contents',
      () async {
        Directory? directory;
        LibraryRepository? repository;
        try {
          if (storage == 'native') {
            await Isar.initializeIsarCore(
              libraries: {Abi.current(): isarLibrary!},
              download: false,
            );
            directory = await Directory.systemTemp.createTemp(
              'tachi-metadata-batch-',
            );
            repository = await LibraryRepository.open(
              directoryPath: directory.path,
            );
          } else if (storage == 'preferences') {
            SharedPreferences.setMockInitialValues({});
            repository = await LibraryRepository.openWebPreview();
          } else {
            repository = MemoryLibraryRepository();
          }
          final repo = repository;
          for (final id in ['a', 'b']) {
            await repo.save(
              LibraryBook(
                id: id,
                title: 'Book $id',
                categories: ['Before', 'Keep'],
                chapters: const [
                  BookChapter(
                    id: 'chapter',
                    title: 'Chapter',
                    index: 0,
                    downloaded: true,
                    read: true,
                  ),
                ],
              ),
            );
            await repo.saveChapter(
              id,
              0,
              ReaderContent(kind: 'novel', html: '<p>Offline $id</p>'),
            );
          }
          final before = (await repo.snapshot()).fingerprint;
          final revision = repo.replacementRevision;
          await expectLater(
            repo.mutateBooks(
              ['a', 'b'],
              (book) => book.id == 'b'
                  ? book.copyWith(title: '')
                  : book.copyWith(categories: ['After']),
              expectedRevision: revision,
            ),
            throwsFormatException,
          );
          expect((await repo.snapshot()).fingerprint, before);
          expect(repo.replacementRevision, revision);
          await expectLater(
            repo.mutateBooks(
              ['a', 'b'],
              (book) => book.copyWith(id: 'changed-id'),
              expectedRevision: revision,
            ),
            throwsStateError,
          );
          expect((await repo.snapshot()).fingerprint, before);
          final progress = repo.mutateBook(
            'a',
            (book) => book.copyWith(progress: .8, bookmarks: ['0:0.4']),
          );
          final batch = repo.mutateBooks(
            ['a', 'b', 'a', 'missing'],
            (book) => book.copyWith(
              categories: [
                'After',
                ...book.categories.where((name) => name != 'Before'),
              ],
            ),
            expectedRevision: revision,
          );
          await progress;
          expect(await batch, 2);
          final saved = (await repo.find('a'))!;
          expect(saved.categories, ['After', 'Keep']);
          expect(saved.progress, .8);
          expect(saved.bookmarks, ['0:0.4']);
          expect(saved.chapters.single.read, isTrue);
          expect(saved.chapters.single.downloaded, isTrue);
          expect((await repo.readChapter('a', 0))!.html, '<p>Offline a</p>');
          expect((await repo.readChapter('b', 0))!.html, '<p>Offline b</p>');
          if (storage == 'preferences') {
            final reopened = await LibraryRepository.openWebPreview();
            expect((await reopened.find('a'))!.toJson(), saved.toJson());
          }
          await repo.clear();
          final restored = LibraryBook(
            id: 'a',
            title: 'Replacement',
            categories: ['Restored'],
          );
          await repo.save(restored);
          await expectLater(
            repo.mutateBooks(
              ['a', 'b'],
              (book) => book.copyWith(categories: ['Stale']),
              expectedRevision: revision,
            ),
            throwsStateError,
          );
          expect((await repo.find('a'))!.toJson(), restored.toJson());
          expect(await repo.find('b'), isNull);
        } finally {
          await repository?.close();
          await directory?.delete(recursive: true);
        }
      },
      skip: storage == 'native' && isarLibrary == null
          ? 'Set TACHI_ISAR_TEST_LIBRARY to official Isar core.'
          : false,
    );
  }
}
