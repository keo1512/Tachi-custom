import 'dart:convert';

import 'library_book.dart';
import 'library_grouping.dart';

/// Folder membership is independent of categories, author and series metadata.
class LibraryFolders {
  LibraryFolders([Map<String, String> names = const {}])
    : names = Map.unmodifiable(names);
  static const preferenceKey = 'libraryFoldersV1';
  final Map<String, String> names;

  factory LibraryFolders.decode(String? raw) {
    if (raw == null) return LibraryFolders();
    final data = jsonDecode(raw);
    if (data is! Map<String, dynamic> ||
        data.length > 10000 ||
        data.entries.any(
          (entry) =>
              entry.key.isEmpty ||
              entry.key.length > 4096 ||
              entry.value is! String ||
              (entry.value as String).trim().isEmpty ||
              entry.value != (entry.value as String).trim() ||
              (entry.value as String).length > 256,
        )) {
      throw const FormatException('Thư mục truyện không hợp lệ.');
    }
    return LibraryFolders(data.cast<String, String>());
  }

  String encode() => jsonEncode(names);

  List<LibraryGroup> groups(Iterable<LibraryBook> books, LibraryGrouping mode) {
    final values = books.toList();
    final manual = <String, Set<String>>{};
    for (final book in values) {
      final name = names[book.id];
      if (name != null) (manual[name] ??= {}).add(book.id);
    }
    final result = [
      for (final entry in manual.entries)
        LibraryGroup(
          key: 'folder:${entry.key}',
          label: entry.key,
          bookIds: entry.value,
        ),
    ];
    if (mode != LibraryGrouping.collection) {
      result.addAll(
        libraryGroups(
          values.where((book) => !names.containsKey(book.id)),
          mode,
        ).where((group) => group.key != 'missing' && group.bookIds.length > 1),
      );
    }
    return result
      ..sort((a, b) => a.label.toLowerCase().compareTo(b.label.toLowerCase()));
  }
}
