import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../domain/library_grouping.dart';
import 'library_filter_controller.dart';
import 'library_group_order_controller.dart';

/// Changes only category references, preserving unrecognized preference fields.
class LibraryCategoryPreferenceMigration {
  LibraryCategoryPreferenceMigration._(
    this.preferences,
    this.before,
    this.after,
  );

  final SharedPreferences preferences;
  final Map<String, String> before, after;
  final List<String> _written = [];

  factory LibraryCategoryPreferenceMigration.prepare(
    SharedPreferences preferences,
    String oldName,
    String? newName,
  ) {
    final before = <String, String>{};
    final after = <String, String>{};
    final oldGroup = 'value:$oldName';
    final newGroup = newName == null ? null : 'value:$newName';
    Map<String, dynamic>? read(String key) {
      final raw = preferences.get(key);
      if (raw == null) return null;
      if (raw is! String) {
        throw const FormatException('Thiết lập danh mục không hợp lệ.');
      }
      final json = jsonDecode(raw);
      if (json is! Map<String, dynamic>) {
        throw const FormatException('Thiết lập danh mục không hợp lệ.');
      }
      before[key] = raw;
      return json;
    }

    final order = read(LibraryGroupOrderController.preferenceKey);
    if (order != null) {
      final values = order[LibraryGrouping.collection.name];
      if (values != null) {
        if (values is! List || values.any((value) => value is! String)) {
          throw const FormatException('Thứ tự danh mục không hợp lệ.');
        }
        order[LibraryGrouping.collection.name] = <String>{
          for (final value in values)
            if (value != oldGroup || newGroup != null)
              value == oldGroup ? newGroup! : value,
        }.toList();
      }
      after[LibraryGroupOrderController.preferenceKey] = jsonEncode(order);
    }
    final filters = read(LibraryFilterController.preferenceKey);
    if (filters != null) {
      LibraryFilterPreferences.fromJson(filters);
      final sorts = filters['sorts'] as Map<String, dynamic>;
      final oldScope = LibraryFilterPreferences.scope(
        LibraryGrouping.collection,
        oldGroup,
      );
      final saved = sorts.remove(oldScope);
      if (saved != null && newGroup != null) {
        final newScope = LibraryFilterPreferences.scope(
          LibraryGrouping.collection,
          newGroup,
        );
        if (sorts.containsKey(newScope)) {
          throw const FormatException('Thiết lập danh mục đích đã tồn tại.');
        }
        sorts[newScope] = saved;
      }
      for (final filter in [filters['filter'], ...sorts.values]) {
        final map = filter as Map<String, dynamic>;
        if (map['category'] == oldName) {
          map['category'] = newName ?? 'Tất cả';
        }
      }
      after[LibraryFilterController.preferenceKey] = jsonEncode(filters);
    }
    return LibraryCategoryPreferenceMigration._(preferences, before, after);
  }

  Future<void> apply() async {
    for (final entry in after.entries) {
      // A failed setter can still update the plugin's in-memory cache.
      _written.add(entry.key);
      if (!await preferences.setString(entry.key, entry.value)) {
        throw StateError('Không lưu được thiết lập danh mục.');
      }
    }
  }

  Future<void> rollback() async {
    for (final key in _written.reversed) {
      if (preferences.get(key) != after[key]) continue;
      if (!await preferences.setString(key, before[key]!)) {
        throw StateError('Không khôi phục được thiết lập danh mục cũ.');
      }
    }
  }
}
