import 'dart:convert';

/// Opaque, bounded JSON carried by the extension's SManga/SChapter. Some
/// sources need this context to reconstruct chapter URLs after an app restart.
/// This is source metadata, separate from the browser/cookie store.
Map<String, dynamic> sourceMemo(Object? value) {
  if (value == null) return const {};
  var nodes = 0;
  dynamic copy(Object? item, int depth) {
    if (++nodes > 4096 || depth > 12) {
      throw const FormatException('Dữ liệu phụ của nguồn vượt giới hạn.');
    }
    if (item == null || item is bool || item is num && item.isFinite) {
      return item;
    }
    if (item is String && item.length <= 32768) return item;
    if (item is List) {
      return List.unmodifiable(item.map((v) => copy(v, depth + 1)));
    }
    if (item is Map && item.keys.every((key) => key is String)) {
      return Map<String, dynamic>.unmodifiable({
        for (final entry in item.entries)
          entry.key as String: copy(entry.value, depth + 1),
      });
    }
    throw const FormatException('Dữ liệu phụ của nguồn không hợp lệ.');
  }

  final result = copy(value, 0);
  if (result is! Map<String, dynamic> ||
      utf8.encode(jsonEncode(result)).length > 65536) {
    throw const FormatException('Dữ liệu phụ của nguồn không hợp lệ.');
  }
  return result;
}
