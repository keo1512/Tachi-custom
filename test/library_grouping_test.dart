import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tachi_books/features/library/data/library_repository.dart';
import 'package:tachi_books/features/library/domain/library_book.dart';
import 'package:tachi_books/features/library/domain/library_grouping.dart';
import 'package:tachi_books/features/library/presentation/library_view_model.dart';

class PausedGroupingRepository extends MemoryLibraryRepository {
  final started = Completer<void>();
  final release = Completer<void>();
  bool pause = false;
  int saves = 0;

  @override
  Future<void> save(LibraryBook book) async {
    saves++;
    await super.save(book);
  }

  @override
  Future<LibraryBook?> mutateBook(
    String id,
    LibraryBook Function(LibraryBook) transform, {
    int? expectedRevision,
  }) async {
    if (await this.find(id) != null) saves++;
    if (pause) {
      pause = false;
      started.complete();
      await release.future;
    }
    return super.mutateBook(id, transform, expectedRevision: expectedRevision);
  }
}

void main() {
  test(
    'old JSON has empty series and additive metadata survives roundtrip',
    () {
      final old = LibraryBook(
        id: 'stable',
        title: 'Book',
        collection: 'My shelf',
      ).toJson()..remove('series');
      final restored = LibraryBook.fromJson(old);
      expect(restored.series, '');
      expect(restored.collection, 'My shelf');
      final updated = restored.copyWith(series: 'Explicit series');
      expect(LibraryBook.fromJson(updated.toJson()).toJson(), updated.toJson());
      expect(updated.id, 'stable');
    },
  );

  test('automatic groups deduplicate IDs and use only explicit author/series metadata', () {
    final books = [
      LibraryBook(
        id: '1',
        title: 'Volume 1',
        author: ' Nguyễn  Văn A ',
        series: ' Series A ',
        collection: 'Manual 1',
      ),
      LibraryBook(
        id: '2',
        title: 'Unrelated title',
        author: 'nguyễn văn a',
        series: 'series a',
        collection: 'Manual 2',
      ),
      LibraryBook(id: '3', title: 'Volume 2', collection: 'Manual 1'),
      LibraryBook(
        id: '4',
        title: 'Volume 3',
        author: 'Chưa có tác giả',
        series: 'Chưa có bộ truyện',
      ),
    ];
    final before = books.map((book) => book.toJson()).toList();
    final authors = libraryGroups([
      ...books,
      books.first,
    ], LibraryGrouping.author);
    final series = libraryGroups(books, LibraryGrouping.series);
    expect(
      authors.singleWhere((group) => group.key == 'value:nguyễn văn a').bookIds,
      {'1', '2'},
    );
    expect(authors.singleWhere((group) => group.key == 'missing').bookIds, {
      '3',
    });
    expect(
      authors
          .singleWhere((group) => group.key == 'value:chưa có tác giả')
          .bookIds,
      {'4'},
    );
    expect(
      series.singleWhere((group) => group.key == 'value:series a').bookIds,
      {'1', '2'},
    );
    expect(series.singleWhere((group) => group.key == 'missing').bookIds, {
      '3',
    });
    expect(books.map((book) => book.toJson()).toList(), before);
    expect(
      libraryGroups(
        books,
        LibraryGrouping.collection,
      ).singleWhere((group) => group.label == 'Manual 1').bookIds,
      {'1', '3'},
    );
  });

  test('bulk groups serialize latest progress/bookmarks/cache and skip removed or duplicate IDs', () async {
    final repo = PausedGroupingRepository();
    final original = LibraryBook(
      id: '1',
      title: 'Book',
      author: 'Old author',
      collection: 'Manual',
      chapters: const [
        BookChapter(id: 'c', title: 'C', index: 0, downloaded: true),
      ],
    );
    await repo.save(original);
    await repo.save(LibraryBook(id: '2', title: 'Second', collection: 'Keep'));
    await repo.saveChapter(
      '1',
      0,
      ReaderContent(kind: 'novel', html: '<p>offline</p>'),
    );
    final container = ProviderContainer(
      overrides: [libraryRepositoryProvider.overrideWithValue(repo)],
    );
    addTearDown(container.dispose);
    await container.read(libraryProvider.future);
    final vm = container.read(libraryProvider.notifier);
    repo.pause = true;
    final progress = vm.updateProgress('1', 'c', .7);
    await repo.started.future;
    final grouping = vm.groupBooks([
      '1',
      '2',
      '1',
      'missing',
    ], series: ' Same series ');
    final bookmark = vm.toggleBookmark('1', 'c', .4);
    repo.release.complete();
    await progress;
    expect(await grouping, 2);
    await bookmark;
    final saved = (await repo.find('1'))!;
    expect(saved.id, '1');
    expect(saved.collection, 'Manual');
    expect(saved.author, 'Old author');
    expect(saved.series, 'Same series');
    expect(saved.progress, .7);
    expect(saved.lastRead, isNotNull);
    expect(saved.bookmarks, ['0:0.4000']);
    expect(saved.chapters.single.downloaded, isTrue);
    expect((await repo.readChapter('1', 0))!.html, '<p>offline</p>');
    expect((await repo.find('2'))!.collection, 'Keep');
    expect(
      repo.saves,
      6,
    ); // Initial 2, progress, distinct 2 grouped books, bookmark.
    expect(await repo.find('missing'), isNull);
    expect(await vm.groupBooks(['1', '2'], collection: ' New shelf '), 2);
    expect((await repo.find('1'))!.series, 'Same series');
    expect((await repo.find('2'))!.collection, 'New shelf');
    expect(await vm.groupBooks(['1'], series: ''), 1);
    expect((await repo.find('1'))!.series, '');
    expect((await repo.find('1'))!.collection, 'New shelf');
  });

  test('invalid empty shelf is rejected before any write', () async {
    final repo = PausedGroupingRepository();
    await repo.save(LibraryBook(id: '1', title: 'Book', collection: 'Manual'));
    final container = ProviderContainer(
      overrides: [libraryRepositoryProvider.overrideWithValue(repo)],
    );
    addTearDown(container.dispose);
    await container.read(libraryProvider.future);
    await expectLater(
      container.read(libraryProvider.notifier).groupBooks([
        '1',
      ], collection: ' '),
      throwsFormatException,
    );
    expect(repo.saves, 1);
    expect((await repo.find('1'))!.collection, 'Manual');
  });
}
