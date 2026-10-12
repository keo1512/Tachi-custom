import 'library_book.dart';

enum LibraryGrouping {
  collection('Kệ'),
  author('Tác giả'),
  series('Bộ truyện');

  const LibraryGrouping(this.label);
  final String label;
}

class LibraryGroup {
  LibraryGroup({
    required this.key,
    required this.label,
    required Iterable<String> bookIds,
  }) : bookIds = Set.unmodifiable(bookIds);

  final String key, label;
  final Set<String> bookIds;
}

/// Stored identities come first; newly discovered groups keep their default order.
List<LibraryGroup> orderLibraryGroups(
  List<LibraryGroup> groups,
  Iterable<String> preferredKeys,
) {
  final byKey = {for (final group in groups) group.key: group};
  final ordered = <LibraryGroup>[];
  for (final key in preferredKeys) {
    final group = byKey.remove(key);
    if (group != null) ordered.add(group);
  }
  return [...ordered, ...byKey.values];
}

/// Groups explicit metadata only. Titles are never used to infer an author or
/// series, and deriving groups does not mutate a manually assigned collection.
List<LibraryGroup> libraryGroups(
  Iterable<LibraryBook> books,
  LibraryGrouping grouping,
) {
  final labels = <String, String>{};
  final members = <String, Set<String>>{};
  final seen = <String>{};
  for (final book in books) {
    if (!seen.add(book.id)) continue;
    final values = switch (grouping) {
      LibraryGrouping.collection => book.categories,
      LibraryGrouping.author => [book.author],
      LibraryGrouping.series => [book.series],
    };
    for (final raw in values) {
      final value = grouping == LibraryGrouping.collection
          ? raw
          : raw.trim().replaceAll(RegExp(r'\s+'), ' ');
      final key = value.isEmpty
          ? 'missing'
          : 'value:${grouping == LibraryGrouping.collection ? value : value.toLowerCase()}';
      labels.putIfAbsent(
        key,
        () => value.isEmpty
            ? switch (grouping) {
                LibraryGrouping.collection => 'Chưa có kệ',
                LibraryGrouping.author => 'Chưa có tác giả',
                LibraryGrouping.series => 'Chưa có bộ truyện',
              }
            : value,
      );
      (members[key] ??= <String>{}).add(book.id);
    }
  }
  final result = [
    for (final entry in members.entries)
      LibraryGroup(
        key: entry.key,
        label: labels[entry.key]!,
        bookIds: entry.value,
      ),
  ];
  result.sort((a, b) {
    if (a.key == 'missing') return 1;
    if (b.key == 'missing') return -1;
    return a.label.toLowerCase().compareTo(b.label.toLowerCase());
  });
  return result;
}
