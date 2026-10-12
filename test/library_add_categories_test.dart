import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tachi_books/core/theme/app_theme.dart';
import 'package:tachi_books/features/library/data/library_repository.dart';
import 'package:tachi_books/features/library/domain/library_book.dart';
import 'package:tachi_books/features/library/domain/library_categories.dart';
import 'package:tachi_books/features/library/presentation/library_add_categories.dart';
import 'package:tachi_books/features/library/presentation/library_category_controller.dart';
import 'package:tachi_books/features/library/presentation/library_view_model.dart';
import 'package:tachi_books/features/settings/settings_controller.dart';
import 'package:tachi_books/features/sources/data/source_repository.dart';
import 'package:tachi_books/features/sources/domain/catalogue.dart';

const _item = CatalogueBook(
  ref: 'https://example.test/story',
  title: 'Tên truyện thật từ nguồn',
  sourceId: '9223372036854775807',
  kind: ContentKind.manga,
  engine: SourceEngine.tachimanga,
);

class _Source extends SourceRepository {
  _Source() : super(tachimangaUrl: '', vbookUrl: '');
  int details = 0;
  Completer<void>? release;
  final started = Completer<void>();
  @override
  Future<CatalogueBook> detail(CatalogueBook item) async {
    details++;
    if (!started.isCompleted) started.complete();
    await release?.future;
    return item;
  }

  @override
  Future<List<CatalogueChapter>> chapters(CatalogueBook item) async => const [
    CatalogueChapter(ref: '/c1', title: 'Chương 1', index: 0),
  ];
}

class _Fixture {
  _Fixture(this.repo, this.source, this.preferences);
  final MemoryLibraryRepository repo;
  final _Source source;
  final SharedPreferences preferences;
  LibraryBook? result;
  Object? error;
  late ProviderContainer container;
}

