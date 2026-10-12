import 'library_book.dart';
import 'library_grouping.dart';

enum CategoryPolicy { inherit, include, exclude }

class LibraryCategory {
  const LibraryCategory({
    required this.name,
    this.update = CategoryPolicy.inherit,
    this.download = CategoryPolicy.inherit,
  });
  final String name;
  final CategoryPolicy update, download;

  LibraryCategory copyWith({
    String? name,
    CategoryPolicy? update,
    CategoryPolicy? download,
  }) => LibraryCategory(
    name: name ?? this.name,
    update: update ?? this.update,
    download: download ?? this.download,
  );

  Map<String, dynamic> toJson() => {
    'name': name,
    'update': update.name,
    'download': download.name,
  };
  factory LibraryCategory.fromJson(Map<String, dynamic> json) {
    CategoryPolicy policy(String key) {
      final value = json[key] ?? 'inherit';
      for (final option in CategoryPolicy.values) {
        if (option.name == value) return option;
      }
      throw const FormatException('Chính sách danh mục không hợp lệ.');
    }

    if (json['name'] is! String ||
        (json['name'] as String).trim().isEmpty ||
        (json['name'] as String).length > 256) {
      throw const FormatException('Tên danh mục không hợp lệ.');
    }
    return LibraryCategory(
      name: json['name'] as String,
      update: policy('update'),
      download: policy('download'),
    );
  }
}

class LibraryCategoryRegistry {
  LibraryCategoryRegistry({
    List<LibraryCategory> categories = const [],
    List<String> defaultCategories = const [],
  }) : categories = List.unmodifiable(categories),
       defaultCategories = List.unmodifiable(defaultCategories);

  final List<LibraryCategory> categories;
  final List<String> defaultCategories;

  LibraryCategory policyFor(String name) =>
      categories.where((category) => category.name == name).firstOrNull ??
      LibraryCategory(name: name);

  List<LibraryCategory> all(Iterable<LibraryBook> books) {
    final result = {for (final category in categories) category.name: category};
    for (final book in books) {
      for (final name in book.categories) {
        if (name.trim().isEmpty) continue;
        result.putIfAbsent(name, () => LibraryCategory(name: name));
      }
    }
    return result.values.toList();
  }

  /// Explicit exclusions take priority over inclusion in another category.
  bool allowsUpdate(LibraryBook book) {
    if (book.categories.any(
      (name) => policyFor(name).update == CategoryPolicy.exclude,
    )) {
      return false;
    }
    final included = categories
        .where((category) => category.update == CategoryPolicy.include)
        .map((category) => category.name)
        .toSet();
    return included.isEmpty || book.categories.any(included.contains);
  }

  bool allowsAutoDownload(LibraryBook book) =>
      !book.categories.any(
        (name) => policyFor(name).download == CategoryPolicy.exclude,
      ) &&
      book.categories.any(
        (name) => policyFor(name).download == CategoryPolicy.include,
      );

  Map<String, dynamic> toJson() => {
    'categories': categories.map((category) => category.toJson()).toList(),
    'defaultCategories': defaultCategories,
  };

  factory LibraryCategoryRegistry.fromJson(Map<String, dynamic> json) {
    final values = json['categories'];
    final defaults = json['defaultCategories'] ?? const [];
    if (values is! List ||
        values.length > 10000 ||
        values.any((value) => value is! Map<String, dynamic>) ||
        defaults is! List ||
        defaults.any((value) => value is! String)) {
      throw const FormatException('Thiết lập danh mục không hợp lệ.');
    }
    final categories = values
        .map((value) => LibraryCategory.fromJson(value as Map<String, dynamic>))
        .toList();
    final names = categories.map((category) => category.name).toSet();
    if (names.length != categories.length ||
        defaults.toSet().length != defaults.length ||
        defaults.any((value) => !names.contains(value))) {
      throw const FormatException(
        'Danh mục bị trùng hoặc danh mục mặc định không tồn tại.',
      );
    }
    return LibraryCategoryRegistry(
      categories: categories,
      defaultCategories: defaults.cast<String>(),
    );
  }
}

List<LibraryGroup> libraryCategoryGroups(
  Iterable<LibraryBook> books,
  LibraryCategoryRegistry registry,
) {
  final groups = {
    for (final group in libraryGroups(books, LibraryGrouping.collection))
      group.key: group,
  };
  for (final category in registry.categories) {
    groups.putIfAbsent(
      'value:${category.name}',
      () => LibraryGroup(
        key: 'value:${category.name}',
        label: category.name,
        bookIds: const [],
      ),
    );
  }
  final ordered = groups.values.toList()
    ..sort((a, b) => a.label.toLowerCase().compareTo(b.label.toLowerCase()));
  return ordered;
}
