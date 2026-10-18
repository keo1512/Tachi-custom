import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tachi_books/features/reader/presentation/reader_image_region.dart';

Future<Uint8List> _png(WidgetTester tester) async =>
    (await tester.runAsync(() async {
      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(recorder)
        ..drawColor(const ui.Color(0xffffffff), ui.BlendMode.src);
      canvas.drawRect(
        const ui.Rect.fromLTWH(0, 0, 40, 80),
        ui.Paint()..color = const ui.Color(0xff000000),
      );
      final picture = recorder.endRecording();
      final image = await picture.toImage(400, 800);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      picture.dispose();
      return data!.buffer.asUint8List();
    }))!;

void main() {
  for (final size in [const Size(320, 568), const Size(430, 932)]) {
    testWidgets(
      'OCR region maps the visible image with letterboxing at $size',
      (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final bytes = await _png(tester);
        final before = Uint8List.fromList(bytes);
        Rect? selected;
        await tester.pumpWidget(
          MaterialApp(
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () async =>
                      selected = await showReaderImageRegion(context, bytes),
                  child: const Text('Open'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Open'));
        for (var i = 0; i < 15; i++) {
          await tester.runAsync(
            () async => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await tester.pump(const Duration(milliseconds: 50));
          if (find
              .byKey(const ValueKey('ocr-region-image'))
              .evaluate()
              .isNotEmpty) {
            break;
          }
        }
        await tester.pumpAndSettle();
        final image = tester.getRect(
          find.byKey(const ValueKey('ocr-region-image')),
        );
        expect(image.width / image.height, closeTo(.5, .001));
        final gesture = await tester.startGesture(
          Offset(image.left + image.width * .2, image.top + image.height * .25),
        );
        await gesture.moveTo(
          Offset(image.left + image.width * .8, image.top + image.height * .75),
        );
        await gesture.up();
        await tester.pump();
        await tester.tap(find.text('Nhận dạng vùng đã chọn'));
        await tester.pumpAndSettle();
        expect(selected!.left, closeTo(.2, .02));
        expect(selected!.top, closeTo(.25, .02));
        expect(selected!.right, closeTo(.8, .02));
        expect(selected!.bottom, closeTo(.75, .02));
        expect(bytes, before);
        expect(tester.takeException(), isNull);
      },
    );
  }
  testWidgets(
    'invalid image cannot enable OCR and cancellation returns no region',
    (tester) async {
      Rect? selected;
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(1.5)),
            child: child!,
          ),
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async => selected = await showReaderImageRegion(
                  context,
                  Uint8List(0),
                ),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      expect(find.text('Chưa đọc được ảnh để chọn vùng.'), findsOneWidget);
      expect(
        tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNull,
      );
      await tester.tap(find.byTooltip('Hủy chọn vùng'));
      await tester.pumpAndSettle();
      expect(selected, isNull);
      expect(tester.takeException(), isNull);
    },
  );
}
