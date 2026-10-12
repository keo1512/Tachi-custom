import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../settings/settings_controller.dart';
import '../domain/library_categories.dart';
import '../domain/library_book.dart';
import 'library_view_model.dart';
import 'library_preference_writes.dart';
import 'library_category_preference_migration.dart';
import 'library_filter_controller.dart';
import 'library_group_order_controller.dart';

final libraryCategoriesProvider =
    NotifierProvider<LibraryCategoryController, LibraryCategoryRegistry>(
      LibraryCategoryController.new,
    );

class LibraryCategoryController extends Notifier<LibraryCategoryRegistry> {
  static const preferenceKey = 'libraryCategoriesV1';

  LibraryCategoryRegistry _read() {
    final raw = ref.read(preferencesProvider).get(preferenceKey);
    if (raw == null) return LibraryCategoryRegistry();
    if (raw is! String) {
      throw const FormatException('Thiết lập danh mục không hợp lệ.');
    }
    final json = jsonDecode(raw);
    if (json is! Map<String, dynamic>) {
      throw const FormatException('Thiết lập danh mục không hợp lệ.');
    }
    return LibraryCategoryRegistry.fromJson(json);
  }

  @override
  LibraryCategoryRegistry build() {
    ref.watch(preferencesProvider);
    try {
      return _read();
    } on FormatException {
      return LibraryCategoryRegistry();
    }
  }

  void _revision(int expectedRevision) {
    if (ref.read(libraryRepositoryProvider).replacementRevision !=
        expectedRevision) {
      throw StateError(
        'Thư viện đã được thay đổi hoặc khôi phục. Mở lại danh mục để tiếp tục.',
      );
    }
  }

  Future<T> _serialize<T>(Future<T> Function() action) {
    return LibraryPreferenceWrites.serialize(
      ref.read(preferencesProvider),
      action,
    );
  }

  Future<void> _save(LibraryCategoryRegistry next) async {
    if (!await ref
        .read(preferencesProvider)
        .setString(preferenceKey, jsonEncode(next.toJson()))) {
      throw StateError('Không lưu được thiết lập danh mục.');
    }
    if (ref.mounted) state = next;
  }

  Future<int> _changeMemberships({
    required String oldName,
    required String? newName,
    required int expectedRevision,
    required Iterable<String> ids,
    required LibraryBook Function(LibraryBook) transform,
    required LibraryBook Function(LibraryBook) rollback,
    required LibraryCategoryRegistry next,
  }) async {
    final preferences = ref.read(preferencesProvider);
    final rawRegistry = preferences.getString(preferenceKey);
    final migration = LibraryCategoryPreferenceMigration.prepare(
      preferences,
      oldName,
      newName,
    );
    final repository = ref.read(libraryRepositoryProvider);
    final selected = ids.toList();
    var changed = false;
    var attemptedRegistry = false;
    try {
      await migration.apply();
      final count = await repository.mutateBooks(
        selected,
        transform,
        expectedRevision: expectedRevision,
      );
      changed = true;
      _revision(expectedRevision);
      attemptedRegistry = true;
      await _save(next);
      _revision(expectedRevision);
      return count;
    } catch (error, stack) {
      // Restore only affected memberships in the latest rows, never old progress
      // or chapter/cache snapshots. A replacement revision forbids this repair.
      if (changed && repository.replacementRevision == expectedRevision) {
        await repository.mutateBooks(
          selected,
          rollback,
          expectedRevision: expectedRevision,
        );
      }
      if (attemptedRegistry) {
        final restored = rawRegistry == null
            ? await preferences.remove(preferenceKey)
            : await preferences.setString(preferenceKey, rawRegistry);
        if (!restored) {
          throw StateError('Không khôi phục được thiết lập danh mục cũ.');
        }
      }
      await migration.rollback();
      Error.throwWithStackTrace(error, stack);
    } finally {
      if (ref.mounted) {
        ref.invalidate(libraryFilterProvider);
        ref.invalidate(libraryGroupOrderProvider);
        state = _read();
        await ref.read(libraryProvider.notifier).refresh();
      }
    }
  }

  String _name(String value) {
    final name = value.trim();
    if (name.isEmpty ||
        name.length > 256 ||
        [
          'Tất cả',
          'Đang đọc',
          'Yêu thích',
          'Hoàn thành',
          'Mặc định',
        ].contains(name)) {
      throw const FormatException(
        'Nhập tên danh mục khác các mục hệ thống, dài tối đa 256 ký tự.',
      );
    }
    return name;
  }

