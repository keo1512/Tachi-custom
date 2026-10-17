import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tachi_books/core/theme/app_theme.dart';
import 'package:tachi_books/features/library/presentation/library_filter_sheet.dart';

void main() {
  Future<void> mount(
    WidgetTester tester,
    Size size,
    ValueChanged<LibraryFilter> onChanged, {
    double scale = 1,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme(Brightness.dark),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: Scaffold(
          body: LibraryFilterSheet(
            value: const LibraryFilter(showSource: true),
            collections: [for (var i = 0; i < 80; i++) 'Danh mục $i'],
            sources: {
              for (var i = 0; i < 100; i++) 'source:$i': 'Nguồn thử $i',
            },
            libraryColumns: 5,
            onColumnsChanged: (_) {},
            onChanged: onChanged,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> scrollToFilter(
    WidgetTester tester,
    Finder target, {
    double step = 100,
  }) async {
    await tester.scrollUntilVisible(
      target,
      step,
      scrollable: find
          .descendant(
            of: find.byKey(const ValueKey('library-filter-options')),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.pumpAndSettle();
  }

  for (final size in [const Size(320, 568), const Size(430, 932)]) {
    testWidgets(
      'large source/category lists stay behind searchable selectors at $size',
      (tester) async {
        LibraryFilter? changed;
        await mount(tester, size, (value) => changed = value);
        expect(find.text('Nguồn thử 95'), findsNothing);
        expect(find.text('Danh mục 70'), findsNothing);
        await scrollToFilter(tester, find.text('Nguồn truyện'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Nguồn truyện'));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const ValueKey('library-filter-picker-search')),
          'Nguồn thử 95',
        );
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(ListTile, 'Nguồn thử 95'));
        await tester.pumpAndSettle();
        expect(changed!.source, 'source:95');
        expect(
          find.byKey(const ValueKey('library-filter-picker-search')),
          findsNothing,
        );
        await scrollToFilter(tester, find.text('Loại trừ nguồn đã chọn'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Loại trừ nguồn đã chọn'));
        await tester.pumpAndSettle();
        expect(changed!.excludeSource, isTrue);
        await scrollToFilter(tester, find.text('Danh mục'), step: -100);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Danh mục'));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const ValueKey('library-filter-picker-search')),
          'Danh mục 70',
        );
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(ListTile, 'Danh mục 70'));
        await tester.pumpAndSettle();
        expect(changed!.category, 'Danh mục 70');
        expect(changed!.source, 'source:95');
        await scrollToFilter(tester, find.text('Đặt lại bộ lọc'), step: -100);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Đặt lại bộ lọc'));
        await tester.pumpAndSettle();
        expect(changed!.active, isFalse);
        expect(changed!.showSource, isTrue);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'compact status menus preserve all three states and display groups remain actionable',
    (tester) async {
      LibraryFilter? changed;
      await mount(tester, const Size(430, 932), (value) => changed = value);
      await tester.ensureVisible(find.byTooltip('Lọc Chương chưa đọc'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Lọc Chương chưa đọc'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Loại trừ').last);
      await tester.pumpAndSettle();
      expect(changed!.unread, LibraryTriState.exclude);
      await tester.tap(find.text('Hiển thị'));
      await tester.pumpAndSettle();
      expect(find.text('Tên nguồn'), findsNothing);
      await tester.ensureVisible(find.text('Thông tin và nút đọc'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Thông tin và nút đọc'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Tên nguồn'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Tên nguồn'));
      await tester.pumpAndSettle();
      expect(changed!.showSource, isFalse);
      expect(changed!.unread, LibraryTriState.exclude);
      await tester.drag(find.byType(ListView).last, const Offset(0, 800));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Danh sách'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Danh sách'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('library-columns-slider')),
        findsNothing,
      );
      expect(changed!.display, LibraryDisplay.list);
      expect(tester.takeException(), isNull);
    },
  );

  for (final scale in [1.0, 1.5]) {
    testWidgets('filter layout fits small screens at text scale $scale', (
      tester,
    ) async {
      await mount(tester, const Size(320, 568), (_) {}, scale: scale);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Hiển thị'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }
}
