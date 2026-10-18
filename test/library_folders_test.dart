import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tachi_books/features/library/data/backup_configuration.dart';
import 'package:tachi_books/features/library/data/coordinated_preferences.dart';
import 'package:tachi_books/features/library/data/library_repository.dart';
import 'package:tachi_books/features/library/domain/library_book.dart';
import 'package:tachi_books/features/library/domain/library_folders.dart';
import 'package:tachi_books/features/library/domain/library_grouping.dart';
import 'package:tachi_books/features/library/presentation/library_folders_controller.dart';
import 'package:tachi_books/features/library/presentation/library_view_model.dart';
import 'package:tachi_books/features/library/presentation/library_category_preference_migration.dart';
import 'package:tachi_books/features/settings/settings_controller.dart';

void main() {
  test('category folder overrides retain legacy data and migrate IDs without overwriting orphan assignment', () {
    final folders = LibraryFolders(
      {'a': 'Legacy'},
      {
        'Manga': {'a': 'Manga folder'},
        'Novel': {'a': null},
      },
    );
    final roundtrip = LibraryFolders.decodeWithCategories(
      folders.encode(),
      folders.encodeCategories(),
    );
    expect(roundtrip.namesIn('Manga'), {'a': 'Manga folder'});
    expect(roundtrip.namesIn('Novel'), isEmpty);
    expect(roundtrip.namesIn('Favorites'), {'a': 'Legacy'});
    final moved = roundtrip.migrateBookIds({'a': 'b'}, replaceOld: true);
    expect(moved.namesIn('Manga'), {'b': 'Manga folder'});
    expect(moved.namesIn('Novel'), isEmpty);
    expect(moved.categoryNames['Novel'], {'b': null});
    expect(
      roundtrip.migrateBookIds({'a': 'b'}, replaceOld: false).namesIn('Manga'),
      {'a': 'Manga folder', 'b': 'Manga folder'},
    );
    expect(
      () =>
          LibraryFolders({'a': 'Old', 'b': 'Other'})
              .migrateBookIds({'a': 'b'}, replaceOld: true),
      throwsStateError,
    );
  });
  test('same title has independent folders per category and rename rollback preserves scopes', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final repo = MemoryLibraryRepository();
    await repo.save(
      LibraryBook(id: 'a', title: 'A', categories: ['Manga', 'Novel']),
    );
    final container = ProviderContainer(
      overrides: [
        preferencesProvider.overrideWithValue(prefs),
        libraryRepositoryProvider.overrideWithValue(repo),
      ],
    );
    addTearDown(container.dispose);
    final controller = container.read(libraryFoldersProvider.notifier);
    final revision = repo.replacementRevision;
    final before = (await repo.snapshot()).fingerprint;
    await controller.assign(
      ['a'],
      'M',
      expectedRevision: revision,
      category: 'Manga',
    );
    await controller.assign(
      ['a'],
      'N',
      expectedRevision: revision,
      category: 'Novel',
    );
    expect(container.read(libraryFoldersProvider).namesIn('Manga'), {'a': 'M'});
    expect(container.read(libraryFoldersProvider).namesIn('Novel'), {'a': 'N'});
    await controller.assign(
      ['a'],
      null,
      expectedRevision: revision,
      category: 'Manga',
    );
    expect(container.read(libraryFoldersProvider).namesIn('Manga'), isEmpty);
    expect(container.read(libraryFoldersProvider).namesIn('Novel'), {'a': 'N'});
    final migration = LibraryCategoryPreferenceMigration.prepare(
      prefs,
      'Novel',
      'Books',
    );
    final raw = prefs.getString(LibraryFolders.categoryPreferenceKey);
    await migration.apply();
    expect(
      LibraryFolders.decodeWithCategories(
        null,
        prefs.getString(LibraryFolders.categoryPreferenceKey),
      ).namesIn('Books'),
      {'a': 'N'},
    );
    await migration.rollback();
    expect(prefs.getString(LibraryFolders.categoryPreferenceKey), raw);
    expect((await repo.snapshot()).fingerprint, before);
    expect(
      BackupConfiguration.capture(prefs).values
          .containsKey(LibraryFolders.categoryPreferenceKey),
      true,
    );
  });
  test('automatic folders stay within category; singles and missing authors stay loose', () {
    final books = [
      LibraryBook(
        id: 'a',
        title: 'Grand Blue',
        author: 'Same',
        categories: ['Manga'],
      ),
      LibraryBook(
        id: 'b',
        title: 'Blue Box',
        author: ' SAME ',
        categories: ['Manga'],
      ),
      LibraryBook(
        id: 'c',
        title: 'Novel',
        author: 'Same',
        categories: ['Novel'],
      ),
      LibraryBook(id: 'd', title: 'Unknown', categories: ['Manga']),
    ];
    final folders = LibraryFolders().groups(
      books.where((b) => b.categories.contains('Manga')),
      LibraryGrouping.author,
    );
    expect(folders.single.bookIds, {'a', 'b'});
    expect(folders.single.label, 'Same');
    expect(
      LibraryFolders().groups([books[2]], LibraryGrouping.author),
      isEmpty,
    );
    final manual = LibraryFolders({'a': 'My folder', 'd': 'My folder'});
    final result = manual.groups(books, LibraryGrouping.author);
    expect(result.firstWhere((g) => g.key == 'folder:My folder').bookIds, {
      'a',
      'd',
    });
    expect(result.firstWhere((g) => g.key == 'value:same').bookIds, {'b', 'c'});
  });

  test('manual folders preserve all book metadata and portable configuration; stale restore refused', () async {
    SharedPreferences.setMockInitialValues({});
    final rawPreferences = await SharedPreferences.getInstance();
    final repository = MemoryLibraryRepository();
    final preferences = await CoordinatedPreferences.open(
      rawPreferences,
      repository,
    );
    await repository.save(
      LibraryBook(
        id: 'a',
        title: 'A',
        author: 'Original',
        categories: ['Manga'],
      ),
    );
    await repository.save(
      LibraryBook(id: 'b', title: 'B', categories: ['Manga', 'Favorites']),
    );
    final before = (await repository.snapshot()).fingerprint;
    final container = ProviderContainer(
      overrides: [
        preferencesProvider.overrideWithValue(preferences),
        libraryRepositoryProvider.overrideWithValue(repository),
      ],
    );
    addTearDown(container.dispose);
    await container.read(libraryProvider.future);
    final controller = container.read(libraryFoldersProvider.notifier);
    final revision = repository.replacementRevision;
    await controller.assign(['a', 'b'], 'Custom', expectedRevision: revision);
    expect((await repository.snapshot()).fingerprint, before);
    final restored = BackupConfiguration.fromJson(
      BackupConfiguration.capture(preferences).toJson(),
    );
    expect(
      LibraryFolders.decode(
        restored.values[LibraryFolders.preferenceKey] as String,
      ).names,
      {'a': 'Custom', 'b': 'Custom'},
    );
    await controller.assign(['a', 'b'], null, expectedRevision: revision);
    expect(
      jsonDecode(preferences.getString(LibraryFolders.preferenceKey)!),
      isEmpty,
    );
    await repository.clear();
    await repository.save(LibraryBook(id: 'a', title: 'Replacement'));
    await expectLater(
      controller.assign(['a'], 'Stale', expectedRevision: revision),
      throwsStateError,
    );
    expect(
      jsonDecode(preferences.getString(LibraryFolders.preferenceKey)!),
      isEmpty,
    );
  });

  test('folder configuration rejects corrupt memberships instead of overwriting them', () {
    for (final raw in ['[]', '{"a":0}', '{"a":" "}', '{"":"name"}']) {
      expect(() => LibraryFolders.decode(raw), throwsFormatException);
    }
  });
}
