import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tachi_books/features/reader/domain/reader_options.dart';
import 'package:tachi_books/features/reader/presentation/reader_tap_zones.dart';

void main() {
  test('paged and continuous profiles persist independently with safe legacy defaults', () {
    final options = ReaderOptions.fromJson({
      'tapZones': 'kindle',
      'pagedTapZones': 'edges',
      'mangaLayout': 'doublePage',
      'invertDoublePages': true,
    });
    final restored = ReaderOptions.fromJson(options.toJson());
    expect(restored.activeTapZones, 'edges');
    expect(restored.pagesPerView, 2);
    expect(restored.invertDoublePages, true);
    expect(
      restored.patch({'mangaLayout': 'continuous'}).activeTapZones,
      'kindle',
    );
    expect(
      ReaderOptions.fromJson({'mangaMode': 'rtl'}).mangaLayout,
      'continuous',
    );
    expect(
      ReaderOptions.fromJson({'mangaLayout': 'future'}).mangaLayout,
      'continuous',
    );
  });
  for (final layout in [
    'off',
    'horizontal',
    'vertical',
    'edges',
    'kindle',
    'lShape',
  ]) {
    test(
      '$layout covers the viewport exactly once and inversion keeps the menu',
      () {
        final regions = readerTapRegions(layout);
        expect(
          ReaderOptions.fromJson({'tapZones': layout}).toJson()['tapZones'],
          layout,
        );
        for (var x = 0; x < 100; x++) {
          for (var y = 0; y < 100; y++) {
            final unit = Offset((x + .5) / 100, (y + .5) / 100);
            expect(regions.where((r) => r.bounds.contains(unit)), hasLength(1));
            final action = readerTapAction(
              layout: layout,
              point: unit * 300,
              viewport: const Size(300, 300),
              inverted: false,
            );
            final reversed = readerTapAction(
              layout: layout,
              point: unit * 300,
              viewport: const Size(300, 300),
              inverted: true,
            );
            expect(reversed, switch (action) {
              ReaderTapAction.menu => ReaderTapAction.menu,
              ReaderTapAction.previous => ReaderTapAction.next,
              ReaderTapAction.next => ReaderTapAction.previous,
            });
          }
        }
      },
    );
    testWidgets('$layout diagram fits a small viewport with large text', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(2)),
            child: Center(
              child: SizedBox(
                width: 240,
                child: ReaderTapZoneDiagram(layout: layout, inverted: true),
              ),
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
    });
  }
  test(
    'unknown profiles and points outside the viewport only toggle controls',
    () {
      expect(
        ReaderOptions.fromJson({'tapZones': 'future-profile'}).tapZones,
        'off',
      );
      for (final layout in ['edges', 'kindle', 'lShape', 'future-profile']) {
        for (final point in [
          const Offset(-1, 30),
          const Offset(300, 30),
          const Offset(30, double.nan),
        ]) {
          expect(
            readerTapAction(
              layout: layout,
              point: point,
              viewport: const Size(300, 300),
              inverted: false,
            ),
            ReaderTapAction.menu,
          );
        }
        expect(
          readerTapAction(
            layout: layout,
            point: const Offset(1, 1),
            viewport: Size.zero,
            inverted: false,
          ),
          ReaderTapAction.menu,
        );
      }
    },
  );
}
