import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../library/data/coordinated_preferences.dart';
import '../../library/presentation/library_folders_controller.dart';
import '../../library/presentation/library_view_model.dart';
import '../../settings/settings_controller.dart';
import '../domain/source_migration.dart';

/// Production migration shares the same durable library/configuration restore
/// boundary as backup. Plain test/legacy stores retain the library-only API.
final sourceMigrationProvider = Provider<SourceMigration>((ref) {
  final preferences = ref.read(preferencesProvider);
  return SourceMigration(
    ref.read(libraryRepositoryProvider),
    configuration: preferences is CoordinatedPreferences
        ? AppConfigurationStore(preferences)
        : null,
    onConfigurationChanged: () {
      if (ref.mounted) ref.invalidate(libraryFoldersProvider);
    },
  );
});
