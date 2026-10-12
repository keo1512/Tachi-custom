import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/platform/native_tabs.dart';
import '../library/data/coordinated_preferences.dart';
import 'settings_controller.dart';

/// IDs identify routes; the order only changes their visible positions.
class NavigationPreferences {
  const NavigationPreferences({
    this.order = const [0, 1, 2, 3, 4, 5],
    this.start = 0,
    this.showLabels = true,
    this.rememberSelected = false,
  });
  final List<int> order;
  final int start;
  final bool showLabels, rememberSelected;
  factory NavigationPreferences.decode(String? value) {
    if (value == null) return const NavigationPreferences();
    final data = jsonDecode(value);
    if (data is! Map<String, dynamic> ||
        data.keys.any(
          (key) => ![
            'order',
            'start',
            'showLabels',
            'rememberSelected',
          ].contains(key),
        )) {
      throw const FormatException('Thiết lập thanh tab không hợp lệ.');
    }
    final order = data['order'] ?? [0, 1, 2, 3, 4, 5];
    final start = data['start'] ?? 0;
    final labels = data['showLabels'] ?? true;
    final remember = data['rememberSelected'] ?? false;
    if (order is! List ||
        order.length != 6 ||
        order.any((id) => id is! int || id < 0 || id >= 6) ||
        order.toSet().length != 6 ||
        start is! int ||
        start < 0 ||
        start >= 6 ||
        labels is! bool ||
        remember is! bool) {
      throw const FormatException('Thiết lập thanh tab không hợp lệ.');
    }
    return NavigationPreferences(
      order: List.unmodifiable(order.cast<int>()),
      start: start,
      showLabels: labels,
      rememberSelected: remember,
    );
  }
  String encode() => jsonEncode({
    'order': order,
    'start': start,
    'showLabels': showLabels,
    'rememberSelected': rememberSelected,
  });
}

final navigationPreferencesProvider =
    NotifierProvider<NavigationPreferencesController, NavigationPreferences>(
      NavigationPreferencesController.new,
    );

class NavigationPreferencesController extends Notifier<NavigationPreferences> {
  static const key = 'navigationPreferencesV1';
  static const lastKey = 'lastSelectedTabV1';
  Future<void> _writes = Future.value();
  @override
  NavigationPreferences build() {
    try {
      return NavigationPreferences.decode(
        ref.watch(preferencesProvider).getString(key),
      );
    } catch (_) {
      return const NavigationPreferences();
    }
  }

  String get startRoute {
    final last = ref.read(preferencesProvider).getInt(lastKey);
    final index =
        state.rememberSelected && last != null && last >= 0 && last < 6
        ? last
        : state.start;
    return mainTabRoutes[index];
  }

  Future<void> save(NavigationPreferences value, {int? expectedGeneration}) {
    // Validate public values even when constructed by a settings screen.
    final next = NavigationPreferences.decode(value.encode());
    final preferences = ref.read(preferencesProvider);
    final generation =
        expectedGeneration ??
        (preferences is CoordinatedPreferences
            ? preferences.mutationGeneration
            : null);
    final work = _writes.then((_) async {
      if (!ref.mounted ||
          preferences is CoordinatedPreferences &&
              preferences.mutationGeneration != generation) {
        throw StateError(
          'Cấu hình đã được khôi phục. Hãy mở lại thiết lập thanh tab.',
        );
      }
      if (!await preferences.setString(key, next.encode())) {
        throw StateError('Không lưu được thanh tab.');
      }
      if (ref.mounted) state = next;
    });
    _writes = work.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return work;
  }

  Future<void> recordSelection(String path) async {
    if (!state.rememberSelected) return;
    final index = mainTabRoutes.indexOf(path);
    if (index < 0) return;
    final preferences = ref.read(preferencesProvider);
    if (preferences.getInt(lastKey) != index) {
      await preferences.setInt(lastKey, index);
    }
  }
}
