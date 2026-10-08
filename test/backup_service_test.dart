import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tachi_books/features/library/data/backup_service.dart';
import 'package:tachi_books/features/library/data/library_repository.dart';
import 'package:tachi_books/features/library/domain/library_book.dart';

const image = 'data:image/png;base64,AQID';

LibraryBook sampleBook({
  String id = 'sample',
  String kind = 'novel',
  int chapters = 2,
}) => LibraryBook(
  id: id,
  title: 'Sách tiếng Việt',
  author: 'Tác giả',
  kind: kind,
  cover: image,
  favorite: true,
  collection: 'Đang đọc',
  chapters: List.generate(
    chapters,
    (index) => BookChapter(
      id: '$id-$index',
      title: 'Chương ${index + 1}',
      index: index,
      downloaded: true,
    ),
  ),
  currentChapter: 1,
  progress: .7,
  lastRead: DateTime.utc(2026, 10, 8),
  bookmarks: ['1:0.4'],
);

Future<void> seed(MemoryLibraryRepository repository, LibraryBook book) async {
  for (final chapter in book.chapters) {
    await repository.saveChapter(
      book.id,
      chapter.index,
      ReaderContent(
        kind: book.kind,
        html: book.kind == 'novel'
            ? '<p>Nội dung ${chapter.index} <img src="$image"/></p>'
            : '',
        images: book.kind == 'manga' ? [image] : [],
        headers: {'Referer': 'https://example.org/'},
      ),
    );
  }
  await repository.save(book);
}

Map<String, dynamic> decode(Uint8List bytes) =>
    jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
Uint8List encode(Map<String, dynamic> backup) =>
    Uint8List.fromList(utf8.encode(jsonEncode(backup)));

class RecordingRepository extends MemoryLibraryRepository {
  int writes = 0;
  @override
  Future<void> save(LibraryBook book) async {
    writes++;
    await super.save(book);
  }

  @override
  Future<void> saveChapter(
    String bookId,
    int index,
    ReaderContent content,
  ) async {
    writes++;
    await super.saveChapter(bookId, index, content);
  }

  @override
  Future<void> remove(String id) async {
    writes++;
    await super.remove(id);
  }
}

class FailingRepository extends RecordingRepository {
  @override
  Future<void> save(LibraryBook book) async {
    if (book.id == 'second') throw StateError('Storage full');
    await super.save(book);
  }
}

