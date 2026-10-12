import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tachi_books/features/library/data/backup_service.dart';
import 'package:tachi_books/features/library/data/document_importer.dart';
import 'package:tachi_books/features/library/data/library_repository.dart';

Uint8List zip(Map<String, List<int>> files) {
  final archive = Archive();
  for (final entry in files.entries) {
    archive.add(ArchiveFile.bytes(entry.key, entry.value));
  }
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

void main() {
  test('local metadata, cover and chapter folders travel offline to a fresh library', () async {
    final repo = MemoryLibraryRepository();
    final bytes = zip({
      'details.json': utf8.encode(
        jsonEncode({
          'title': 'Tên thật',
          'author': 'Tác giả',
          'artist': 'Họa sĩ',
          'genre': ['Hài', 'Đời thường'],
          'status': 2,
          'description': 'Giới thiệu',
          'series': 'Bộ A',
        }),
      ),
      'cover.jpg': [9],
      'Chương 10/page1.png': [10],
      'Chương 2/page10.png': [4],
      'Chương 2/page2.png': [2],
    });
    final book = await DocumentImporter().import('folder.cbz', bytes, repo);
    expect(book.title, 'Tên thật');
    expect(book.author, 'Tác giả');
    expect(book.artist, 'Họa sĩ');
    expect(book.status, 2);
    expect(book.genres, ['Hài', 'Đời thường']);
    expect(book.series, 'Bộ A');
    expect(book.chapters.map((c) => c.title), ['Chương 2', 'Chương 10']);
    expect(UriData.parse(book.cover).contentAsBytes(), [9]);
    final destination = MemoryLibraryRepository();
    await BackupService(destination).merge(await BackupService(repo).export());
    expect((await destination.find(book.id))!.toJson(), book.toJson());
    expect(
      (await destination.readChapter(
        book.id,
        0,
      ))!.images.map((s) => UriData.parse(s).contentAsBytes().single),
      [2, 4],
    );
    expect(
      UriData.parse((await destination.readChapter(book.id, 1))!.images.single)
          .contentAsBytes(),
      [10],
    );
    // The original input is never rewritten, and reimport retains all state.
    await repo.save(
      book.copyWith(progress: .2, notes: 'Ghi chú', bookmarks: ['0:0.4']),
    );
    final reimport = await DocumentImporter().import(
      'renamed.zip',
      bytes,
      repo,
    );
    expect(reimport.notes, 'Ghi chú');
    expect(reimport.bookmarks, ['0:0.4']);
    expect(reimport.progress, .2);
  });

  test(
    'bad details.json rejects the entire title without partial insertion',
    () async {
      final repo = MemoryLibraryRepository();
      for (final metadata in [
        {'genre': 'Sai kiểu'},
        {'status': 8},
        {'author': 3},
      ]) {
        await expectLater(
          DocumentImporter().import(
            'bad.zip',
            zip({
              'page1.png': [1],
              'details.json': utf8.encode(jsonEncode(metadata)),
            }),
            repo,
          ),
          throwsFormatException,
        );
        expect(await repo.list(), isEmpty);
        expect((await repo.snapshot()).entries, isEmpty);
      }
    },
  );

  test(
    'image import retains original bytes and bounded conditional image formats',
    () async {
      for (final extension in [
        'jpg',
        'jpeg',
        'png',
        'webp',
        'gif',
        'avif',
        'heic',
        'heif',
        'jxl',
      ]) {
        final repo = MemoryLibraryRepository();
        final input = Uint8List.fromList([1, 2, 3]);
        final book = await DocumentImporter().import(
          'Trang.$extension',
          input,
          repo,
        );
        expect(book.kind, 'manga');
        expect(book.chapters.single.downloaded, true);
        expect(
          UriData.parse((await repo.readChapter(book.id, 0))!.images.single)
              .contentAsBytes(),
          input,
        );
      }
      await expectLater(
        DocumentImporter().import(
          'large.png',
          Uint8List(8 * 1024 * 1024 + 1),
          MemoryLibraryRepository(),
        ),
        throwsFormatException,
      );
    },
  );
}
