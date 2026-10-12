import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tachi_books/features/library/data/library_repository.dart';
import 'package:tachi_books/features/library/domain/library_book.dart';
import 'package:tachi_books/features/library/domain/library_categories.dart';
import 'package:tachi_books/features/library/presentation/library_categories_screen.dart';
import 'package:tachi_books/features/library/presentation/library_category_controller.dart';
import 'package:tachi_books/features/library/presentation/library_view_model.dart';
import 'package:tachi_books/features/settings/settings_controller.dart';

class PausedCategoryRepository extends MemoryLibraryRepository {
  final started = Completer<void>();
  final release = Completer<void>();
  bool pause = false;

  @override
  Future<int> mutateBooks(
    Iterable<String> ids,
    LibraryBook Function(LibraryBook) transform, {
    int? expectedRevision,
  }) async {
    if (pause) {
      pause = false;
      started.complete();
      await release.future;
    }
    return super.mutateBooks(
      ids,
      transform,
      expectedRevision: expectedRevision,
    );
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<ProviderContainer> containerFor(
    MemoryLibraryRepository repository,
  ) async {
    final preferences = await SharedPreferences.getInstance();
    final container = ProviderContainer(
      overrides: [
        libraryRepositoryProvider.overrideWithValue(repository),
        preferencesProvider.overrideWithValue(preferences),
      ],
    );
    addTearDown(container.dispose);
    await container.read(libraryProvider.future);
    return container;
  }

  test(
    'empty categories, defaults and inclusion policies persist across restart',
    () async {
      final repository = MemoryLibraryRepository();
      final container = await containerFor(repository);
      final controller = container.read(libraryCategoriesProvider.notifier);
      await Future.wait([
        controller.create('Empty A'),
        controller.create('Empty B'),
      ]);
      await controller.setDefaults(['Empty A', 'Empty B']);
      await controller.setPolicy(
        'Empty A',
        update: CategoryPolicy.include,
        download: CategoryPolicy.include,
      );
      container.invalidate(libraryCategoriesProvider);
      final registry = container.read(libraryCategoriesProvider);
      expect(registry.defaultCategories, ['Empty A', 'Empty B']);
      expect(libraryCategoryGroups([], registry).map((group) => group.label), [
        'Empty A',
        'Empty B',
      ]);
      expect(
        libraryCategoryGroups(
          [],
          registry,
        ).every((group) => group.bookIds.isEmpty),
        isTrue,
      );
      expect(registry.policyFor('Empty A').download, CategoryPolicy.include);
    },
  );

  test('exclude policies win over includes without silently enabling automatic downloads', () {
    final registry = LibraryCategoryRegistry(
      categories: const [
        LibraryCategory(
          name: 'Allowed',
          update: CategoryPolicy.include,
          download: CategoryPolicy.include,
        ),
        LibraryCategory(
          name: 'Excluded',
          update: CategoryPolicy.exclude,
          download: CategoryPolicy.exclude,
        ),
      ],
    );
    final allowed = LibraryBook(id: 'a', title: 'A', categories: ['Allowed']);
    final excluded = allowed.copyWith(categories: ['Allowed', 'Excluded']);
    final other = allowed.copyWith(categories: ['Other']);
    expect(registry.allowsUpdate(allowed), isTrue);
    expect(registry.allowsAutoDownload(allowed), isTrue);
    expect(registry.allowsUpdate(excluded), isFalse);
    expect(registry.allowsAutoDownload(excluded), isFalse);
    expect(registry.allowsUpdate(other), isFalse);
    expect(registry.allowsAutoDownload(other), isFalse);
    expect(LibraryCategoryRegistry().allowsUpdate(other), isTrue);
    expect(LibraryCategoryRegistry().allowsAutoDownload(other), isFalse);
  });

  test('rename keeps other memberships, current progress, offline content and defaults', () async {
    final repository = PausedCategoryRepository();
    await repository.save(
      LibraryBook(
        id: 'a',
        title: 'A',
        categories: ['Old', 'Other'],
        readerPreferences: {'fontSize': 20},
        chapters: const [
          BookChapter(
            id: 'c',
            title: 'C',
            index: 0,
            downloaded: true,
            read: true,
          ),
        ],
      ),
    );
    await repository.saveChapter(
      'a',
      0,
      ReaderContent(kind: 'novel', html: '<p>offline bytes</p>'),
    );
    final container = await containerFor(repository);
    final controller = container.read(libraryCategoriesProvider.notifier);
    await controller.setDefaults(['Old']);
    await controller.setPolicy('Old', download: CategoryPolicy.include);
    repository.pause = true;
    final pending = controller.rename(
      'Old',
      'New',
      expectedRevision: repository.replacementRevision,
    );
    await repository.started.future;
    await repository.mutateBook(
      'a',
      (book) => book.copyWith(progress: .7, bookmarks: ['0:0.5']),
    );
    repository.release.complete();
    expect(await pending, 1);
    final saved = (await repository.find('a'))!;
    expect(saved.categories, ['New', 'Other']);
    expect(saved.collection, 'New');
    expect(saved.progress, .7);
    expect(saved.bookmarks, ['0:0.5']);
    expect(saved.readerPreferences, {'fontSize': 20});
    expect(saved.chapters.single.downloaded, isTrue);
    expect(
      (await repository.readChapter('a', 0))!.html,
      '<p>offline bytes</p>',
    );
    expect(container.read(libraryCategoriesProvider).defaultCategories, [
      'New',
    ]);
    expect(
      container.read(libraryCategoriesProvider).policyFor('New').download,
      CategoryPolicy.include,
    );
  });

  test('remove retains every title and only moves titles with no other membership to default', () async {
    final repository = MemoryLibraryRepository();
    await repository.save(
      LibraryBook(id: 'a', title: 'A', categories: ['Delete', 'Keep']),
    );
    await repository.save(
      LibraryBook(id: 'b', title: 'B', categories: ['Delete']),
    );
    final container = await containerFor(repository);
    final controller = container.read(libraryCategoriesProvider.notifier);
    await controller.setDefaults(['Delete']);
    expect(
      await controller.remove(
        'Delete',
        expectedRevision: repository.replacementRevision,
      ),
      2,
    );
    expect((await repository.find('a'))!.categories, ['Keep']);
    expect((await repository.find('b'))!.categories, ['Mặc định']);
    expect(await repository.list(), hasLength(2));
    expect(
      container.read(libraryCategoriesProvider).defaultCategories,
      isEmpty,
    );
    expect(
      container
          .read(libraryCategoriesProvider)
          .categories
          .any((category) => category.name == 'Delete'),
      isFalse,
    );
  });

  test('rename started before restore cannot change a replacement title or registry', () async {
    final repository = PausedCategoryRepository();
    await repository.save(
      LibraryBook(id: 'a', title: 'Old title', categories: ['Old']),
    );
    final container = await containerFor(repository);
    final controller = container.read(libraryCategoriesProvider.notifier);
    await controller.setDefaults(['Old']);
    final before = container.read(libraryCategoriesProvider).toJson();
    repository.pause = true;
    final pending = controller.rename(
      'Old',
      'Stale name',
      expectedRevision: repository.replacementRevision,
    );
    final failure = expectLater(pending, throwsStateError);
    await repository.started.future;
    await repository.clear();
    final restored = LibraryBook(
      id: 'a',
      title: 'Restored',
      categories: ['Restored shelf'],
    );
    await repository.save(restored);
    repository.release.complete();
    await failure;
    expect((await repository.find('a'))!.toJson(), restored.toJson());
    expect(container.read(libraryCategoriesProvider).toJson(), before);
  });

  test('reserved duplicate names and invalid registry fail without replacing stored inputs', () async {
    final repository = MemoryLibraryRepository();
    final container = await containerFor(repository);
    final controller = container.read(libraryCategoriesProvider.notifier);
    await controller.create('Saved');
    await expectLater(controller.create('Saved'), throwsFormatException);
    await expectLater(controller.create('Tất cả'), throwsFormatException);
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(
      LibraryCategoryController.preferenceKey,
      '{corrupt',
    );
    container.invalidate(libraryCategoriesProvider);
    expect(container.read(libraryCategoriesProvider).categories, isEmpty);
    await expectLater(
      container.read(libraryCategoriesProvider.notifier).create('New'),
      throwsFormatException,
    );
    expect(
      preferences.getString(LibraryCategoryController.preferenceKey),
      '{corrupt',
    );
  });

  for (final width in [320.0, 430.0]) {
    testWidgets(
      'empty-category creation and default selection work at $width',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = Size(width, 932);
        addTearDown(tester.view.reset);
        final repository = MemoryLibraryRepository();
        final preferences = await SharedPreferences.getInstance();
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              libraryRepositoryProvider.overrideWithValue(repository),
              preferencesProvider.overrideWithValue(preferences),
            ],
            child: const MaterialApp(home: LibraryCategoriesScreen()),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Tạo danh mục'));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const ValueKey('category-name')),
          'Empty shelf',
        );
        await tester.tap(find.text('Lưu'));
        await tester.pumpAndSettle();
        expect(find.text('Empty shelf'), findsOneWidget);
        expect(find.text('0 truyện'), findsOneWidget);
        await tester.tap(
          find.byKey(const ValueKey('category-settings-Empty shelf')),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Mặc định khi thêm truyện'));
        await tester.pumpAndSettle();
        final container = ProviderScope.containerOf(
          tester.element(find.byType(LibraryCategoriesScreen)),
        );
        expect(container.read(libraryCategoriesProvider).defaultCategories, [
          'Empty shelf',
        ]);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      },
    );
  }
}
