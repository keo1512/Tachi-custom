import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tachi_books/core/platform/reader_platform.dart';
import 'package:tachi_books/core/theme/app_theme.dart';
import 'package:tachi_books/features/library/presentation/book_cover_viewer.dart';

void main() {
  for (final width in [320.0, 430.0]) {
    testWidgets(
      'full-screen cover keeps theme and retries failed provider at $width',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = Size(width, 700);
        addTearDown(tester.view.reset);
        final provider = _RetryCover();
        await tester.pumpWidget(
          MaterialApp(
            theme: appTheme(Brightness.dark),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: const TextScaler.linear(1.5)),
              child: child!,
            ),
            home: BookCoverViewer(
              title: 'Tên truyện rất dài vẫn có thể đọc bìa toàn màn hình',
              image: provider,
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('Chưa tải được ảnh bìa'), findsOneWidget);
        expect(
          tester.widget<IconButton>(_coverAction('Chia sẻ ảnh bìa')).onPressed,
          isNull,
        );
        expect(provider.calls, 1);
        expect(
          Theme.of(tester.element(find.byType(BookCoverViewer))).brightness,
          Brightness.dark,
        );
        await tester.tap(find.text('Thử lại'));
        await tester.pump();
        for (var attempt = 0; attempt < 50; attempt++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await tester.pump();
          if (tester
              .widgetList<RawImage>(find.byType(RawImage))
              .any((image) => image.image != null)) {
            break;
          }
        }
        expect(provider.calls, 2);
        expect(find.text('Chưa tải được ảnh bìa'), findsNothing);
        expect(
          tester
              .widgetList<RawImage>(find.byType(RawImage))
              .where((image) => image.image != null),
          hasLength(1),
        );
        expect(find.byType(InteractiveViewer), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await provider.evict();
      },
    );
  }

  for (final width in [320.0, 430.0]) {
    testWidgets(
      'cover save and share send the displayed PNG without refetch and keep actions bounded at $width',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = Size(width, 700);
        addTearDown(tester.view.reset);
        final provider = _RetryCover(failFirst: false);
        final calls = <MethodCall>[];
        final shared = Completer<void>();
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          ReaderPlatform.channel,
          (call) async {
            calls.add(call);
            if (call.method == 'shareImage') await shared.future;
            return null;
          },
        );
        addTearDown(
          () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            ReaderPlatform.channel,
            null,
          ),
        );
        await tester.pumpWidget(
          MaterialApp(
            theme: appTheme(Brightness.dark),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: const TextScaler.linear(1.5)),
              child: child!,
            ),
            home: BookCoverViewer(title: 'Bìa đang hiển thị', image: provider),
          ),
        );
        await _waitForCover(tester);
        expect(provider.calls, 1);
        await tester.tap(_coverAction('Lưu ảnh bìa vào Ảnh'));
        await _waitForCall(tester, calls, 1);
        expect(calls.single.method, 'saveImage');
        expect(find.text('Đã lưu ảnh bìa PNG vào Ảnh.'), findsOneWidget);
        await tester.runAsync(() async {
          final bytes = calls.single.arguments as Uint8List;
          expect(bytes.take(8), [137, 80, 78, 71, 13, 10, 26, 10]);
          final codec = await ui.instantiateImageCodec(bytes);
          final frame = await codec.getNextFrame();
          expect(frame.image.width, 1);
          expect(frame.image.height, 1);
          frame.image.dispose();
          codec.dispose();
        });
        await tester.tap(_coverAction('Chia sẻ ảnh bìa'));
        await _waitForCall(tester, calls, 2);
        expect(calls.last.method, 'shareImage');
        expect(
          tester.widget<IconButton>(_coverAction('Chia sẻ ảnh bìa')).onPressed,
          isNull,
        );
        expect(
          tester
              .widget<IconButton>(_coverAction('Lưu ảnh bìa vào Ảnh'))
              .onPressed,
          isNull,
        );
        shared.complete();
        await tester.pumpAndSettle();
        expect(provider.calls, 1);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await provider.evict();
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );
  }

  testWidgets(
    'denied Photos permission is actionable and leaves the cover available to share',
    (tester) async {
      final provider = _RetryCover(failFirst: false);
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        ReaderPlatform.channel,
        (call) async => throw PlatformException(
          code: 'photos_denied',
          message: 'Chưa được phép lưu vào Ảnh. Bật quyền thêm ảnh trong Cài đặt iOS.',
        ),
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          ReaderPlatform.channel,
          null,
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: BookCoverViewer(title: 'Bìa', image: provider),
        ),
      );
      await _waitForCover(tester);
      await tester.tap(_coverAction('Lưu ảnh bìa vào Ảnh'));
      for (var attempt = 0; attempt < 30; attempt++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump();
        if (find.byType(SnackBar).evaluate().isNotEmpty) break;
      }
      expect(find.textContaining('Cài đặt iOS'), findsOneWidget);
      expect(find.text('Đã lưu ảnh bìa PNG vào Ảnh.'), findsNothing);
      expect(
        tester.widget<IconButton>(_coverAction('Chia sẻ ảnh bìa')).onPressed,
        isNotNull,
      );
      expect(provider.calls, 1);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await provider.evict();
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets(
    'changing the cover disables export until the replacement frame arrives',
    (tester) async {
      final first = _RetryCover(failFirst: false);
      final gate = Completer<void>();
      final second = _RetryCover(failFirst: false, ready: gate.future);
      var provider = first;
      late StateSetter replace;
      await tester.pumpWidget(
        MaterialApp(
          home: StatefulBuilder(
            builder: (context, update) {
              replace = update;
              return BookCoverViewer(title: 'Bìa', image: provider);
            },
          ),
        ),
      );
      await _waitForCover(tester);
      replace(() => provider = second);
      await tester.pump();
      expect(
        tester.widget<IconButton>(_coverAction('Chia sẻ ảnh bìa')).onPressed,
        isNull,
      );
      gate.complete();
      await _waitForCover(tester);
      expect(first.calls, 1);
      expect(second.calls, 1);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await first.evict();
      await second.evict();
    },
  );

  testWidgets(
    'closing the viewer while native share is pending disposes its frame and ignores the late result',
    (tester) async {
      final provider = _RetryCover(failFirst: false);
      final calls = <MethodCall>[];
      final finished = Completer<void>();
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        ReaderPlatform.channel,
        (call) async {
          calls.add(call);
          await finished.future;
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          ReaderPlatform.channel,
          null,
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: BookCoverViewer(title: 'Bìa', image: provider),
        ),
      );
      await _waitForCover(tester);
      await tester.tap(_coverAction('Chia sẻ ảnh bìa'));
      await _waitForCall(tester, calls, 1);
      await tester.pumpWidget(const SizedBox.shrink());
      finished.complete();
      await tester.pumpAndSettle();
      expect(calls.single.method, 'shareImage');
      expect(tester.takeException(), isNull);
      await provider.evict();
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );
}

