import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../settings/settings_controller.dart';
import '../domain/library_grouping.dart';
import 'library_preference_writes.dart';

final libraryGroupOrderProvider =
    NotifierProvider<LibraryGroupOrderController, Map<String, List<String>>>(
      LibraryGroupOrderController.new,
    );

/// Display order only; book metadata and category identities are unchanged.
class LibraryGroupOrderController extends Notifier<Map<String, List<String>>> {
  static const preferenceKey = 'libraryGroupOrderV1';

  Map<String, List<String>> _read() {
    final raw = ref.read(preferencesProvider).get(preferenceKey);
    if (raw == null) return const {};
    if (raw is! String) {
      throw const FormatException('Thứ tự các mục thư viện không hợp lệ.');
    }
    final decoded = jsonDecode(raw);
    if (decoded is! Map<String, dynamic> ||
        decoded.values.any(
          (value) => value is! List || value.any((key) => key is! String),
        )) {
      throw const FormatException('Thứ tự các mục thư viện không hợp lệ.');
    }
    return Map.unmodifiable({
      for (final entry in decoded.entries)
        entry.key: List<String>.unmodifiable(
          (entry.value as List).cast<String>(),
        ),
    });
  }

  @override
  Map<String, List<String>> build() {
    ref.watch(preferencesProvider);
    try {
      return _read();
    } on FormatException {
      // Keep the stored value; a later save reports it instead of discarding it.
      return const {};
    }
  }

  Future<void> setOrder(LibraryGrouping grouping, Iterable<String> keys) {
    final order = keys.toList(growable: false);
    if (order.any((key) => key.isEmpty) ||
        order.toSet().length != order.length) {
      throw const FormatException(
        'Danh sách các mục bị trùng hoặc không hợp lệ.',
      );
    }
    return LibraryPreferenceWrites.serialize(
      ref.read(preferencesProvider),
      () async {
        final previous = _read();
        // Retain temporarily absent groups and orders for the other grouping modes.
        final next = {
          ...previous,
          grouping.name: [
            ...order,
            ...?previous[grouping.name]?.where((key) => !order.contains(key)),
          ],
        };
        if (!await ref
            .read(preferencesProvider)
            .setString(preferenceKey, jsonEncode(next))) {
          throw StateError('Không lưu được thứ tự các mục thư viện.');
        }
        if (ref.mounted) {
          state = Map.unmodifiable({
            for (final entry in next.entries)
              entry.key: List<String>.unmodifiable(entry.value),
          });
        }
      },
    );
  }
}
