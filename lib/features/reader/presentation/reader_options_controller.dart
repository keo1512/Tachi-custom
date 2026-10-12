import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../settings/settings_controller.dart';
import '../../library/data/coordinated_preferences.dart';
import '../domain/reader_options.dart';

final readerOptionsProvider =
    NotifierProvider<ReaderOptionsController, ReaderOptions>(
      ReaderOptionsController.new,
    );

class ReaderOptionsController extends Notifier<ReaderOptions> {
  Future<void> _pending = Future<void>.value();
  @override
  ReaderOptions build() {
    final raw = ref.watch(preferencesProvider).getString('readerOptionsV1');
    if (raw == null) return const ReaderOptions();
    try {
      return ReaderOptions.fromJson(
        Map<String, dynamic>.from(jsonDecode(raw) as Map),
      );
    } catch (_) {
      return const ReaderOptions();
    }
  }

  Future<void> set(ReaderOptions options, {int? expectedGeneration}) =>
      _save((_) => options, expectedGeneration: expectedGeneration);
  Future<void> patch(Map<String, dynamic> values, {int? expectedGeneration}) =>
      _save(
        (current) => current.patch(values),
        expectedGeneration: expectedGeneration,
      );
  Future<void> _save(
    ReaderOptions Function(ReaderOptions) edit, {
    int? expectedGeneration,
  }) {
    final preferences = ref.read(preferencesProvider);
    final generation =
        expectedGeneration ??
        (preferences is CoordinatedPreferences
            ? preferences.mutationGeneration
            : null);
    final result = _pending.then((_) async {
      if (!ref.mounted ||
          (preferences is CoordinatedPreferences &&
              generation != preferences.mutationGeneration)) {
        throw StateError('Thiết lập đã khôi phục. Hãy mở lại trình đọc.');
      }
      final raw = preferences.getString('readerOptionsV1');
      final current = raw == null
          ? const ReaderOptions()
          : ReaderOptions.fromJson(
              Map<String, dynamic>.from(jsonDecode(raw) as Map),
            );
      final options = edit(current);
      if (!await preferences.setString(
        'readerOptionsV1',
        jsonEncode(options.toJson()),
      )) {
        throw StateError('Không lưu được thiết lập đọc.');
      }
      if (ref.mounted) state = options;
    });
    _pending = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }
}
