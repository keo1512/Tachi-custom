import 'dart:convert';

import 'library_book.dart';
import 'library_grouping.dart';

/// Folder membership is independent of categories, author and series metadata.
class LibraryFolders {
  LibraryFolders([
    Map<String, String> names = const {},
    Map<String, Map<String, String?>> categoryNames = const {},
  ]) : names = Map.unmodifiable(names),
       categoryNames = Map.unmodifiable({
         for (final entry in categoryNames.entries)
           entry.key: Map<String, String?>.unmodifiable(entry.value),
       });
  static const preferenceKey = 'libraryFoldersV1';
  static const categoryPreferenceKey = 'libraryFoldersByCategoryV1';
  final Map<String, String> names;
  final Map<String, Map<String, String?>> categoryNames;

  factory LibraryFolders.decodeWithCategories(String? raw, String? categories) {
    final legacy = LibraryFolders.decode(raw);
    if (categories == null) return legacy;
    final data = jsonDecode(categories);
    if (data is! Map<String, dynamic> || data.length > 1000) {
      throw const FormatException('Thư mục theo danh mục không hợp lệ.');
    }
    final scopes = <String, Map<String, String?>>{};
    var count = 0;
    for (final entry in data.entries) {
      if (entry.key.isEmpty || entry.key.length > 256 || entry.value is! Map) {
        throw const FormatException('Danh mục thư mục không hợp lệ.');
      }
      final values = <String, String?>{};
      for (final item in (entry.value as Map).entries) {
        final id = item.key, name = item.value;
        if (id is! String ||
            id.isEmpty ||
            id.length > 4096 ||
            (name != null &&
                (name is! String ||
                    name.trim().isEmpty ||
                    name != name.trim() ||
                    name.length > 256)) ||
            ++count > 50000) {
          throw const FormatException('Thư mục theo danh mục không hợp lệ.');
        }
        values[id] = name as String?;
      }
      scopes[entry.key] = values;
    }
    return LibraryFolders(legacy.names, scopes);
  }

  Map<String, String> namesIn(String? category) {
    if (category == null) return names;
    return {
      ...names,
      for (final entry
          in (categoryNames[category] ?? const <String, String?>{}).entries)
        if (entry.value != null) entry.key: entry.value!,
    }..removeWhere(
      (id, _) =>
          categoryNames[category]?.containsKey(id) == true &&
          categoryNames[category]![id] == null,
    );
  }

  String encodeCategories() => jsonEncode(categoryNames);

  LibraryFolders migrateBookIds(
    Map<String, String> ids, {
    required bool replaceOld,
  }) {
    Map<String, T> transfer<T>(Map<String, T> values) {
      final next = Map<String, T>.of(values);
      for (final entry in ids.entries) {
        if (entry.key == entry.value || !values.containsKey(entry.key)) {
          continue;
        }
        if (values.containsKey(entry.value) &&
            values[entry.value] != values[entry.key]) {
          throw StateError(
            'Truyện đích đã có thư mục khác. Hãy kiểm tra trước khi chuyển nguồn.',
          );
        }
        next[entry.value] = values[entry.key] as T;
        if (replaceOld) next.remove(entry.key);
      }
      return next;
    }

    return LibraryFolders(transfer(names), {
      for (final entry in categoryNames.entries)
        entry.key: transfer(entry.value),
    });
  }

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

  List<LibraryGroup> groups(
    Iterable<LibraryBook> books,
    LibraryGrouping mode, {
    String? category,
  }) {
    final names = namesIn(category);
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
