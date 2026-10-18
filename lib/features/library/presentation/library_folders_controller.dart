import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../settings/settings_controller.dart';
import '../data/coordinated_preferences.dart';
import '../data/library_mutation.dart';
import '../domain/library_folders.dart';
import 'library_preference_writes.dart';
import 'library_view_model.dart';

final libraryFoldersProvider =
    NotifierProvider<LibraryFoldersController, LibraryFolders>(
      LibraryFoldersController.new,
    );

class LibraryFoldersController extends Notifier<LibraryFolders> {
  LibraryFolders _read() => LibraryFolders.decodeWithCategories(
    ref.read(preferencesProvider).getString(LibraryFolders.preferenceKey),
    ref
        .read(preferencesProvider)
        .getString(LibraryFolders.categoryPreferenceKey),
  );
  @override
  LibraryFolders build() {
    ref.watch(preferencesProvider);
    try {
      return _read();
    } on FormatException {
      // Keep corrupt input for diagnosis; assignments still validate before saving.
      return LibraryFolders();
    }
  }

  Future<void> assign(
    Iterable<String> ids,
    String? name, {
    required int expectedRevision,
    String? category,
  }) {
    final selected = ids.toSet();
    final preferences = ref.read(preferencesProvider);
    final generation = preferences is CoordinatedPreferences
        ? preferences.mutationGeneration
        : 0;
    bool current() =>
        ref.mounted &&
        ref.read(libraryRepositoryProvider).replacementRevision ==
            expectedRevision &&
        (preferences is! CoordinatedPreferences ||
            preferences.mutationGeneration == generation);
    return LibraryPreferenceWrites.serialize(preferences, () async {
      checkLibraryRevision(
        ref.read(libraryRepositoryProvider).replacementRevision,
        expectedRevision,
      );
      if (!current()) {
        throw StateError('Thiết lập đã được khôi phục. Mở lại thư mục.');
      }
      final trimmed = name?.trim();
      if (trimmed != null && (trimmed.isEmpty || trimmed.length > 256)) {
        throw const FormatException('Nhập tên thư mục dài tối đa 256 ký tự.');
      }
      final existing = (await ref.read(libraryRepositoryProvider).list())
          .map((book) => book.id)
          .toSet();
      if (!current() || !existing.containsAll(selected)) {
        throw StateError('Thư viện đã thay đổi. Chọn lại truyện để tiếp tục.');
      }
      final currentFolders = _read();
      final names = Map<String, String>.of(currentFolders.names);
      final scoped = <String, Map<String, String?>>{
        for (final entry in currentFolders.categoryNames.entries)
          entry.key: Map.of(entry.value),
      };
      for (final id in selected) {
        if (category != null) {
          (scoped[category] ??= {})[id] = trimmed;
        } else if (trimmed == null) {
          names.remove(id);
        } else {
          names[id] = trimmed;
        }
      }
      final next = LibraryFolders.decodeWithCategories(
        LibraryFolders(names, scoped).encode(),
        LibraryFolders(names, scoped).encodeCategories(),
      );
      final key = category == null
          ? LibraryFolders.preferenceKey
          : LibraryFolders.categoryPreferenceKey;
      final raw = category == null ? next.encode() : next.encodeCategories();
      final saved = preferences is CoordinatedPreferences
          ? await preferences.setStringIfCurrent(key, raw, current)
          : await preferences.setString(key, raw);
      if (!saved) throw StateError('Không lưu được thư mục truyện.');
      if (!current()) throw StateError('Thư viện đã thay đổi. Mở lại thư mục.');
      state = next;
    });
  }
}
