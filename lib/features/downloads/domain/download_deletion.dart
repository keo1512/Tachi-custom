import '../../library/domain/library_book.dart';
import '../../library/domain/library_reading.dart';

/// The stored bookmark prefix is the library TOC position, not source ordinal.
Set<int> _bookmarkIndices(LibraryBook book) {
  final result = <int>{};
  for (final bookmark in book.bookmarks) {
    final index = int.tryParse(bookmark.split(':').first);
    if (!bookmark.contains(':') ||
        index == null ||
        index < 0 ||
        index >= book.chapters.length) {
      throw StateError(
        'Dấu trang không hợp lệ. Chưa thể xóa chương có bảo vệ dấu trang.',
      );
    }
    result.add(index);
  }
  return result;
}

List<int> downloadDeletionIndices(
  LibraryBook book,
  Set<String> requested, {
  required bool protectBookmarks,
  required bool readOnly,
}) {
  if (book.engine == 'local') {
    throw StateError('Không xóa nội dung gốc của sách đã nhập.');
  }
  if (requested.any((id) => id.isEmpty) || requested.length > 10000) {
    throw const FormatException('Danh sách chương không hợp lệ.');
  }
  final chapters = book.chapters.map((chapter) => chapter.id).toList();
  if (chapters.toSet().length != chapters.length ||
      !chapters.toSet().containsAll(requested)) {
    throw StateError('Chương đã chọn không còn hoặc trùng mã trong mục lục.');
  }
  final protected = protectBookmarks ? _bookmarkIndices(book) : <int>{};
  return [
    for (final entry in book.chapters.indexed)
      if (requested.contains(entry.$2.id) &&
          !protected.contains(entry.$1) &&
          (!readOnly || chapterIsRead(book, entry.$1)))
        entry.$1,
  ];
}
