import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tachi_books/features/library/data/backup_configuration.dart';
import 'package:tachi_books/features/library/data/backup_service.dart';
import 'package:tachi_books/features/library/data/coordinated_preferences.dart';
import 'package:tachi_books/features/library/data/library_repository.dart';
import 'package:tachi_books/features/library/data/library_snapshot.dart';
import 'package:tachi_books/features/settings/settings_controller.dart';
import 'package:tachi_books/features/sources/domain/source_languages.dart';
import 'package:tachi_books/features/sources/presentation/source_languages_controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('all includes future languages; empty means none; untrusted backup is strict', () {
    expect(SourceLanguages.decode(null).allows('future'), true);
    final none = SourceLanguages.decode(const SourceLanguages({}).encode());
    expect(none.allows('vi'), false);
    for (final data in [
      {
        'version': 1,
        'enabled': ['vi', 'vi'],
      },
      {
        'version': 1,
        'enabled': [2],
      },
      {'version': 2, 'enabled': null},
      {
        'version': 1,
        'enabled': ['../vi'],
      },
    ]) {
      expect(
        () => BackupConfiguration.fromJson({
          'version': 1,
          'preferences': {'sourceLanguagesV1': jsonEncode(data)},
        }),
        throwsFormatException,
      );
    }
  });
  test('multiple languages persist and stale editor cannot override restored preference', () async {
    SharedPreferences.setMockInitialValues({});
    final repository = MemoryLibraryRepository();
    final prefs = await CoordinatedPreferences.open(
      await SharedPreferences.getInstance(),
      repository,
    );
    final container = ProviderContainer(
      overrides: [preferencesProvider.overrideWithValue(prefs)],
    );
    addTearDown(container.dispose);
    final editor = container.read(sourceLanguagesProvider.notifier);
    await editor.save(const SourceLanguages({'vi', 'en', 'vi_VN', 'all'}));
    final restarted = ProviderContainer(
      overrides: [preferencesProvider.overrideWithValue(prefs)],
    );
    addTearDown(restarted.dispose);
    expect(restarted.read(sourceLanguagesProvider).enabled, {
      'vi',
      'en',
      'vi_VN',
      'all',
    });
    expect(restarted.read(sourceLanguagesProvider).allows('ja'), false);
    final backup = BackupService(
      repository,
      configuration: AppConfigurationStore(prefs),
    );
    final old = await backup.export();
    final generation = prefs.mutationGeneration;
    final incoming = LibrarySnapshot(
      [],
      configuration: BackupConfiguration.fromJson({
        'version': 1,
        'preferences': {
          'sourceLanguagesV1': const SourceLanguages({'ja'}).encode(),
        },
      }),
    ).encode();
    await backup.replace(
      incoming,
      expectedFingerprint: backup.fingerprint(old),
    );
    await expectLater(
      editor.save(const SourceLanguages(null), expectedGeneration: generation),
      throwsStateError,
    );
    container.invalidate(sourceLanguagesProvider);
    expect(container.read(sourceLanguagesProvider).enabled, {'ja'});
    expect(
      SourceLanguages.decode(prefs.getString('sourceLanguagesV1')).enabled,
      {'ja'},
    );
  });
}
