import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../settings/settings_controller.dart';
import '../../library/data/coordinated_preferences.dart';
import '../domain/catalogue.dart';
import '../domain/source_filters.dart';

final sourceFilterPresetsProvider = Provider(
  (ref) => SourceFilterPresetStore(
    ref.watch(preferencesProvider),
    isCurrent: () => ref.mounted,
  ),
);

class SourceFilterPreset {
  const SourceFilterPreset(this.name, this.filters);
  final String name;
  final SourceFilterSet filters;
}

class SourceFilterPresetStore {
  SourceFilterPresetStore(this.preferences, {bool Function()? isCurrent})
    : _isCurrent = isCurrent ?? (() => true),
      _generation = preferences is CoordinatedPreferences
          ? preferences.mutationGeneration
          : null;
  final SharedPreferences preferences;
  final bool Function() _isCurrent;
  final int? _generation;
  static const key = 'savedSourceFiltersV1';
  Future<void> _tail = Future.value();

  Map<String, dynamic> _read() {
    final raw = preferences.getString(key);
    if (raw == null) return {};
    if (raw.length > 1024 * 1024) {
      throw const ApiException('Bộ lọc đã lưu vượt giới hạn 1 MiB.');
    }
    try {
      final json = jsonDecode(raw);
      if (json is Map<String, dynamic> && raw.length <= 1024 * 1024) {
        return json;
      }
    } catch (_) {}
    throw const ApiException(
      'Bộ lọc đã lưu bị hỏng. Dữ liệu hiện có được giữ nguyên.',
    );
  }

  List<SourceFilterPreset> list(String sourceIdentity) {
    final json = _read()[sourceIdentity];
    if (json == null) return [];
    if (json is! Map<String, dynamic>) {
      throw const ApiException('Danh sách bộ lọc đã lưu không hợp lệ.');
    }
    return [
      for (final entry in json.entries)
        SourceFilterPreset(
          entry.key,
          SourceFilterSet.fromJson(
            entry.value is Map<String, dynamic>
                ? entry.value as Map<String, dynamic>
                : throw const ApiException('Bộ lọc đã lưu không hợp lệ.'),
          ),
        ),
    ];
  }

  Future<void> save(
    String sourceIdentity,
    String name,
    SourceFilterSet filters,
  ) {
    final snapshot = filters.clone();
    return _mutate((json) {
      final label = name.trim();
      if (label.isEmpty || label.length > 80) {
        throw const ApiException('Tên bộ lọc cần có từ 1 đến 80 ký tự.');
      }
      final current = json[sourceIdentity];
      if (current != null && current is! Map<String, dynamic>) {
        throw const ApiException('Bộ lọc đã lưu không hợp lệ.');
      }
      final source = Map<String, dynamic>.from(
        current as Map<String, dynamic>? ?? {},
      );
      if (source.length >= 30 && !source.containsKey(label)) {
        throw const ApiException('Tối đa 30 bộ lọc đã lưu cho một nguồn.');
      }
      source[label] = snapshot.toJson();
      json[sourceIdentity] = source;
    });
  }

  Future<void> remove(String sourceIdentity, String name) => _mutate((json) {
    final source = json[sourceIdentity];
    if (source is Map<String, dynamic>) {
      source.remove(name);
      if (source.isEmpty) {
        json.remove(sourceIdentity);
      }
    }
  });

  /// Rename and replace in one write, preserving other presets and sources.
  Future<void> replace(
    String sourceIdentity,
    String previousName,
    String name,
    SourceFilterSet filters,
  ) {
    final snapshot = filters.clone();
    return _mutate((json) {
      final label = name.trim();
      if (label.isEmpty || label.length > 80) {
        throw const ApiException('Tên bộ lọc cần có từ 1 đến 80 ký tự.');
      }
      final source = json[sourceIdentity];
      if (source is! Map<String, dynamic> ||
          !source.containsKey(previousName)) {
        throw const ApiException('Bộ lọc đã thay đổi. Hãy mở lại danh sách.');
      }
      if (label != previousName && source.containsKey(label)) {
        throw const ApiException('Tên bộ lọc này đã được sử dụng.');
      }
      source.remove(previousName);
      source[label] = snapshot.toJson();
    });
  }

  bool get _current =>
      _isCurrent() &&
      (preferences is! CoordinatedPreferences ||
          (preferences as CoordinatedPreferences).mutationGeneration ==
              _generation);

  Future<void> _mutate(void Function(Map<String, dynamic>) action) {
    final operation = _tail.then((_) async {
      if (!_current) {
        throw const ApiException(
          'Thiết lập đã được khôi phục. Hãy mở lại bộ lọc trước khi lưu.',
        );
      }
      final json = _read();
      action(json);
      final raw = jsonEncode(json);
      if (raw.length > 1024 * 1024) {
        throw const ApiException('Bộ lọc đã lưu vượt giới hạn 1 MiB.');
      }
      if (!await preferences.setString(key, raw)) {
        throw const ApiException('Chưa lưu được bộ lọc.');
      }
      if (!_current) {
        throw const ApiException('Thiết lập đã thay đổi trong lúc lưu bộ lọc.');
      }
    });
    _tail = operation.then((_) {}, onError: (Object _) {});
    return operation;
  }
}
