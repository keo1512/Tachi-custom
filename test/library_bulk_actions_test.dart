import 'package:flutter_test/flutter_test.dart';
import 'package:tachi_books/features/library/application/library_bulk_actions.dart';
import 'package:tachi_books/features/library/data/library_repository.dart';
import 'package:tachi_books/features/library/domain/library_book.dart';
import 'package:tachi_books/features/library/domain/library_duplicates.dart';

LibraryBook book(String id) => LibraryBook(
  id: id,
  title: id,
  notes: 'giữ',
  categories: const ['A', 'B'],
  bookmarks: const ['chapter'],
  chapters: const [
    BookChapter(id: 'chapter', title: 'Chương 1', index: 0, downloaded: true),
  ],
);

void main() {
  test('bulk read uses current metadata and preserves cache, bookmarks, categories and history', () async {
    final repo = MemoryLibraryRepository(),
        service = LibraryBulkActions(MemoryLibraryRepository());
    final actions = LibraryBulkActions(repo);
    await repo.save(book('a').copyWith(lastRead: DateTime(2026)));
    await repo.save(book('b'));
    final content = ReaderContent(kind: 'novel', html: 'nội dung');
    await repo.saveChapter('a', 0, content);
    await repo.mutateBook('a', (b) => b.copyWith(notes: 'ghi chú mới'));
    expect(await actions.markRead(['a', 'a', 'missing'], true, revision: 0), 1);
    final read = (await repo.find('a'))!;
    expect(read.completed, true);
    expect(read.chapters.single.read, true);
    expect(read.notes, 'ghi chú mới');
    expect(read.categories, ['A', 'B']);
    expect(read.bookmarks, ['chapter']);
    expect(await repo.readChapter('a', 0), content);
    expect((await repo.find('b'))!.chapters.single.read, null);
    await actions.markRead(['a'], false, revision: 0);
    expect((await repo.find('a'))!.lastRead, DateTime(2026));
    expect((await repo.find('a'))!.progress, 0);
    expect(await service.favorite([], true, revision: 0), 0);
  });

  test('removal is atomic with full recovery and rejects stale metadata or chapter changes', () async {
    final repo = MemoryLibraryRepository();
    final actions = LibraryBulkActions(repo);
    await repo.save(book('a'));
    await repo.save(book('b'));
    await repo.saveChapter('a', 0, ReaderContent(kind: 'novel', html: 'a'));
    await repo.saveChapter('b', 0, ReaderContent(kind: 'novel', html: 'b'));
    final stale = await actions.previewRemoval(['a', 'b'], revision: 0);
    await repo.mutateBook(
      'b',
      (b) => b.copyWith(notes: 'sửa khi đang xác nhận'),
    );
    await expectLater(actions.remove(stale), throwsStateError);
    expect((await repo.list()).length, 2);
    final staleChapter = await actions.previewRemoval(['a'], revision: 0);
    await repo.saveChapter('a', 0, ReaderContent(kind: 'novel', html: 'mới'));
    await expectLater(actions.remove(staleChapter), throwsStateError);
    final previousRead = (await repo.openChapter('a', 'chapter'))!;
    final preview = await actions.previewRemoval([
      'a',
      'a',
      'missing',
    ], revision: 0);
    expect(preview.cachedChapters, 1);
    expect(await actions.remove(preview), 1);
    expect(await repo.find('a'), null);
    expect((await repo.readChapter('b', 0))!.html, 'b');
    expect(await repo.recoverySnapshot(), isNotNull);
    await expectLater(
      repo.commitChapter(
        previousRead,
        ReaderContent(kind: 'novel', html: 'cũ'),
        downloaded: true,
      ),
      throwsStateError,
    );
    await expectLater(
      actions.favorite(['b'], true, revision: 0),
      throwsStateError,
    );
  });

  test('duplicate suggestions normalize whitespace and case without merging editions', () {
    final a = book('a').copyWith(title: ' Truyện   mới '),
        b = book('b').copyWith(title: 'truyện mới');
    expect(libraryDuplicates([a, b, book('c')]).single.map((b) => b.id), [
      'a',
      'b',
    ]);
    expect(a.notes, 'giữ');
  });
}