  Future<void> create(String value) => _serialize(() async {
    final name = _name(value);
    final previous = _read();
    final books = await ref.read(libraryRepositoryProvider).list();
    if (previous.all(books).any((category) => category.name == name)) {
      throw const FormatException('Danh mục đã tồn tại.');
    }
    await _save(
      LibraryCategoryRegistry(
        categories: [
          ...previous.categories,
          LibraryCategory(name: name),
        ],
        defaultCategories: previous.defaultCategories,
      ),
    );
  });

  Future<void> setDefaults(Iterable<String> names) => _serialize(() async {
    final previous = _read();
    final all = previous.all(await ref.read(libraryRepositoryProvider).list());
    final selected = names.toSet().toList();
    if (selected.any((name) => !all.any((category) => category.name == name))) {
      throw const FormatException('Danh mục mặc định không tồn tại.');
    }
    await _save(
      LibraryCategoryRegistry(categories: all, defaultCategories: selected),
    );
  });

  Future<void> setPolicy(
    String name, {
    CategoryPolicy? update,
    CategoryPolicy? download,
  }) => _serialize(() async {
    final previous = _read();
    final all = previous.all(await ref.read(libraryRepositoryProvider).list());
    if (!all.any((category) => category.name == name)) {
      throw const FormatException('Danh mục không tồn tại.');
    }
    await _save(
      LibraryCategoryRegistry(
        categories: [
          for (final category in all)
            category.name == name
                ? category.copyWith(update: update, download: download)
                : category,
        ],
        defaultCategories: previous.defaultCategories,
      ),
    );
  });

  Future<int> rename(
    String oldName,
    String value, {
    required int expectedRevision,
  }) => _serialize(() async {
    final newName = _name(value);
    final previous = _read();
    _revision(expectedRevision);
    final repository = ref.read(libraryRepositoryProvider);
    final books = await repository.list();
    final all = previous.all(books);
    if (oldName == 'Mặc định' ||
        !all.any((category) => category.name == oldName)) {
      throw const FormatException('Không thể đổi tên danh mục này.');
    }
    if (oldName == newName) return 0;
    if (all.any((category) => category.name == newName)) {
      throw const FormatException('Danh mục đã tồn tại.');
    }
    return _changeMemberships(
      oldName: oldName,
      newName: newName,
      expectedRevision: expectedRevision,
      ids: books
          .where((book) => book.categories.contains(oldName))
          .map((book) => book.id),
      transform: (latest) => latest.copyWith(
        categories: [
          for (final name in latest.categories)
            name == oldName ? newName : name,
        ],
      ),
      rollback: (latest) => latest.copyWith(
        categories: [
          for (final name in latest.categories)
            name == newName ? oldName : name,
        ],
      ),
      next: LibraryCategoryRegistry(
        categories: [
          for (final category in all)
            category.name == oldName
                ? category.copyWith(name: newName)
                : category,
        ],
        defaultCategories: [
          for (final name in previous.defaultCategories)
            name == oldName ? newName : name,
        ],
      ),
    );
  });

  Future<int> remove(String name, {required int expectedRevision}) =>
      _serialize(() async {
        final previous = _read();
        _revision(expectedRevision);
        if (name == 'Mặc định') {
          throw const FormatException('Không thể xóa mục Mặc định.');
        }
        final repository = ref.read(libraryRepositoryProvider);
        final books = await repository.list();
        final previousMemberships = {
          for (final book in books)
            if (book.categories.contains(name)) book.id: book.categories,
        };
        return _changeMemberships(
          oldName: name,
          newName: null,
          expectedRevision: expectedRevision,
          ids: books
              .where((book) => book.categories.contains(name))
              .map((book) => book.id),
          transform: (latest) => latest.copyWith(
            categories: latest.categories
                .where((value) => value != name)
                .toList(),
          ),
          rollback: (latest) {
            if (latest.categories.contains(name)) return latest;
            final original = previousMemberships[latest.id]!;
            final categories = latest.categories.toList();
            if (categories.length == 1 &&
                categories.single == 'Mặc định' &&
                !original.contains('Mặc định')) {
              categories.clear();
            }
            categories.insert(
              original.indexOf(name).clamp(0, categories.length),
              name,
            );
            return latest.copyWith(categories: categories);
          },
          next: LibraryCategoryRegistry(
            categories: previous
                .all(books)
                .where((category) => category.name != name)
                .toList(),
            defaultCategories: previous.defaultCategories
                .where((value) => value != name)
                .toList(),
          ),
        );
      });
}
