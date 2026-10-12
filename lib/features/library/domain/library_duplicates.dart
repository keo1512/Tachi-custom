import 'library_book.dart';

/// Suggestions only: translated titles and different editions can be identical.
/// No title is removed or merged automatically.
List<List<LibraryBook>> libraryDuplicates(Iterable<LibraryBook> books) {
  final groups = <String, List<LibraryBook>>{};
  for (final book in books) {
    final key = book.title.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
    if (key.isEmpty) continue;
    groups.putIfAbsent(key, () => []).add(book);
  }
  final duplicates = groups.values.where((group) => group.length > 1).toList()
    ..sort((a, b) => a.first.title.compareTo(b.first.title));
  return duplicates;
}
