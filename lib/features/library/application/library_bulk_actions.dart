import '../data/library_mutation.dart';
import '../data/library_repository.dart';
import '../data/library_snapshot.dart';
import '../domain/library_book.dart';

/// Metadata edits use the latest records in one transaction. Removal uses a
/// hydrated preview and the repository's recovery/CAS contract.
class LibraryBulkActions {
  const LibraryBulkActions(this.repository);
  final LibraryRepository repository;

  Future<int> markRead(
    Iterable<String> ids,
    bool read, {
    required int revision,
  }) => repository.mutateBooks(
    ids,
    (book) => book.copyWith(
      chapters: [
        for (final chapter in book.chapters) chapter.copyWith(read: read),
      ],
      completed: read && book.chapters.isNotEmpty,
      readingState: !read && book.readingState == 'completed' ? '' : null,
      currentChapter: read && book.chapters.isNotEmpty
          ? book.chapters.length - 1
          : 0,
      progress: read && book.chapters.isNotEmpty ? 1 : 0,
    ),
    expectedRevision: revision,
  );

  Future<int> favorite(
    Iterable<String> ids,
    bool value, {
    required int revision,
  }) => repository.mutateBooks(
    ids,
    (book) => book.copyWith(favorite: value),
    expectedRevision: revision,
  );

  Future<LibraryRemovalPreview> previewRemoval(
    Iterable<String> ids, {
    required int revision,
  }) async {
    checkLibraryRevision(repository.replacementRevision, revision);
    final snapshot = await repository.snapshot();
    checkLibraryRevision(repository.replacementRevision, revision);
    final selected = ids.toSet();
    return LibraryRemovalPreview(snapshot, selected, revision);
  }

  Future<int> remove(LibraryRemovalPreview preview) async {
    checkLibraryRevision(repository.replacementRevision, preview.revision);
    if (preview.books.isEmpty) return 0;
    await repository.replaceSnapshot(
      LibrarySnapshot(
        preview.snapshot.entries.where(
          (entry) => !preview.ids.contains(entry.book.id),
        ),
      ),
      expectedFingerprint: preview.snapshot.fingerprint,
    );
    return preview.books.length;
  }
}

class LibraryRemovalPreview {
  LibraryRemovalPreview(this.snapshot, Set<String> selected, this.revision)
    : ids = Set.unmodifiable(selected),
      books = List.unmodifiable(
        snapshot.entries
            .where((entry) => selected.contains(entry.book.id))
            .map((entry) => entry.book),
      );
  final LibrarySnapshot snapshot;
  final Set<String> ids;
  final List<LibraryBook> books;
  final int revision;
  int get cachedChapters => snapshot.entries
      .where((entry) => ids.contains(entry.book.id))
      .fold(0, (total, entry) => total + entry.contents.length);
}
