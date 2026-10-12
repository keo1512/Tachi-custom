import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
// Used to inject persistence failures at the real plugin boundary.
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:tachi_books/features/library/data/library_repository.dart';
import 'package:tachi_books/features/library/domain/library_book.dart';
import 'package:tachi_books/features/library/domain/library_grouping.dart';
import 'package:tachi_books/features/library/presentation/library_category_controller.dart';
import 'package:tachi_books/features/library/presentation/library_filter_controller.dart';
import 'package:tachi_books/features/library/presentation/library_filter_sheet.dart';
import 'package:tachi_books/features/library/presentation/library_group_order_controller.dart';
import 'package:tachi_books/features/library/presentation/library_view_model.dart';
import 'package:tachi_books/features/settings/settings_controller.dart';

class FailingCategoryStore extends InMemorySharedPreferencesStore {
  FailingCategoryStore() : super.empty();
  String? failKey;
  Future<void> Function()? beforeFailure;
  @override
  Future<bool> setValue(String type, String key, Object value) async {
    if (key == failKey) {
      failKey = null;
      await beforeFailure?.call();
      return false;
    }
    return super.setValue(type, key, value);
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<(ProviderContainer, SharedPreferences, MemoryLibraryRepository)>
  fixture() async {
    final preferences = await SharedPreferences.getInstance();
    final repository = MemoryLibraryRepository();
    await repository.save(
      LibraryBook(id: 'a', title: 'A', categories: ['Old', 'Other']),
    );
    await repository.saveChapter(
      'a',
      0,
      ReaderContent(kind: 'novel', html: '<p>actual offline</p>'),
    );
    final container = ProviderContainer(
      overrides: [
        preferencesProvider.overrideWithValue(preferences),
        libraryRepositoryProvider.overrideWithValue(repository),
      ],
    );
    addTearDown(container.dispose);
    await container.read(libraryProvider.future);
    await preferences.setString(
      LibraryGroupOrderController.preferenceKey,
      jsonEncode({
        'collection': ['value:Other', 'value:Old'],
        'author': ['future author key'],
      }),
    );
    final filter = const LibraryFilter(
      category: 'Old',
      order: LibraryOrder.title,
      source: 'tachi:123',
      unread: LibraryTriState.include,
    ).toJson();
    filter['futureField'] = {'untouched': true};
    await preferences.setString(
      LibraryFilterController.preferenceKey,
      jsonEncode({
        'filter': {...filter},
        'sorts': {
          LibraryFilterPreferences.scope(
            LibraryGrouping.collection,
            'value:Old',
          ): {
            ...filter,
          },
          LibraryFilterPreferences.scope(
            LibraryGrouping.author,
            'value:Old',
          ): const LibraryFilter(order: LibraryOrder.total)
              .toJson(),
        },
        'futureTopLevel': [1, 2, 3],
      }),
    );
    return (container, preferences, repository);
  }

  test('rename preserves category position, scoped constraints, author scope and unknown fields', () async {
    final (container, preferences, repository) = await fixture();
    await container
        .read(libraryCategoriesProvider.notifier)
        .rename('Old', 'New', expectedRevision: repository.replacementRevision);
    expect(container.read(libraryGroupOrderProvider)['collection'], [
      'value:Other',
      'value:New',
    ]);
    final saved = container
        .read(libraryFilterProvider)
        .forGroup(LibraryGrouping.collection, 'value:New');
    expect(saved.category, 'New');
    expect(saved.order, LibraryOrder.title);
    expect(saved.source, 'tachi:123');
    expect(saved.unread, LibraryTriState.include);
    final json = jsonDecode(
      preferences.getString(LibraryFilterController.preferenceKey)!,
    ) as Map<String, dynamic>;
    expect(json['futureTopLevel'], [1, 2, 3]);
    expect((json['filter'] as Map)['futureField'], {'untouched': true});
    expect(
      container
          .read(libraryFilterProvider)
          .forGroup(LibraryGrouping.author, 'value:Old')
          .order,
      LibraryOrder.total,
    );
    expect((await repository.find('a'))!.categories, ['New', 'Other']);
  });

  test('delete removes only category keys and resets constraints naming the deleted category', () async {
    final (container, _, repository) = await fixture();
    await container
        .read(libraryCategoriesProvider.notifier)
        .remove('Old', expectedRevision: repository.replacementRevision);
    expect(container.read(libraryGroupOrderProvider)['collection'], [
      'value:Other',
    ]);
    expect(container.read(libraryFilterProvider).filter.category, 'Tất cả');
    expect(
      container
          .read(libraryFilterProvider)
          .sorts
          .containsKey(
            LibraryFilterPreferences.scope(
              LibraryGrouping.collection,
              'value:Old',
            ),
          ),
      isFalse,
    );
    expect(
      container
          .read(libraryFilterProvider)
          .forGroup(LibraryGrouping.author, 'value:Old')
          .order,
      LibraryOrder.total,
    );
  });

  for (final key in [
    LibraryFilterController.preferenceKey,
    LibraryCategoryController.preferenceKey,
  ]) {
    test(
      'failed write at $key rolls back exact raw prefs and keeps concurrent progress/cache',
      () async {
        final (container, preferences, repository) = await fixture();
        final originalStore = SharedPreferencesStorePlatform.instance;
        final failing = FailingCategoryStore();
        SharedPreferencesStorePlatform.instance = failing;
        addTearDown(
          () => SharedPreferencesStorePlatform.instance = originalStore,
        );
        final oldOrder = preferences.getString(
          LibraryGroupOrderController.preferenceKey,
        );
        final oldFilter = preferences.getString(
          LibraryFilterController.preferenceKey,
        );
        failing.failKey = 'flutter.$key';
        failing.beforeFailure = () => repository.mutateBook(
          'a',
          (latest) => latest.copyWith(progress: .8, bookmarks: ['0:0.8']),
        );
        await expectLater(
          container
              .read(libraryCategoriesProvider.notifier)
              .rename(
                'Old',
                'New',
                expectedRevision: repository.replacementRevision,
              ),
          throwsStateError,
        );
        expect(
          preferences.getString(LibraryGroupOrderController.preferenceKey),
          oldOrder,
        );
        expect(
          preferences.getString(LibraryFilterController.preferenceKey),
          oldFilter,
        );
        expect(
          preferences.get(LibraryCategoryController.preferenceKey),
          isNull,
        );
        final saved = (await repository.find('a'))!;
        expect(saved.categories, ['Old', 'Other']);
        expect(saved.progress, .8);
        expect(saved.bookmarks, ['0:0.8']);
        expect(
          (await repository.readChapter('a', 0))!.html,
          '<p>actual offline</p>',
        );
      },
    );
  }

  test(
    'corrupt filter input refuses migration before any book writes',
    () async {
      final (container, preferences, repository) = await fixture();
      final oldOrder = preferences.getString(
        LibraryGroupOrderController.preferenceKey,
      );
      await preferences.setString(
        LibraryFilterController.preferenceKey,
        '{keep invalid input',
      );
      await expectLater(
        container
            .read(libraryCategoriesProvider.notifier)
            .rename(
              'Old',
              'New',
              expectedRevision: repository.replacementRevision,
            ),
        throwsFormatException,
      );
      expect((await repository.find('a'))!.categories, ['Old', 'Other']);
      expect(
        preferences.getString(LibraryGroupOrderController.preferenceKey),
        oldOrder,
      );
      expect(
        preferences.getString(LibraryFilterController.preferenceKey),
        '{keep invalid input',
      );
    },
  );
}
