import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../downloads/presentation/download_deletion_controller.dart';
import '../../reader/presentation/reader_options_controller.dart';
import '../../settings/settings_controller.dart';
import '../../settings/navigation_preferences.dart';
import '../../sources/presentation/extension_catalogue_controller.dart';
import '../../sources/presentation/source_filter_presets.dart';
import '../../sources/presentation/source_languages_controller.dart';
import '../../tasks/application/task_notifications.dart';
import '../data/backup_service.dart';
import '../data/coordinated_preferences.dart';
import '../data/extension_backup_store.dart';
import '../../sources/data/on_device_source_repository.dart';
import '../../sources/application/native_runtime_provider.dart';
import '../../sources/domain/native_source_engine.dart';
import '../presentation/library_category_controller.dart';
import '../presentation/library_filter_controller.dart';
import '../presentation/library_group_order_controller.dart';
import '../presentation/library_grouping_controller.dart';
import '../presentation/library_view_model.dart';
import 'automatic_backup_controller.dart';
import 'library_update_policy.dart';
import 'extension_recovery_controller.dart';
import '../../privacy/application/app_lock_controller.dart';

final backupServiceProvider = Provider<BackupService>((ref) {
  final preferences = ref.read(preferencesProvider);
  final repository = ref.read(libraryRepositoryProvider);
  final runtimes = ref.read(nativeSourceRuntimesProvider);
  final engines = runtimes.entries
      .where((entry) => entry.value is NativeExtensionBackupEngine)
      .map((entry) => entry.key)
      .toSet();
  final sources = engines.isEmpty
      ? null
      : OnDeviceSourceRepository(
          tachimangaUrl: '',
          vbookUrl: '',
          runtimes: runtimes,
          ownsRuntimes: false,
        );
  if (sources != null) ref.onDispose(sources.dispose);
  return BackupService(
    repository,
    extensions: sources != null
        ? RepositoryExtensionBackupStore(
            runtime: sources,
            repository: repository,
            engines: engines,
          )
        : null,
    configuration: preferences is CoordinatedPreferences
        ? AppConfigurationStore(preferences)
        : null,
    onExtensionRestoreIncomplete: (error, stack) {
      if (ref.mounted) {
        ref.invalidate(libraryProvider);
        ref
            .read(extensionRecoveryProvider.notifier)
            .reportIncomplete(error, stack);
      }
    },
    beforeExport: () async {
      await ref.read(appLockProvider.notifier).initialize();
      await ref.read(extensionRecoveryProvider.future);
    },
    exportGuard: () {
      final lock = ref.read(appLockProvider);
      final recovery = ref.read(extensionRecoveryProvider);
      if (!lock.initialized || lock.locked || !lock.configurationValid) {
        throw StateError('Mở khóa ứng dụng trước khi sao lưu.');
      }
      if (recovery.isLoading || recovery.hasError) {
        throw StateError(
          'Còn phục hồi extension chưa hoàn tất. Mở Sao lưu & Khôi phục và thử lại.',
        );
      }
    },
    onConfigurationRestored: () {
      if (!ref.mounted) return;
      // A settings screen already open on this device must show the restored
      // values. Invalidation also prevents a pending old controller write.
      ref.invalidate(settingsProvider);
      ref.invalidate(navigationPreferencesProvider);
      ref.invalidate(readerOptionsProvider);
      ref.invalidate(libraryCategoriesProvider);
      ref.invalidate(libraryFilterProvider);
      ref.invalidate(libraryGroupOrderProvider);
      ref.invalidate(libraryGroupingProvider);
      ref.invalidate(extensionCatalogueProvider);
      ref.invalidate(sourceFilterPresetsProvider);
      ref.invalidate(sourceLanguagesProvider);
      ref.invalidate(libraryUpdatePolicyProvider);
      ref.invalidate(downloadDeletionProvider);
      ref.invalidate(automaticBackupPolicyProvider);
      ref.invalidate(taskNotificationsProvider);
    },
  );
});

final configurationChangesProvider = StreamProvider<int>((ref) async* {
  final preferences = ref.watch(preferencesProvider);
  if (preferences is CoordinatedPreferences) {
    yield preferences.changeRevision;
    yield* preferences.changes;
  }
});
