import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../settings/settings_controller.dart';
import '../data/coordinated_preferences.dart';
import '../domain/library_grouping.dart';
import 'library_filter_sheet.dart';
import 'library_preference_writes.dart';

final libraryFilterProvider =
    NotifierProvider<LibraryFilterController, LibraryFilterPreferences>(
      LibraryFilterController.new,
    );

class LibraryFilterPreferences {
  LibraryFilterPreferences({
    this.filter = const LibraryFilter(),
    Map<String, LibraryFilter> sorts = const {},
    Map<String, LibraryFilter> presets = const {},
  }) : sorts = Map.unmodifiable(sorts),
       presets = Map.unmodifiable(presets);

  final LibraryFilter filter;
  final Map<String, LibraryFilter> sorts;
  final Map<String, LibraryFilter> presets;

  static String scope(LibraryGrouping grouping, String? groupKey) =>
      jsonEncode([grouping.name, groupKey]);

  LibraryFilter forGroup(LibraryGrouping grouping, String? groupKey) {
    final sort = sorts[scope(grouping, groupKey)];
    return sort == null
        ? filter
        : sort.copyWith(
            display: filter.display,
            compact: filter.compact,
            showCategoryTabs: filter.showCategoryTabs,
            showUnreadBadge: filter.showUnreadBadge,
            showDownloadedBadge: filter.showDownloadedBadge,
            showLocalBadge: filter.showLocalBadge,
            showSource: filter.showSource,
            showReadingStatus: filter.showReadingStatus,
            showReadCount: filter.showReadCount,
            showFavoriteBadge: filter.showFavoriteBadge,
            showLastUpdated: filter.showLastUpdated,
            showPublicationStatus: filter.showPublicationStatus,
            showResumeButton: filter.showResumeButton,
          );
  }

  Map<String, dynamic> toJson() => {
    'filter': filter.toJson(),
    'sorts': {
      for (final entry in sorts.entries) entry.key: entry.value.toJson(),
    },
    if (presets.isNotEmpty)
      'presets': {
        for (final entry in presets.entries) entry.key: entry.value.toJson(),
      },
  };

  factory LibraryFilterPreferences.fromJson(Map<String, dynamic> json) {
    if (json['filter'] is! Map<String, dynamic> ||
        json['sorts'] is! Map<String, dynamic>) {
      throw const FormatException('Thiết lập thư viện không hợp lệ.');
    }
    final sorts = json['sorts'] as Map<String, dynamic>;
    final rawPresets = json['presets'] ?? <String, dynamic>{};
    if (rawPresets is! Map<String, dynamic> ||
        rawPresets.length > 50 ||
        rawPresets.entries.any(
          (entry) =>
              entry.key.trim().isEmpty ||
              entry.key != entry.key.trim() ||
              entry.key.length > 80 ||
              entry.value is! Map<String, dynamic>,
        )) {
      throw const FormatException('Bộ lọc thư viện đã lưu không hợp lệ.');
    }
    if (sorts.length > 10000 ||
        sorts.values.any((value) => value is! Map<String, dynamic>)) {
      throw const FormatException('Thứ tự riêng của danh mục không hợp lệ.');
    }
    return LibraryFilterPreferences(
      filter: LibraryFilter.fromJson(json['filter'] as Map<String, dynamic>),
      sorts: {
        for (final entry in sorts.entries)
          entry.key: LibraryFilter.fromJson(
            entry.value as Map<String, dynamic>,
          ),
      },
      presets: {
        for (final entry in rawPresets.entries)
          entry.key: LibraryFilter.fromJson(
            entry.value as Map<String, dynamic>,
          ),
      },
    );
  }
}

/// Local display preferences only, independent of library replacement revision.
class LibraryFilterController extends Notifier<LibraryFilterPreferences> {
  static const preferenceKey = 'libraryFilterV1';

  LibraryFilterPreferences _read() {
    final raw = ref.read(preferencesProvider).get(preferenceKey);
    if (raw == null) return LibraryFilterPreferences();
    if (raw is! String) {
      throw const FormatException('Thiết lập thư viện không hợp lệ.');
    }
    final json = jsonDecode(raw);
    if (json is! Map<String, dynamic>) {
      throw const FormatException('Thiết lập thư viện không hợp lệ.');
    }
    return LibraryFilterPreferences.fromJson(json);
  }

  @override
  LibraryFilterPreferences build() {
    ref.watch(preferencesProvider);
    try {
      return _read();
    } on FormatException {
      // Preserve invalid input; saving reports the problem before overwriting it.
      return LibraryFilterPreferences();
    }
  }

  Future<void> save(
    LibraryFilter filter, {
    required LibraryGrouping grouping,
    String? groupKey,
    int? expectedGeneration,
  }) {
    return LibraryPreferenceWrites.serialize(
      ref.read(preferencesProvider),
      () async {
        _checkGeneration(expectedGeneration);
        final previous = _read();
        final next = LibraryFilterPreferences(
          filter: filter,
          sorts: {
            ...previous.sorts,
            LibraryFilterPreferences.scope(grouping, groupKey): filter,
          },
          presets: previous.presets,
        );
        if (!await ref
            .read(preferencesProvider)
            .setString(preferenceKey, jsonEncode(next.toJson()))) {
          throw StateError('Không lưu được thiết lập thư viện.');
        }
        if (ref.mounted) state = next;
      },
    );
  }

  void _checkGeneration(int? expected) {
    final preferences = ref.read(preferencesProvider);
    final current = preferences is CoordinatedPreferences
        ? preferences.mutationGeneration
        : 0;
    if (expected != null && expected != current) {
      throw StateError('Thiết lập đã được khôi phục. Hãy mở lại bộ lọc.');
    }
  }

  Future<void> savePreset(
    String name,
    LibraryFilter filter, {
    int? expectedGeneration,
  }) => _editPreset(name, filter, expectedGeneration);
  Future<void> removePreset(String name, {int? expectedGeneration}) =>
      _editPreset(name, null, expectedGeneration);
  Future<void> _editPreset(
    String name,
    LibraryFilter? filter,
    int? generation,
  ) {
    final trimmed = name.trim();
    if (trimmed.isEmpty || trimmed.length > 80) {
      throw const FormatException('Tên bộ lọc cần từ 1 đến 80 ký tự.');
    }
    return LibraryPreferenceWrites.serialize(
      ref.read(preferencesProvider),
      () async {
        _checkGeneration(generation);
        final previous = _read();
        final presets = {...previous.presets};
        if (filter == null) {
          presets.remove(trimmed);
        } else {
          presets[trimmed] = filter;
        }
        if (presets.length > 50) {
          throw const FormatException('Chỉ lưu tối đa 50 bộ lọc thư viện.');
        }
        final next = LibraryFilterPreferences(
          filter: previous.filter,
          sorts: previous.sorts,
          presets: presets,
        );
        if (!await ref
            .read(preferencesProvider)
            .setString(preferenceKey, jsonEncode(next.toJson()))) {
          throw StateError('Không lưu được bộ lọc thư viện.');
        }
        if (ref.mounted) state = next;
      },
    );
  }
}
