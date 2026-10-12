import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../library/data/coordinated_preferences.dart';
import '../../settings/settings_controller.dart';
import '../domain/source_languages.dart';

final sourceLanguagesProvider =
    NotifierProvider<SourceLanguagesController, SourceLanguages>(
      SourceLanguagesController.new,
    );

class SourceLanguagesController extends Notifier<SourceLanguages> {
  Future<void> _pending = Future<void>.value();
  @override
  SourceLanguages build() {
    try {
      return SourceLanguages.decode(
        ref.watch(preferencesProvider).getString('sourceLanguagesV1'),
      );
    } catch (_) {
      return const SourceLanguages(null);
    }
  }

  Future<void> save(SourceLanguages languages, {int? expectedGeneration}) {
    final preferences = ref.read(preferencesProvider);
    final generation =
        expectedGeneration ??
        (preferences is CoordinatedPreferences
            ? preferences.mutationGeneration
            : null);
    // Validate even values constructed directly by callers.
    final encoded = languages.encode();
    final validated = SourceLanguages.decode(encoded);
    final result = _pending.then((_) async {
      if (!ref.mounted ||
          (preferences is CoordinatedPreferences &&
              generation != preferences.mutationGeneration)) {
        throw StateError('Thiết lập đã khôi phục. Hãy mở lại bộ lọc ngôn ngữ.');
      }
      if (!await preferences.setString('sourceLanguagesV1', encoded)) {
        throw StateError('Không lưu được ngôn ngữ nguồn.');
      }
      if (ref.mounted) state = validated;
    });
    _pending = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }
}