Future<_Fixture> _mount(
  WidgetTester tester, {
  Size size = const Size(430, 932),
  bool paused = false,
  bool categories = true,
  MemoryLibraryRepository? repository,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);
  final preferences = await SharedPreferences.getInstance();
  if (categories) {
    await preferences.setString(
      'libraryCategoriesV1',
      jsonEncode(
        LibraryCategoryRegistry(
          categories: const [
            LibraryCategory(name: 'Bộ truyện'),
            LibraryCategory(name: 'Tác giả'),
          ],
          defaultCategories: const ['Bộ truyện'],
        ).toJson(),
      ),
    );
  }
  final source = _Source();
  if (paused) source.release = Completer<void>();
  final fixture = _Fixture(
    repository ?? MemoryLibraryRepository(),
    source,
    preferences,
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        preferencesProvider.overrideWithValue(preferences),
        libraryRepositoryProvider.overrideWithValue(fixture.repo),
        sourceRepositoryProvider.overrideWithValue(source),
      ],
      child: MaterialApp(
        theme: appTheme(Brightness.dark),
        home: Consumer(
          builder: (context, ref, _) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () async {
                  try {
                    fixture.result = await addCatalogueBookWithCategories(
                      context,
                      ref,
                      _item,
                      sourceName: 'Nguồn thử nghiệm',
                    );
                  } catch (error) {
                    fixture.error = error;
                  }
                },
                child: const Text('Thêm từ nguồn'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  fixture.container = ProviderScope.containerOf(
    tester.element(find.byType(Consumer)),
  );
  await fixture.container.read(libraryProvider.future);
  await tester.pumpAndSettle();
  return fixture;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  for (final size in const [Size(320, 568), Size(430, 932)]) {
    testWidgets(
      'source add chooses multiple categories at $size before fetching',
      (tester) async {
        final fixture = await _mount(tester, size: size);
        await tester.tap(find.text('Thêm từ nguồn'));
        await tester.pumpAndSettle();
        expect(find.text('Thêm vào danh mục'), findsOneWidget);
        expect(fixture.source.details, 0);
        await tester.tap(find.byKey(const ValueKey('add-category-Tác giả')));
        await tester.tap(find.byKey(const ValueKey('confirm-add-categories')));
        await tester.pumpAndSettle();
        expect(fixture.error, isNull);
        expect(fixture.result!.categories, ['Bộ truyện', 'Tác giả']);
        expect(fixture.result!.sourceName, 'Nguồn thử nghiệm');
        expect(fixture.result!.sourceId, '9223372036854775807');
        expect(fixture.source.details, 1);
        expect((await fixture.repo.list()).single.categories, [
          'Bộ truyện',
          'Tác giả',
        ]);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('cancel does not request the source or add a title', (
    tester,
  ) async {
    final fixture = await _mount(tester);
    final before = (await fixture.repo.snapshot()).encode();
    await tester.tap(find.text('Thêm từ nguồn'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Hủy'));
    await tester.pumpAndSettle();
    expect(fixture.result, isNull);
    expect(fixture.source.details, 0);
    expect((await fixture.repo.snapshot()).encode(), before);
  });

  testWidgets('unselecting defaults adds to the legacy Mặc định category', (
    tester,
  ) async {
    final fixture = await _mount(tester);
    await tester.tap(find.text('Thêm từ nguồn'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('add-category-Bộ truyện')));
    await tester.tap(find.byKey(const ValueKey('confirm-add-categories')));
    await tester.pumpAndSettle();
    expect(fixture.result!.categories, ['Mặc định']);
  });

  testWidgets(
    'replacement while the category sheet is open cannot add a stale title',
    (tester) async {
      final fixture = await _mount(tester);
      await tester.tap(find.text('Thêm từ nguồn'));
      await tester.pumpAndSettle();
      await fixture.repo.clear();
      await fixture.repo.save(
        LibraryBook(id: 'restored', title: 'Giữ bản khôi phục'),
      );
      final restored = (await fixture.repo.snapshot()).encode();
      await tester.tap(find.byKey(const ValueKey('confirm-add-categories')));
      await tester.pumpAndSettle();
      expect(fixture.error, isA<StateError>());
      expect(fixture.source.details, 0);
      expect((await fixture.repo.snapshot()).encode(), restored);
    },
  );

  testWidgets(
    'a category removed during the source request cannot be recreated by insertion',
    (tester) async {
      final fixture = await _mount(tester, paused: true);
      await tester.tap(find.text('Thêm từ nguồn'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('confirm-add-categories')));
      await tester.pumpAndSettle();
      expect(fixture.source.details, 1);
      await fixture.preferences.setString(
        'libraryCategoriesV1',
        jsonEncode(LibraryCategoryRegistry().toJson()),
      );
      fixture.container.invalidate(libraryCategoriesProvider);
      fixture.source.release!.complete();
      await tester.pumpAndSettle();
      expect(fixture.error, isA<StateError>());
      expect(await fixture.repo.list(), isEmpty);
      expect(fixture.result, isNull);
    },
  );

  testWidgets(
    'without custom categories the existing quick-add flow is preserved',
    (tester) async {
      final fixture = await _mount(tester, categories: false);
      await tester.tap(find.text('Thêm từ nguồn'));
      await tester.pumpAndSettle();
      expect(find.text('Thêm vào danh mục'), findsNothing);
      expect(fixture.result!.categories, ['Mặc định']);
      final saved = fixture.result!.copyWith(
        notes: 'Giữ ghi chú',
        favorite: true,
      );
      await fixture.repo.save(saved);
      await tester.tap(find.text('Thêm từ nguồn'));
      await tester.pumpAndSettle();
      expect(fixture.source.details, 1);
      expect(fixture.result!.toJson(), saved.toJson());
    },
  );

  testWidgets(
    'category removal queued during insertion sees and removes the new membership',
    (tester) async {
      final repository = _HeldInsertRepository();
      final fixture = await _mount(tester, repository: repository);
      await tester.tap(find.text('Thêm từ nguồn'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('confirm-add-categories')));
      await tester.pumpAndSettle();
      expect(repository.started.isCompleted, true);
      final removal = fixture.container
          .read(libraryCategoriesProvider.notifier)
          .remove(
            'Bộ truyện',
            expectedRevision: repository.replacementRevision,
          );
      await tester.pump();
      repository.release.complete();
      await removal;
      await tester.pumpAndSettle();
      expect(fixture.error, isNull);
      expect((await repository.list()).single.categories, ['Mặc định']);
      expect(
        fixture.container
            .read(libraryCategoriesProvider)
            .categories
            .any((c) => c.name == 'Bộ truyện'),
        false,
      );
      expect(tester.takeException(), isNull);
    },
  );
}

class _HeldInsertRepository extends MemoryLibraryRepository {
  final started = Completer<void>();
  final release = Completer<void>();
  @override
  Future<LibraryBook> insertBook(
    LibraryBook book, {
    Map<int, ReaderContent> contents = const {},
    required int expectedRevision,
  }) async {
    started.complete();
    await release.future;
    return super.insertBook(
      book,
      contents: contents,
      expectedRevision: expectedRevision,
    );
  }
}