Future<void> _waitForCover(WidgetTester tester) async {
  for (var attempt = 0; attempt < 50; attempt++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump();
    final action = tester.widget<IconButton>(_coverAction('Chia sẻ ảnh bìa'));
    if (action.onPressed != null) return;
  }
  fail('Cover did not decode');
}

Finder _coverAction(String tooltip) => find.byWidgetPredicate(
  (widget) => widget is IconButton && widget.tooltip == tooltip,
);

Future<void> _waitForCall(
  WidgetTester tester,
  List<MethodCall> calls,
  int count,
) async {
  for (var attempt = 0; attempt < 50; attempt++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump();
    if (calls.length == count) return;
  }
  fail('Cover action did not reach the existing native channel');
}

class _RetryCover extends ImageProvider<_RetryCover> {
  _RetryCover({this.failFirst = true, this.ready});
  final bool failFirst;
  final Future<void>? ready;
  int calls = 0;

  @override
  Future<_RetryCover> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(
    _RetryCover key,
    ImageDecoderCallback decode,
  ) => MultiFrameImageStreamCompleter(codec: _load(decode), scale: 1);

  Future<ui.Codec> _load(ImageDecoderCallback decode) async {
    if (++calls == 1 && failFirst) throw StateError('Temporary image failure');
    if (ready != null) await ready;
    final bytes = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+ip1sAAAAASUVORK5CYII=',
    );
    return decode(await ui.ImmutableBuffer.fromUint8List(bytes));
  }
}
