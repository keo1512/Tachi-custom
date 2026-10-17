import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tachi_books/core/theme/app_theme.dart';
import 'package:tachi_books/features/library/data/library_repository.dart';
import 'package:tachi_books/features/library/domain/library_book.dart';
import 'package:tachi_books/features/library/domain/library_grouping.dart';
import 'package:tachi_books/features/library/presentation/library_group_order_controller.dart';
import 'package:tachi_books/features/library/presentation/library_group_order_sheet.dart';
import 'package:tachi_books/features/library/presentation/library_screen.dart';
import 'package:tachi_books/features/library/presentation/library_view_model.dart';
import 'package:tachi_books/features/settings/settings_controller.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'saved identities retain absent groups and order the new groups last',
    () {
      final books = [
        LibraryBook(id: '1', title: 'First', collection: '..'),
        LibraryBook(id: '2', title: 'Second', collection: 'manga'),
        LibraryBook(id: '3', title: 'New', collection: 'a new shelf'),
      ];
      final before = books.map((book) => book.toJson()).toList();
      final ordered = orderLibraryGroups(
        libraryGroups(books, LibraryGrouping.collection),
        ['value:removed', 'value:manga', 'value:manga', 'value:..'],
      );
      expect(ordered.map((group) => group.label), [
        'manga',
        '..',
        'a new shelf',
      ]);
      expect(ordered.first.bookIds, {'2'});
      expect(books.map((book) => book.toJson()).toList(), before);
    },
  );

  test(
    'separate orders survive restart and simultaneous preference writes',
    () async {
      final preferences = await SharedPreferences.getInstance();
      final container = ProviderContainer(
        overrides: [preferencesProvider.overrideWithValue(preferences)],
      );
      addTearDown(container.dispose);
      final controller = container.read(libraryGroupOrderProvider.notifier);
      await Future.wait([
        controller.setOrder(LibraryGrouping.collection, [
          'value:manga',
          'value:..',
        ]),
        controller.setOrder(LibraryGrouping.author, [
          'value:author b',
          'value:author a',
        ]),
      ]);
      await controller.setOrder(LibraryGrouping.collection, ['value:..']);
      container.invalidate(libraryGroupOrderProvider);
      final order = container.read(libraryGroupOrderProvider);
      expect(order['collection'], ['value:..', 'value:manga']);
      expect(order['author'], ['value:author b', 'value:author a']);
    },
  );

  test('malformed stored order is preserved and a save does not silently replace it', () async {
    SharedPreferences.setMockInitialValues({
      LibraryGroupOrderController.preferenceKey: '{corrupt',
    });
    final preferences = await SharedPreferences.getInstance();
    final container = ProviderContainer(
      overrides: [preferencesProvider.overrideWithValue(preferences)],
    );
    addTearDown(container.dispose);
    expect(container.read(libraryGroupOrderProvider), isEmpty);
    await expectLater(
      container.read(libraryGroupOrderProvider.notifier).setOrder(
        LibraryGrouping.collection,
        ['value:manga'],
      ),
      throwsFormatException,
    );
    expect(
      preferences.getString(LibraryGroupOrderController.preferenceKey),
      '{corrupt',
    );
  });

  for (final width in [320.0, 430.0]) {
    testWidgets('drag auto-scrolls a long group list both ways at $width', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = Size(width, 932);
      addTearDown(tester.view.reset);
      final groups = [
        for (var i = 0; i < 20; i++)
          LibraryGroup(key: '$i', label: 'Shelf $i', bookIds: ['$i']),
      ];
      List<String>? result;
      await tester.pumpWidget(
        MaterialApp(
          theme: appTheme(Brightness.dark),
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () async {
                  result = await showLibraryGroupOrderSheet(context, groups);
                },
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      final list = find.byType(ReorderableListView);
      final viewport = tester.getRect(list);
      final position = tester
          .state<ScrollableState>(
            find.descendant(of: list, matching: find.byType(Scrollable)).first,
          )
          .position;
      final pointer = await tester.startGesture(
        tester.getCenter(find.byKey(const ValueKey('group-order-0'))),
      );
      await tester.pump(const Duration(milliseconds: 650));
      await pointer.moveBy(const Offset(0, 10));
      await tester.pump(const Duration(milliseconds: 100));
      await pointer.moveTo(Offset(viewport.center.dx, viewport.bottom + 36));
      for (var i = 0; i < 35; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      final scrolledDown = position.pixels;
      expect(scrolledDown, greaterThan(400));
      await pointer.moveTo(Offset(viewport.center.dx, viewport.top - 36));
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(position.pixels, lessThan(scrolledDown - 100));
      await pointer.moveTo(viewport.center);
      await tester.pump(const Duration(milliseconds: 600));
      await pointer.up();
      await tester.pumpAndSettle();
      await tester.tap(find.text('Lưu'));
      await tester.pumpAndSettle();
      expect(result, hasLength(groups.length));
      expect(result!.toSet(), groups.map((group) => group.key).toSet());
      expect(result!.indexOf('0'), greaterThan(0));
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      'drag both directions saves category order, keeps selection and persists at $width',
      (tester) async {
        final repository = MemoryLibraryRepository();
        await repository.save(
          LibraryBook(id: '1', title: 'First', collection: '..'),
        );
        await repository.save(
          LibraryBook(id: '2', title: 'Second', collection: 'manga'),
        );
        final snapshot = (await repository.list())
            .map((book) => book.toJson())
            .toList();
        final preferences = await SharedPreferences.getInstance();
        await _mount(tester, repository, preferences, width);
        await tester.tap(
          find.byKey(const ValueKey('library-group-value:manga')),
        );
        await tester.pumpAndSettle();
        await tester.longPress(
          find.byKey(const ValueKey('library-group-value:manga')),
        );
        await tester.pumpAndSettle();
        await _moveMangaFirst(tester);
        _expectSheetMangaFirst(tester);
        await tester.tap(find.text('Lưu'));
        await tester.pumpAndSettle();
        final raw = preferences.getString(
          LibraryGroupOrderController.preferenceKey,
        )!;
        expect(jsonDecode(raw)['collection'], ['value:manga', 'value:..']);
        _expectMangaFirst(tester);
        expect(find.byKey(const ValueKey('library-book-2')), findsOneWidget);
        expect(find.byKey(const ValueKey('library-book-1')), findsNothing);
        expect(
          (await repository.list()).map((book) => book.toJson()).toList(),
          snapshot,
        );
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
        await _mount(tester, repository, preferences, width);
        _expectMangaFirst(tester);
        await tester.tap(
          find.byKey(const ValueKey('library-group-value:manga')),
        );
        await tester.pumpAndSettle();
        await tester.longPress(
          find.byKey(const ValueKey('library-group-value:manga')),
        );
        await tester.pumpAndSettle();
        await _dragManga(tester, up: false);
        _expectSheetMangaFirst(tester, first: false);
        await tester.tap(find.text('Lưu'));
        await tester.pumpAndSettle();
        expect(
          jsonDecode(
            preferences.getString(LibraryGroupOrderController.preferenceKey)!,
          )['collection'],
          ['value:..', 'value:manga'],
        );
        _expectMangaFirst(tester, first: false);
        expect(find.byKey(const ValueKey('library-book-2')), findsOneWidget);
        expect(find.byKey(const ValueKey('library-book-1')), findsNothing);
        expect(
          (await repository.list()).map((book) => book.toJson()).toList(),
          snapshot,
        );
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
        await _mount(tester, repository, preferences, width);
        _expectMangaFirst(tester, first: false);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('cancel after drag preserves category order at $width', (
      tester,
    ) async {
      final repository = MemoryLibraryRepository();
      await repository.save(
        LibraryBook(id: '1', title: 'First', collection: '..'),
      );
      await repository.save(
        LibraryBook(id: '2', title: 'Second', collection: 'manga'),
      );
      final preferences = await SharedPreferences.getInstance();
      await _mount(tester, repository, preferences, width);
      await tester.tap(find.byTooltip('Thao tác thư viện'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Sắp xếp các mục'));
      await tester.pumpAndSettle();
      await _moveMangaFirst(tester);
      _expectSheetMangaFirst(tester);
      await tester.tap(find.text('Hủy'));
      await tester.pumpAndSettle();
      expect(
        preferences.containsKey(LibraryGroupOrderController.preferenceKey),
        isFalse,
      );
      expect(
        tester
            .getCenter(find.byKey(const ValueKey('library-group-value:..')))
            .dx,
        lessThan(
          tester
              .getCenter(
                find.byKey(const ValueKey('library-group-value:manga')),
              )
              .dx,
        ),
      );
      expect(tester.takeException(), isNull);
    });
  }
}

Future<void> _mount(
  WidgetTester tester,
  MemoryLibraryRepository repository,
  SharedPreferences preferences,
  double width,
) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = Size(width, 932);
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        libraryRepositoryProvider.overrideWithValue(repository),
        preferencesProvider.overrideWithValue(preferences),
      ],
      child: MaterialApp(
        theme: appTheme(Brightness.dark),
        home: const LibraryScreen(),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _moveMangaFirst(WidgetTester tester) =>
    _dragManga(tester, up: true);

Future<void> _dragManga(WidgetTester tester, {required bool up}) async {
  final from = find.byKey(const ValueKey('group-order-value:manga'));
  final to = find.byKey(const ValueKey('group-order-value:..'));
  // Overshoot the destination center, including the top edge when moving up.
  // A plain center-to-center drag misses the boundary regression.
  final target = tester.getCenter(to) + Offset(0, up ? -20 : 20);
  final start = tester.getCenter(from);
  final pointer = await tester.startGesture(start);
  await tester.pump(const Duration(milliseconds: 650));
  await pointer.moveBy(Offset(0, up ? -10 : 10));
  await tester.pump(const Duration(milliseconds: 100));
  if (up) {
    // A fast move can cross the list edge within one pointer update.
    await pointer.moveTo(target);
  } else {
    for (var step = 1; step <= 12; step++) {
      await pointer.moveTo(Offset.lerp(start, target, step / 12)!);
      await tester.pump(const Duration(milliseconds: 40));
    }
  }
  await tester.pump(const Duration(milliseconds: 600));
  await pointer.up();
  await tester.pumpAndSettle();
}

void _expectSheetMangaFirst(WidgetTester tester, {bool first = true}) {
  expect(
    tester.getCenter(find.byKey(const ValueKey('group-order-value:manga'))).dy,
    first
        ? lessThan(
            tester
                .getCenter(find.byKey(const ValueKey('group-order-value:..')))
                .dy,
          )
        : greaterThan(
            tester
                .getCenter(find.byKey(const ValueKey('group-order-value:..')))
                .dy,
          ),
  );
}

void _expectMangaFirst(WidgetTester tester, {bool first = true}) {
  expect(find.byKey(const ValueKey('library-group-all')), findsNothing);
  final manga = tester
      .getCenter(find.byKey(const ValueKey('library-group-value:manga')))
      .dx;
  final other = tester
      .getCenter(find.byKey(const ValueKey('library-group-value:..')))
      .dx;
  expect(manga, first ? lessThan(other) : greaterThan(other));
}
