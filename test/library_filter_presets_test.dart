import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tachi_books/features/library/data/backup_configuration.dart';
import 'package:tachi_books/features/library/data/coordinated_preferences.dart';
import 'package:tachi_books/features/library/data/library_repository.dart';
import 'package:tachi_books/features/library/domain/library_grouping.dart';
import 'package:tachi_books/features/library/presentation/library_filter_controller.dart';
import 'package:tachi_books/features/library/presentation/library_filter_sheet.dart';
import 'package:tachi_books/features/settings/settings_controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  test('named library presets persist independently of per-category sorting and enter validated public backups', () async {
    final prefs = await SharedPreferences.getInstance();
    final container = ProviderContainer(
      overrides: [preferencesProvider.overrideWithValue(prefs)],
    );
    addTearDown(container.dispose);
    final controller = container.read(libraryFilterProvider.notifier);
    const favorite = LibraryFilter(
      favorite: LibraryTriState.include,
      order: LibraryOrder.title,
    );
    await controller.savePreset('Yêu thích', favorite);
    await controller.save(
      const LibraryFilter(downloaded: LibraryTriState.include),
      grouping: LibraryGrouping.collection,
      groupKey: 'Manga',
    );
    expect(
      container.read(libraryFilterProvider).presets['Yêu thích']!.favorite,
      LibraryTriState.include,
    );
    final config = BackupConfiguration.capture(prefs);
    expect(
      (jsonDecode(config.values['libraryFilterV1'] as String)
          as Map)['presets'],
      contains('Yêu thích'),
    );
    final restarted = ProviderContainer(
      overrides: [preferencesProvider.overrideWithValue(prefs)],
    );
    addTearDown(restarted.dispose);
    expect(
      restarted.read(libraryFilterProvider).presets['Yêu thích']!.order,
      LibraryOrder.title,
    );
    await controller.savePreset('Yêu thích', const LibraryFilter());
    expect(
      container.read(libraryFilterProvider).presets['Yêu thích']!.active,
      false,
    );
    await controller.removePreset('Yêu thích');
    expect(container.read(libraryFilterProvider).presets, isEmpty);
  });
  test('old filter editor cannot replace imported configuration and malformed presets are retained', () async {
    final raw = await SharedPreferences.getInstance();
    final repo = MemoryLibraryRepository();
    final prefs = await CoordinatedPreferences.open(raw, repo);
    final container = ProviderContainer(
      overrides: [preferencesProvider.overrideWithValue(prefs)],
    );
    addTearDown(container.dispose);
    final controller = container.read(libraryFilterProvider.notifier);
    await expectLater(
      controller.savePreset(
        'Old',
        const LibraryFilter(),
        expectedGeneration: -1,
      ),
      throwsStateError,
    );
    expect(prefs.containsKey(LibraryFilterController.preferenceKey), false);
    final invalid = jsonEncode({
      'filter': const LibraryFilter().toJson(),
      'sorts': {},
      'presets': {'': {}},
    });
    await prefs.setString(LibraryFilterController.preferenceKey, invalid);
    await expectLater(
      controller.savePreset('New', const LibraryFilter()),
      throwsFormatException,
    );
    expect(prefs.getString(LibraryFilterController.preferenceKey), invalid);
    expect(() => BackupConfiguration.capture(prefs), throwsFormatException);
  });
}
