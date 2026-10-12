import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tachi_books/features/library/application/backup_activity.dart';
import 'package:tachi_books/features/library/data/backup_configuration.dart';
import 'package:tachi_books/features/library/data/backup_service.dart';
import 'package:tachi_books/features/library/data/library_repository.dart';
import 'package:tachi_books/features/library/domain/library_book.dart';
import 'package:tachi_books/features/library/presentation/library_view_model.dart';
import 'package:tachi_books/features/settings/settings_controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('only a successful Files save records time, export retains offline bytes and reader flags', () async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    final repo = MemoryLibraryRepository();
    await repo.insertBook(
      LibraryBook(
        id: 'offline',
        title: 'Offline',
        engine: 'local',
        progress: .4,
        chapters: const [
          BookChapter(id: 'chapter', title: 'One', index: 0, downloaded: true),
        ],
      ),
      contents: {
        0: ReaderContent(kind: 'novel', html: '<p>Full offline text</p>'),
      },
      expectedRevision: repo.replacementRevision,
    );
    Uint8List? bytes;
    String? name;
    var saved = false;
    final container = ProviderContainer(
      overrides: [
        preferencesProvider.overrideWithValue(preferences),
        libraryRepositoryProvider.overrideWithValue(repo),
        backupFileWriterProvider.overrideWithValue((filename, image) async {
          name = filename;
          bytes = image;
          return saved ? 'selected-path' : null;
        }),
      ],
    );
    addTearDown(container.dispose);
    final controller = container.read(backupActivityProvider.notifier);
    final now = DateTime(2026, 10, 11, 12, 30);
    expect(await controller.exportBackup(at: now), false);
    expect(container.read(backupActivityProvider).exportedAt, isNull);
    saved = true;
    expect(await controller.exportBackup(at: now), true);
    expect(name, 'tachibooks-2026-10-11.json');
    final target = MemoryLibraryRepository();
    await BackupService(target).merge(bytes!);
    expect(
      (await target.readChapter('offline', 0))!.html,
      '<p>Full offline text</p>',
    );
    expect((await target.find('offline'))!.progress, .4);
    final restarted = BackupActivity.decode(
      preferences.getString(BackupActivityController.key),
    );
    expect(restarted.exportedAt, now.toUtc());
    expect(
      BackupConfiguration.isPortableKey(BackupActivityController.key),
      false,
    );
  });
  test('writer error leaves last successful timestamp unchanged; parallel operations preserve both fields', () async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    final previous = DateTime.utc(2026, 10, 10);
    await preferences.setString(
      BackupActivityController.key,
      BackupActivity(exportedAt: previous).encode(),
    );
    final container = ProviderContainer(
      overrides: [
        preferencesProvider.overrideWithValue(preferences),
        libraryRepositoryProvider.overrideWithValue(MemoryLibraryRepository()),
        backupFileWriterProvider.overrideWithValue(
          (_, _) async => throw StateError('Files unavailable'),
        ),
      ],
    );
    addTearDown(container.dispose);
    final controller = container.read(backupActivityProvider.notifier);
    await expectLater(controller.exportBackup(), throwsStateError);
    expect(container.read(backupActivityProvider).exportedAt, previous);
    final restore = DateTime.utc(2026, 10, 11);
    await controller.restored(at: restore);
    expect(container.read(backupActivityProvider).exportedAt, previous);
    expect(container.read(backupActivityProvider).restoredAt, restore);
  });
}
