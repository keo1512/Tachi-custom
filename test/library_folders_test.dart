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
import 'package:tachi_books/features/settings/settings_controller.dart';

void main() {
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