void main() {
  test(
    'Roundtrip preserves book state and self-contained manga / novel content',
    () async {
      final source = MemoryLibraryRepository();
      await seed(source, sampleBook());
      await seed(source, sampleBook(id: 'manga', kind: 'manga', chapters: 12));
      final bytes = await BackupService(source).export();
      final restored = MemoryLibraryRepository();
      expect(await BackupService(restored).merge(bytes), 2);
      for (final original in await source.list()) {
        expect((await restored.find(original.id))!.toJson(), original.toJson());
        for (var index = 0; index < original.chapters.length; index++) {
          expect(
            (await restored.readChapter(original.id, index))!.toJson(),
            (await source.readChapter(original.id, index))!.toJson(),
          );
        }
      }
      expect((await restored.readChapter('manga', 10))!.images.single, image);
      expect((await restored.readChapter('sample', 0))!.html, contains(image));
    },
  );

  test(
    'Existing book and chapter bytes keep the current progress during merge',
    () async {
      final source = MemoryLibraryRepository();
      await seed(source, sampleBook());
      await seed(source, sampleBook(id: 'new'));
      final destination = MemoryLibraryRepository();
      final existing = sampleBook().copyWith(
        title: 'Tên hiện tại',
        progress: .21,
        collection: 'Cá nhân',
        bookmarks: ['0:0.42'],
      );
      await destination.save(existing);
      final content = ReaderContent(
        kind: 'novel',
        html: '<p>Current local bytes</p>',
      );
      await destination.saveChapter(existing.id, 0, content);
      expect(
        await BackupService(destination)
            .merge(await BackupService(source).export()),
        1,
      );
      expect(
        (await destination.find(existing.id))!.toJson(),
        existing.toJson(),
      );
      expect(
        (await destination.readChapter(existing.id, 0))!.toJson(),
        content.toJson(),
      );
      expect(await destination.readChapter(existing.id, 1), isNull);
      expect(await destination.find('new'), isNotNull);
    },
  );

  test(
    'An invalid later book causes zero writes, including earlier valid books',
    () async {
      final source = MemoryLibraryRepository();
      await seed(source, sampleBook(id: 'first'));
      await seed(source, sampleBook(id: 'second'));
      final backup = decode(await BackupService(source).export());
      (backup['entries'][1]['book'] as Map)['progress'] = 1.01;
      final destination = RecordingRepository();
      await expectLater(
        BackupService(destination).merge(encode(backup)),
        throwsA(isA<FormatException>()),
      );
      expect(destination.writes, 0);
      expect(await destination.list(), isEmpty);
    },
  );

  test('Reject versions, duplicate IDs, chapter order, progress and absent downloaded bytes before writing', () async {
    final source = MemoryLibraryRepository();
    await seed(source, sampleBook());
    final valid = await BackupService(source).export();
    final corruptions = <void Function(Map<String, dynamic>)>[
      (root) => root['version'] = 2,
      (root) => root['version'] = '1',
      (root) => root['version'] = 1.0,
      (root) => root['entries'].add(root['entries'][0]),
      (root) => root['entries'][0]['book']['progress'] = -.1,
      (root) => root['entries'][0]['book']['progress'] = 2,
      (root) => root['entries'][0]['book']['currentChapter'] = 2,
      (root) => root['entries'][0]['book']['chapters'][1]['index'] = 0,
      (root) => root['entries'][0]['book']['chapters'][1]['id'] =
          root['entries'][0]['book']['chapters'][0]['id'],
      (root) => root['entries'][0]['contents'].remove('1'),
      (root) => root['entries'][0]['contents']['-1'] =
          root['entries'][0]['contents'].remove('1'),
      (root) => root['entries'][0]['contents']['01'] =
          root['entries'][0]['contents'].remove('1'),
      (root) => root['entries'][0]['contents']['1']['kind'] = 'manga',
      (root) => root['entries'][0]['contents']['1']['headers'] = {'key': 12},
      (root) => root['entries'][0]['book']['cover'] = 'tachi-asset://missing',
      (root) => root['entries'][0]['book']['cover'] = 'data:image/png;base64,',
      (root) => root['entries'][0]['contents']['1']['html'] =
          '<img src="tachi-asset://missing"/>',
    ];
    for (final corrupt in corruptions) {
      final root = decode(valid);
      corrupt(root);
      final destination = RecordingRepository();
      await expectLater(
        BackupService(destination).merge(encode(root)),
        throwsA(isA<FormatException>()),
      );
      expect(destination.writes, 0);
    }
  });

  test('Malformed JSON and invalid root never write', () async {
    for (final bytes in [
      Uint8List(0),
      Uint8List.fromList([0xff]),
      Uint8List.fromList(utf8.encode('{')),
      Uint8List.fromList(utf8.encode('[]')),
    ]) {
      final repository = RecordingRepository();
      await expectLater(
        BackupService(repository).merge(bytes),
        throwsA(isA<FormatException>()),
      );
      expect(repository.writes, 0);
    }
  });

  test('A write failure rolls back new books and orphan content while keeping prior books', () async {
    final source = MemoryLibraryRepository();
    await seed(source, sampleBook(id: 'first'));
    await seed(source, sampleBook(id: 'second'));
    final destination = FailingRepository();
    final existing = sampleBook(id: 'existing');
    await seed(destination, existing);
    await expectLater(
      BackupService(destination).merge(await BackupService(source).export()),
      throwsStateError,
    );
    expect((await destination.list()).map((book) => book.id), ['existing']);
    expect((await destination.find('existing'))!.toJson(), existing.toJson());
    expect(await destination.readChapter('first', 0), isNull);
    expect(await destination.readChapter('second', 0), isNull);
    expect(await destination.readChapter('existing', 0), isNotNull);
  });

  test('Export rejects incomplete downloaded content rather than emitting unrestorable backup', () async {
    final repository = MemoryLibraryRepository();
    await repository.save(sampleBook());
    await expectLater(
      BackupService(repository).export(),
      throwsA(isA<FormatException>()),
    );
  });
}
