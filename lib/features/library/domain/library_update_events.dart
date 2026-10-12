import 'library_book.dart';
import 'library_reading.dart';

class LibraryUpdateEntry {
  const LibraryUpdateEntry(this.book, this.chapter, this.index);
  final LibraryBook book;
  final BookChapter chapter;
  final int index;
}

List<String> updateCategoryBookIds(
  Iterable<LibraryBook> books,
  String? category,
) => [
  for (final book in books)
    if (book.engine != 'local' &&
        (category == null || book.categories.contains(category)))
      book.id,
];

List<LibraryUpdateEntry> libraryUpdateEntries(
  Iterable<LibraryBook> books, {
  String? category,
  bool unreadOnly = false,
  bool includeExistingUnread = false,
}) {
  final entries = <LibraryUpdateEntry>[];
  for (final book in books) {
    if (book.engine == 'local' ||
        (category != null && !book.categories.contains(category))) {
      continue;
    }
    for (final (index, chapter) in book.chapters.indexed) {
      final read = chapterIsRead(book, index);
      if ((unreadOnly || includeExistingUnread) && read) continue;
      if (chapter.discoveredAt == null && !includeExistingUnread) continue;
      entries.add(LibraryUpdateEntry(book, chapter, index));
    }
  }
  entries.sort((a, b) {
    final ad = a.chapter.discoveredAt, bd = b.chapter.discoveredAt;
    if (ad == null || bd == null) {
      if (ad != bd) return ad == null ? 1 : -1;
    } else {
      final compared = bd.compareTo(ad);
      if (compared != 0) return compared;
    }
    final book = a.book.id.compareTo(b.book.id);
    return book != 0 ? book : b.index.compareTo(a.index);
  });
  return entries;
}

String discoveredDateLabel(DateTime? time) {
  if (time == null) return 'Chưa có ngày phát hiện';
  final local = time.toLocal();
  return 'Phát hiện ${local.day}/${local.month}/${local.year} '
      '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
}
