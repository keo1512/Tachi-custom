import '../domain/library_book.dart';

/// Library IDs are opaque data. Keep separators and query characters inside one
/// encoded path segment; URI dot normalization needs the existing query fallback.
String libraryBookLocation(String id) => _location('book', id);

/// Keep the legacy numeric position and add the stable chapter identity so a TOC
/// reorder between tapping a row and loading the reader cannot open another row.
String libraryReaderLocation(LibraryBook book, int chapter) => _location(
  'read',
  book.id,
  query: {
    'chapter': '$chapter',
    if (chapter >= 0 &&
        chapter < book.chapters.length &&
        book.chapters[chapter].id.isNotEmpty)
      'chapterId': book.chapters[chapter].id,
  },
);

String _location(
  String route,
  String id, {
  Map<String, String> query = const {},
}) {
  final dotId = id == '.' || id == '..';
  final parameters = {if (dotId) 'bookId': id, ...query};
  return Uri(
    pathSegments: ['', route, dotId ? 'link' : id],
    queryParameters: parameters.isEmpty ? null : parameters,
  ).toString();
}
