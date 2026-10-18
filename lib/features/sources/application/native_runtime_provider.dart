import 'dart:io';

import 'package:flutter/widgets.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/native_tachi_repository.dart';
import '../data/native_vbook_repository.dart';
import '../domain/catalogue.dart';
import '../domain/native_source_engine.dart';
import '../presentation/extension_catalogue_controller.dart';
import '../../settings/settings_controller.dart';
import '../../privacy/application/app_lock_controller.dart';
import '../../library/data/coordinated_preferences.dart';
import '../../library/presentation/library_view_model.dart';

typedef NativeRuntimeFactory = NativeSourceEngine Function();

/// Factories are separate so host tests can exercise the real lifetime owner.
final nativeRuntimeFactoriesProvider =
    Provider<Map<SourceEngine, NativeRuntimeFactory>>((ref) {
      if (!Platform.isIOS) return const {};
      var coverCacheEpoch = 0;
      ref.listen(
        settingsProvider.select((s) => s.incognitoMode),
        (_, _) => coverCacheEpoch++,
      );
      return {
        SourceEngine.vbook: NativeVbookRepository.new,
        SourceEngine.tachimanga: () => NativeTachiRepository(
          automaticallyVerifyChallenges: true,
          canVerifyChallenge: () {
            final lock = ref.read(appLockProvider);
            final lifecycle = WidgetsBinding.instance.lifecycleState;
            return (lifecycle == null ||
                    lifecycle == AppLifecycleState.resumed) &&
                lock.initialized &&
                lock.configurationValid &&
                !lock.authenticating &&
                !lock.locked &&
                !lock.obscured;
          },
          browserSessionRevision: () {
            final preferences = ref.read(preferencesProvider);
            return (
              ref.read(libraryRepositoryProvider).replacementRevision,
              preferences is CoordinatedPreferences
                  ? preferences.mutationGeneration
                  : 0,
            );
          },
          canCacheCover: () => !ref.read(settingsProvider).incognitoMode,
          coverCacheEpoch: () => coverCacheEpoch,
          iconForPackage: (packageUrl) {
            final indexes = ref.read(extensionCatalogueProvider).value;
            for (final index in indexes ?? []) {
              for (final entry in index.entries) {
                if (entry.engine == SourceEngine.tachimanga &&
                    entry.packageUrl == packageUrl) {
                  return entry.iconUrl;
                }
              }
            }
            return '';
          },
        ),
      };
    });

/// Installed on-device runtimes belong to the app container, not a companion
/// URL's routing wrapper. Backup/recovery still need them while routing uses an
/// external server, and settings restoration must not close their clients.
final nativeSourceRuntimesProvider =
    Provider<Map<SourceEngine, NativeSourceEngine>>((ref) {
      final factories = ref.read(nativeRuntimeFactoriesProvider);
      final runtimes = Map<SourceEngine, NativeSourceEngine>.unmodifiable({
        for (final entry in factories.entries) entry.key: entry.value(),
      });
      ref.onDispose(() {
        for (final runtime in runtimes.values.toSet()) {
          runtime.dispose();
        }
      });
      return runtimes;
    });
