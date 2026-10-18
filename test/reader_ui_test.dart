import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tachi_books/core/theme/app_theme.dart';
import 'package:tachi_books/features/downloads/presentation/download_queue_controller.dart';
import 'package:tachi_books/features/library/data/library_repository.dart';
import 'package:tachi_books/features/library/domain/library_book.dart';
import 'package:tachi_books/features/library/presentation/library_view_model.dart';
import 'package:tachi_books/features/reader/presentation/reader_screen.dart';
import 'package:tachi_books/features/reader/presentation/reader_auto_scroll.dart';
import 'package:tachi_books/features/reader/presentation/reader_options_controller.dart';
import 'package:tachi_books/features/settings/settings_controller.dart';

void main() {
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('flutter_tts'),
          (_) async => 1,
        );
  });

  testWidgets(
    'reader uses distinct portrait and landscape margins without paging',
    (tester) async {
      final fixture = await _open(
        tester,
        stored: {
          'readerOptionsV1': jsonEncode({
            'orientationMargins': true,
            'portraitLeft': 8,
            'portraitRight': 16,
            'landscapeLeft': 20,
            'landscapeRight': 28,
            'backgroundMode': 'custom',
            'backgroundColor': 0xfff5ebdc,
          }),
        },
      );
      await _waitForImages(tester);
      expect(_scaffold(tester).backgroundColor, const Color(0xfff5ebdc));
      await tester.tap(find.byTooltip('Giao diện đọc'));
      await tester.pumpAndSettle();
      expect(find.text('Màu tùy chọn #F5EBDC'), findsOneWidget);
      await tester.tap(find.text('Xong'));
      await tester.pumpAndSettle();
      expect(tester.getRect(find.byType(Image).first).left, 8);
      expect(tester.getRect(find.byType(Image).first).width, 430 - 24);
      tester.view.physicalSize = const Size(932, 430);
      await tester.pumpAndSettle();
      await _waitForImages(tester);
      expect(tester.getRect(find.byType(Image).first).left, 20);
      expect(tester.getRect(find.byType(Image).first).width, 932 - 48);
      expect(find.byType(PageView), findsNothing);
      expect(tester.takeException(), isNull);
      await _dispose(tester, fixture);
    },
  );

  testWidgets(
    'quick reader settings describe the current per-title background',
    (tester) async {
      final fixture = await _open(
        tester,
        stored: {
          'readerOptionsV1': jsonEncode({'backgroundMode': 'light'}),
        },
      );
      await _waitForImages(tester);
      final current = (await fixture.repo.find('reader'))!;
      await fixture.repo.save(
        current.copyWith(readerPreferences: const {'backgroundMode': 'dark'}),
      );
      await fixture.container.read(libraryProvider.notifier).refresh();
      await tester.pumpAndSettle();
      expect(_scaffold(tester).backgroundColor, Colors.black);
      await tester.tap(find.byTooltip('Giao diện đọc'));
      await tester.pumpAndSettle();
      expect(find.text('Nền tối'), findsOneWidget);
      expect(
        find.text('Theo giao diện sáng hoặc tối của ứng dụng.'),
        findsNothing,
      );
      await tester.tap(find.text('Xong'));
      await tester.pumpAndSettle();
      await _dispose(tester, fixture);
    },
  );

  testWidgets(
    'back gesture is blocked while explicit reader back still exits',
    (tester) async {
      final fixture = await _open(
        tester,
        pushReader: true,
        stored: {
          'readerOptionsV1': jsonEncode({'disableBackSwipe': true}),
        },
      );
      final navigator = tester.state<NavigatorState>(find.byType(Navigator));
      expect(await navigator.maybePop(), true); // Handled by PopScope.
      await tester.pumpAndSettle();
      expect(find.byType(ReaderScreen), findsOneWidget);
      await tester.tap(find.byTooltip('Quay lại'));
      await tester.pumpAndSettle();
      expect(find.byType(ReaderScreen), findsNothing);
      expect(find.text('Mở trình đọc'), findsOneWidget);
      await _dispose(tester, fixture);
    },
  );

  for (final size in const [Size(320, 568), Size(430, 932)]) {
    for (final brightness in Brightness.values) {
      testWidgets(
        'continuous full-width pages and reader controls follow $brightness at $size',
        (tester) async {
          final fixture = await _open(
            tester,
            size: size,
            brightness: brightness,
            stored: {'readerTheme': 'paper', 'mangaMode': 'rtl'},
          );
          await _waitForImages(tester);
          final images = find.byType(Image);
          expect(images, findsNWidgets(2));
          final first = tester.getRect(images.first);
          final second = tester.getRect(images.last);
          expect(first.left, 0);
          expect(first.width, size.width);
          expect(second.width, size.width);
          expect(second.top, closeTo(first.bottom, .01));
          expect(find.byType(PageView), findsNothing);
          expect(fixture.preferences.getString('mangaMode'), 'rtl');
          expect(fixture.preferences.getString('readerTheme'), 'paper');
          expect(
            _scaffold(tester).backgroundColor,
            appTheme(brightness).scaffoldBackgroundColor,
          );
          expect(find.text('Manga thử giao diện'), findsOneWidget);
          expect(find.text('Chương đầu'), findsOneWidget);
          expect(find.byTooltip('Đánh dấu trang'), findsOneWidget);
          expect(find.byTooltip('Tải chương'), findsOneWidget);
          expect(find.byTooltip('Hướng màn hình'), findsOneWidget);
          expect(find.byTooltip('Giao diện đọc'), findsOneWidget);
          expect(
            (await fixture.repo.find('reader'))!.chapters.first.read,
            false,
          );

          // Edge taps toggle chrome and never change a page/chapter.
          await tester.tapAt(const Offset(12, 180));
          // A single tap waits for the double-tap zoom gesture to expire.
          await tester.pump(const Duration(milliseconds: 350));
          await tester.pumpAndSettle();
          expect(find.byType(AppBar), findsNothing);
          expect(find.byTooltip('Giao diện đọc'), findsNothing);
          expect(find.text('1 / 2'), findsOneWidget);
          await tester.tapAt(Offset(size.width - 12, 180));
          await tester.pump(const Duration(milliseconds: 350));
          await tester.pumpAndSettle();
          expect(find.byType(AppBar), findsOneWidget);
          final scroll = tester
              .widget<SingleChildScrollView>(find.byType(SingleChildScrollView))
              .controller!;
          expect(scroll.offset, closeTo(0, .01));

          await tester.tap(find.byTooltip('Giao diện đọc'));
          await tester.pumpAndSettle();
          expect(find.text('Cuộn dọc liên tục'), findsOneWidget);
          expect(find.text('Lật trang'), findsNothing);
          expect(
            find.text('Theo giao diện sáng hoặc tối của ứng dụng.'),
            findsOneWidget,
          );
          await tester.tap(find.text('Xong'));
          await tester.pumpAndSettle();
          await tester.tap(find.byTooltip('Chương tiếp theo'));
          await tester.pumpAndSettle();
          await _waitForImages(tester);
          expect(find.text('Chương sau'), findsOneWidget);
          expect((await fixture.repo.find('reader'))!.currentChapter, 1);
          expect(tester.takeException(), isNull);
          await _dispose(tester, fixture);
        },
      );
    }
  }

  for (final size in const [Size(320, 568), Size(430, 932)]) {
    for (final mode in ['height', 'screen', 'original']) {
      testWidgets(
        '$mode keeps complete pages and seeks actual geometry at $size',
        (tester) async {
          final fixture = await _open(
            tester,
            size: size,
            images: [
              for (final height in [1200, 1600, 1400])
                await _png(tester, width: 400, height: height),
            ],
            stored: {
              'readerOptionsV1': jsonEncode({'imageScale': mode}),
            },
          );
          await _waitForImages(tester);
          final scroll = _verticalScroll(tester);
          final images = find.byType(Image);
          final first = tester.getRect(images.at(0));
          final second = tester.getRect(images.at(1));
          expect(second.top, closeTo(first.bottom, .01));
          expect(
            first.height,
            closeTo(
              mode == 'original' ? 1200 : scroll.position.viewportDimension,
              .01,
            ),
          );
          if (mode == 'original') {
            expect(first.width, 400);
            expect(second.height, 1600);
          }
          expect(find.byType(PageView), findsNothing);
          final slider = find.byKey(const ValueKey('reader-position-slider'));
          final bounds = tester.getRect(slider);
          final pointer = await tester.startGesture(
            Offset(bounds.left + 21, bounds.center.dy),
          );
          await pointer.moveTo(bounds.center);
          await tester.pumpAndSettle();
          expect(tester.widget<CupertinoSlider>(slider).value, 1);
          expect(scroll.offset, closeTo(first.height, 1));
          await pointer.moveTo(Offset(bounds.left + 21, bounds.center.dy));
          await tester.pumpAndSettle();
          expect(scroll.offset, closeTo(0, 1));
          await pointer.up();
          scroll.jumpTo(first.height + 20);
          await tester.pumpAndSettle();
          expect(tester.widget<CupertinoSlider>(slider).value, 1);
          expect(
            (await fixture.repo.find('reader'))!.chapters.first.read,
            false,
          );
          await _dispose(tester, fixture);
        },
      );
    }
  }

  testWidgets('changing image scale preserves the within-page position', (
    tester,
  ) async {
    final fixture = await _open(
      tester,
      images: [
        for (final height in [1200, 1600, 1400])
          await _png(tester, width: 400, height: height),
      ],
    );
    await _waitForImages(tester);
    final scroll = _verticalScroll(tester);
    final images = find.byType(Image);
    scroll.jumpTo(
      tester.getSize(images.at(0)).height +
          tester.getSize(images.at(1)).height * .3,
    );
    await tester.pumpAndSettle();
    for (final mode in ['height', 'original', 'screen', 'width']) {
      await fixture.container.read(readerOptionsProvider.notifier).patch({
        'imageScale': mode,
      });
      await tester.pumpAndSettle();
      expect(
        scroll.offset,
        closeTo(
          tester.getSize(images.at(0)).height +
              tester.getSize(images.at(1)).height * .3,
          1,
        ),
      );
    }
    await _dispose(tester, fixture);
  });

  for (final mode in [
    'leftToRight',
    'rightToLeft',
    'verticalPages',
    'doublePage',
  ]) {
    testWidgets(
      '$mode uses original page order, seeks, restores and returns to continuous mode',
      (tester) async {
        final fixture = await _open(
          tester,
          images: [
            for (var i = 0; i < 5; i++) await _png(tester, height: 40 + i * 15),
          ],
          stored: {
            'readerOptionsV1': jsonEncode({'mangaLayout': mode, 'zoom': false}),
          },
        );
        await _waitForImages(tester);
        final view = tester.widget<PageView>(find.byType(PageView));
        expect(view.reverse, mode == 'rightToLeft');
        expect(
          view.scrollDirection,
          mode == 'verticalPages' ? Axis.vertical : Axis.horizontal,
        );
        final perView = mode == 'doublePage' ? 2 : 1;
        expect(view.controller!.page, closeTo(0, .001));
        final rect = tester.getRect(
          find.byKey(const ValueKey('reader-content')),
        );
        // Hide controls before swiping so the entire viewport receives the gesture.
        await tester.tapAt(rect.center);
        await tester.pump(const Duration(milliseconds: 350));
        await tester.pumpAndSettle();
        await tester.drag(
          find.byType(PageView),
          mode == 'verticalPages'
              ? const Offset(0, -500)
              : Offset(mode == 'rightToLeft' ? 350 : -350, 0),
        );
        await tester.pumpAndSettle();
        expect(view.controller!.page, closeTo(1, .001));
        await tester.pump(const Duration(milliseconds: 550));
        expect(
          (await fixture.repo.find('reader'))!.progress,
          closeTo(perView / 5 / 2, .001),
        );
        expect((await fixture.repo.find('reader'))!.chapters.first.read, false);
        // Seek to the odd final page through the real bottom slider.
        await tester.tapAt(rect.center);
        await tester.pump(const Duration(milliseconds: 350));
        await tester.pumpAndSettle();
        final slider = tester.widget<CupertinoSlider>(
          find.byType(CupertinoSlider),
        );
        slider.onChanged!(4);
        await tester.pumpAndSettle();
        await _waitForImages(tester);
        expect(view.controller!.page, closeTo(4 ~/ perView, .001));
        expect((await fixture.repo.find('reader'))!.chapters.first.read, true);
        await fixture.container.read(readerOptionsProvider.notifier).patch({
          'mangaLayout': 'continuous',
        });
        await tester.pumpAndSettle();
        await _waitForImages(tester);
        expect(find.byType(PageView), findsNothing);
        expect(_verticalScroll(tester).offset, greaterThan(0));
        await _dispose(tester, fixture);
      },
    );
  }

  testWidgets(
    'double page inversion preserves source IDs and the unpaired last page',
    (tester) async {
      final fixture = await _open(
        tester,
        images: [
          for (var i = 0; i < 3; i++) await _png(tester, height: 60 + i * 10),
        ],
        stored: {
          'readerOptionsV1': jsonEncode({
            'mangaLayout': 'doublePage',
            'invertDoublePages': true,
            'zoom': true,
          }),
        },
      );
      await _waitForImages(tester);
      final keyed = find.byWidgetPredicate(
        (widget) =>
            widget.key is ValueKey<String> &&
            (widget.key as ValueKey<String>).value.startsWith('paged-image:'),
      );
      final first = keyed
          .evaluate()
          .map((e) => e.widget.key as ValueKey<String>)
          .toList();
      final zero = first.firstWhere((key) => key.value.endsWith(':0'));
      final one = first.firstWhere((key) => key.value.endsWith(':1'));
      expect(
        tester.getRect(find.byKey(one)).left,
        lessThan(tester.getRect(find.byKey(zero)).left),
      );
      final view = tester.widget<PageView>(find.byType(PageView));
      view.controller!.jumpToPage(1);
      await tester.pumpAndSettle();
      await _waitForImages(tester);
      expect((await fixture.repo.find('reader'))!.chapters.first.read, true);
      expect(find.byType(PageView), findsOneWidget);
      await _dispose(tester, fixture);
    },
  );

  testWidgets(
    'chapter boundary stays on this chapter until explicit next and describes the final chapter',
    (tester) async {
      final fixture = await _open(tester);
      await _waitForImages(tester);
      _verticalScroll(tester)
          .jumpTo(_verticalScroll(tester).position.maxScrollExtent);
      await tester.pumpAndSettle();
      expect(find.text('Hết chương'), findsOneWidget);
      expect(find.text('Chương tiếp theo: Chương sau'), findsOneWidget);
      expect(find.text('Chương đầu'), findsOneWidget);
      await tester.ensureVisible(find.text('Đọc chương tiếp'));
      await tester.tap(find.text('Đọc chương tiếp'));
      await tester.pumpAndSettle();
      await _waitForImages(tester);
      _verticalScroll(tester)
          .jumpTo(_verticalScroll(tester).position.maxScrollExtent);
      await tester.pumpAndSettle();
      expect(find.text('Chương sau'), findsOneWidget);
      expect(
        find.text('Đây là chương cuối trong danh sách hiện tại.'),
        findsOneWidget,
      );
      expect(find.text('Đọc chương tiếp'), findsNothing);
      await _dispose(tester, fixture);
    },
  );

  testWidgets(
    'an old chapter boundary cannot open replacement content after restore',
    (tester) async {
      final fixture = await _open(tester);
      await _waitForImages(tester);
      final scroll = _verticalScroll(tester);
      scroll.jumpTo(scroll.position.maxScrollExtent);
      await tester.pumpAndSettle();
      final replacement = (await fixture.repo.find('reader'))!
          .copyWith(title: 'Restored only', progress: .1);
      await fixture.repo.clear();
      await fixture.repo.save(replacement);
      await tester.tap(find.text('Đọc chương tiếp'));
      await tester.pumpAndSettle();
      expect(
        find.text(
          'Thư viện đã thay đổi. Hãy mở lại truyện trước khi chuyển chương.',
        ),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('reader-chapter-boundary')),
        findsOneWidget,
      );
      expect(
        (await fixture.repo.find('reader'))!.toJson(),
        replacement.toJson(),
      );
      await _dispose(tester, fixture);
    },
  );

  for (final layout in [
    'horizontal',
    'vertical',
    'edges',
    'kindle',
    'lShape',
  ]) {
    for (final inverted in [false, true]) {
      testWidgets(
        '$layout taps scroll the viewport with inverse=$inverted and center toggles chrome',
        (tester) async {
          final fixture = await _open(
            tester,
            images: [
              await _png(tester, height: 60),
              await _png(tester, height: 60),
            ],
            stored: {
              'readerOptionsV1': jsonEncode({
                'tapZones': layout,
                'invertTapZones': inverted,
              }),
            },
          );
          await _waitForImages(tester);
          final scroll = _verticalScroll(tester);
          final contentBounds = tester.getRect(
            find.byKey(const ValueKey('reader-content')),
          );
          // Stay above the bottom controls while still inside the lower third.
          final early = layout != 'vertical'
              ? Offset(30, contentBounds.top + contentBounds.height * .4)
              : Offset(
                  contentBounds.center.dx,
                  contentBounds.top + contentBounds.height * .2,
                );
          final late = layout != 'vertical'
              ? Offset(
                  contentBounds.right - 30,
                  contentBounds.top + contentBounds.height * .4,
                )
              : Offset(
                  contentBounds.center.dx,
                  contentBounds.top + contentBounds.height * .72,
                );
          await tester.tapAt(inverted ? early : late);
          await tester.pump(const Duration(milliseconds: 350));
          await tester.pumpAndSettle();
          expect(
            scroll.offset,
            closeTo(scroll.position.viewportDimension * .9, 1),
          );
          expect(find.byType(AppBar), findsOneWidget);
          await tester.tapAt(inverted ? late : early);
          await tester.pump(const Duration(milliseconds: 350));
          await tester.pumpAndSettle();
          expect(scroll.offset, closeTo(0, 1));
          await tester.tapAt(
            layout == 'kindle'
                ? Offset(
                    contentBounds.center.dx,
                    contentBounds.top + contentBounds.height * .1,
                  )
                : contentBounds.center,
          );
          await tester.pump(const Duration(milliseconds: 350));
          await tester.pumpAndSettle();
          expect(find.byType(AppBar), findsNothing);
          expect(scroll.offset, closeTo(0, 1));
          await _dispose(tester, fixture);
        },
      );
    }
  }

  testWidgets(
    'enabled tap zones leave drag, wide-image pan, double tap and pinch available',
    (tester) async {
      final fixture = await _open(
        tester,
        images: [
          await _png(tester, width: 800, height: 1800),
          await _png(tester, width: 800, height: 1800),
        ],
        stored: {
          'readerOptionsV1': jsonEncode({
            'tapZones': 'horizontal',
            'imageScale': 'original',
          }),
        },
      );
      await _waitForImages(tester);
      final scroll = _verticalScroll(tester);
      await tester.dragFrom(const Offset(350, 420), const Offset(0, -120));
      await tester.pumpAndSettle();
      expect(scroll.offset, greaterThan(80));
      expect(scroll.offset, lessThan(300));
      final beforePan = scroll.offset;
      await tester.dragFrom(const Offset(340, 350), const Offset(-160, 0));
      await tester.pumpAndSettle();
      final horizontalScrollable = tester.state<ScrollableState>(
        find.descendant(
          of: find.byKey(const ValueKey('manga-horizontal-page')).first,
          matching: find.byType(Scrollable),
        ),
      );
      expect(horizontalScrollable.position.pixels, greaterThan(100));
      expect(scroll.offset, closeTo(beforePan, 1));
      await tester.tapAt(const Offset(340, 300));
      await tester.pump(const Duration(milliseconds: 80));
      await tester.tapAt(const Offset(340, 300));
      await tester.pumpAndSettle();
      final viewer = tester.widget<InteractiveViewer>(
        find.byType(InteractiveViewer).first,
      );
      expect(
        viewer.transformationController!.value.getMaxScaleOnAxis(),
        closeTo(2, .01),
      );
      expect(scroll.offset, closeTo(beforePan, 1));
      final first = await tester.startGesture(
        const Offset(160, 300),
        pointer: 1,
      );
      final second = await tester.startGesture(
        const Offset(240, 300),
        pointer: 2,
      );
      await tester.pump();
      await first.moveTo(const Offset(130, 300));
      await second.moveTo(const Offset(270, 300));
      await tester.pump();
      // The first accepted scale update establishes the pinch baseline.
      await first.moveTo(const Offset(100, 300));
      await second.moveTo(const Offset(300, 300));
      await tester.pump();
      await first.up();
      await second.up();
      await tester.pumpAndSettle();
      expect(
        viewer.transformationController!.value.getMaxScaleOnAxis(),
        greaterThan(2),
      );
      expect(scroll.offset, closeTo(beforePan, 1));
      expect(find.byType(AppBar), findsOneWidget);
      await _dispose(tester, fixture);
    },
  );

  testWidgets(
    'auto scroll status pauses and resumes without changing saved options',
    (tester) async {
      final fixture = await _open(tester, size: const Size(320, 568));
      await _waitForImages(tester);
      await fixture.container.read(readerOptionsProvider.notifier).patch({
        'autoScroll': true,
        'autoScrollSpeed': 80,
      });
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      final scroll = _verticalScroll(tester);
      expect(find.text('Tự cuộn · 80 px/giây'), findsOneWidget);
      expect(scroll.offset, greaterThan(0));
      await tester.tap(find.byTooltip('Tạm dừng tự cuộn'));
      await tester.pump();
      final pausedAt = scroll.offset;
      await tester.pump(const Duration(seconds: 2));
      expect(scroll.offset, pausedAt);
      expect(find.text('Đã tạm dừng tự cuộn'), findsOneWidget);
      expect(fixture.container.read(readerOptionsProvider).autoScroll, true);
      await tester.tap(find.byTooltip('Tiếp tục tự cuộn'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(scroll.offset, greaterThan(pausedAt));
      expect(find.byType(PageView), findsNothing);
      expect(tester.takeException(), isNull);
      await fixture.container.read(readerOptionsProvider.notifier).patch({
        'autoScroll': false,
      });
      await tester.pumpAndSettle();
      await _dispose(tester, fixture);
    },
  );

  testWidgets(
    'auto scrolling waits while settings or nested advanced dialog covers reader',
    (tester) async {
      final fixture = await _open(tester);
      await _waitForImages(tester);
      await fixture.container.read(readerOptionsProvider.notifier).patch({
        'autoScroll': true,
      });
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      final scroll = _verticalScroll(tester);
      expect(scroll.offset, greaterThan(0));
      await tester.tap(find.byTooltip('Giao diện đọc'));
      await tester.pump(const Duration(milliseconds: 400));
      final paused = scroll.offset;
      await tester.pump(const Duration(seconds: 2));
      expect(scroll.offset, paused);
      await tester.tap(find.text('Xong'));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(seconds: 1));
      expect(scroll.offset, greaterThan(paused));
      await tester.tap(find.byTooltip('Giao diện đọc'));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.ensureVisible(
        find.text('Thiết lập nâng cao / riêng theo truyện'),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Thiết lập nâng cao / riêng theo truyện'));
      await tester.pumpAndSettle();
      expect(find.text('Thiết lập đọc nâng cao'), findsOneWidget);
      final advancedPaused = scroll.offset;
      await tester.pump(const Duration(seconds: 2));
      expect(scroll.offset, advancedPaused);
      tester.state<NavigatorState>(find.byType(Navigator).first).pop();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(seconds: 1));
      expect(scroll.offset, greaterThan(advancedPaused));
      await fixture.container.read(readerOptionsProvider.notifier).patch({
        'autoScroll': false,
      });
      await tester.pumpAndSettle();
      await _dispose(tester, fixture);
    },
  );

  for (final brightness in Brightness.values) {
    testWidgets(
      'new novel defaults to the app while explicit page themes remain usable in $brightness',
      (tester) async {
        final fixture = await _open(
          tester,
          kind: 'novel',
          brightness: brightness,
        );
        expect(fixture.container.read(settingsProvider).readerTheme, 'system');
        expect(fixture.preferences.containsKey('readerTheme'), false);
        expect(
          _scaffold(tester).backgroundColor,
          appTheme(brightness).scaffoldBackgroundColor,
        );
        for (final entry in {
          'paper': Colors.white,
          'sepia': const Color(0xFFF5EBDC),
          'night': const Color(0xFF161616),
          'system': appTheme(brightness).scaffoldBackgroundColor,
        }.entries) {
          await fixture.container
              .read(settingsProvider.notifier)
              .update(readerTheme: entry.key);
          await tester.pumpAndSettle();
          expect(_scaffold(tester).backgroundColor, entry.value);
          expect(
            Theme.of(tester.element(find.byType(AppBar))).brightness,
            brightness,
          );
        }
        await _dispose(tester, fixture);
      },
    );
  }

  for (final size in const [Size(320, 568), Size(430, 932)]) {
    testWidgets(
      'pointer dragging seeks whole unequal-height pages immediately and manual scrolling updates the slider at $size',
      (tester) async {
        final images = [
          await _png(tester, height: 16),
          await _png(tester, height: 40),
          await _png(tester, height: 32),
        ];
        final fixture = await _open(tester, images: images, size: size);
        await _waitForImages(tester);
        final scroll = tester
            .widget<SingleChildScrollView>(find.byType(SingleChildScrollView))
            .controller!;
        final heights = tester
            .widgetList<Image>(find.byType(Image))
            .map((image) => tester.getSize(find.byWidget(image)).height)
            .toList();
        final slider = find.byKey(const ValueKey('reader-position-slider'));
        final bounds = tester.getRect(slider);
        final pointer = await tester.startGesture(
          Offset(bounds.left + 21, bounds.center.dy),
        );
        await pointer.moveTo(bounds.center);
        await tester.pumpAndSettle();
        // Still dragging: the selected page must already be visible.
        expect(tester.widget<CupertinoSlider>(slider).value, 1);
        expect(scroll.offset, closeTo(heights[0], 1));
        await pointer.moveTo(Offset(bounds.right - 21, bounds.center.dy));
        await tester.pumpAndSettle();
        expect(tester.widget<CupertinoSlider>(slider).value, 2);
        expect(scroll.offset, closeTo(heights[0] + heights[1], 1));
        await pointer.moveTo(Offset(bounds.left + 21, bounds.center.dy));
        await tester.pumpAndSettle();
        expect(tester.widget<CupertinoSlider>(slider).value, 0);
        expect(scroll.offset, closeTo(0, 1));
        await pointer.up();
        scroll.jumpTo(heights[0] - 30);
        await tester.pumpAndSettle();
        expect(tester.widget<CupertinoSlider>(slider).value, 0);
        await tester.timedDrag(
          find.byKey(const ValueKey('reader-content')),
          const Offset(0, -100),
          const Duration(seconds: 1),
        );
        await tester.pumpAndSettle();
        await tester.pump(const Duration(milliseconds: 600));
        await tester.pumpAndSettle();
        expect(tester.widget<CupertinoSlider>(slider).value, 1);
        expect((await fixture.repo.find('reader'))!.chapters.first.read, false);
        expect(
          (await fixture.repo.find('reader'))!.progress,
          closeTo((1 + (scroll.offset - heights[0]) / heights[1]) / 6, .0001),
        );
        await _dispose(tester, fixture);
      },
    );
  }

  testWidgets('loading and unavailable chapters retain the dark app scaffold', (
    tester,
  ) async {
    final ready = Completer<void>();
    final fixture = await _open(
      tester,
      empty: true,
      stored: {'readerTheme': 'paper'},
      findGate: ready,
      settle: false,
    );
    await tester.pump();
    expect(find.byType(CupertinoActivityIndicator), findsOneWidget);
    expect(_scaffold(tester).backgroundColor, Colors.black);
    ready.complete();
    await tester.pumpAndSettle();
    expect(find.text('Chưa mở được chương'), findsOneWidget);
    expect(find.text('Nhật ký và chẩn đoán'), findsOneWidget);
    expect(_scaffold(tester).backgroundColor, Colors.black);
    expect(
      Theme.of(tester.element(find.text('Chưa mở được chương'))).brightness,
      Brightness.dark,
    );
    await _dispose(tester, fixture);
  });

  testWidgets(
    'seeking to the start of a decoded final page in a 1000-page chapter stays unread until its actual end',
    (tester) async {
      final page = await _png(tester, height: 32);
      final fixture = await _open(tester, images: List.filled(1000, page));
      await _waitForImages(tester);
      final scroll = tester
          .widget<SingleChildScrollView>(find.byType(SingleChildScrollView))
          .controller!;
      final slider = find.byKey(const ValueKey('reader-position-slider'));
      final bounds = tester.getRect(slider);
      final pointer = await tester.startGesture(
        Offset(bounds.left + 21, bounds.center.dy),
      );
      await pointer.moveTo(Offset(bounds.right - 21, bounds.center.dy));
      await tester.pumpAndSettle();
      await _waitForImages(tester);
      expect(tester.widget<CupertinoSlider>(slider).value, 999);
      expect(scroll.offset, lessThan(scroll.position.maxScrollExtent - 1));
      final saved = (await fixture.repo.find('reader'))!;
      expect(saved.progress, closeTo(.999 / 2, .00001));
      expect(saved.chapters.first.read, false);
      await pointer.up();
      scroll.jumpTo(scroll.position.maxScrollExtent);
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pumpAndSettle();
      expect((await fixture.repo.find('reader'))!.chapters.first.read, true);
      expect((await fixture.repo.find('reader'))!.progress, .5);
      await _dispose(tester, fixture);
    },
  );

  testWidgets(
    'reader download uses the shared chapter queue and a stale reader cannot enqueue after restore',
    (tester) async {
      final downloaded = <String>[];
      final finished = Completer<void>();
      final fixture = await _open(
        tester,
        remote: true,
        executor: (book, index) async {
          downloaded.add(book.chapters[index].id);
          await finished.future;
        },
      );
      await tester.tap(find.byTooltip('Tải chương'));
      await tester.pumpAndSettle();
      expect(downloaded, ['chapter-0']);
      expect(
        fixture.container.read(downloadQueueProvider).tasks.single.chapterId,
        'chapter-0',
      );
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      final original = (await fixture.repo.find('reader'))!;
      await fixture.repo.clear();
      await fixture.repo.save(
        original.copyWith(title: 'Restored', progress: .35),
      );
      final unchangedQueue = fixture.container
          .read(downloadQueueProvider)
          .tasks
          .map((task) => task.toJson())
          .toList();
      await tester.tap(find.byTooltip('Tải chương'));
      await tester.pumpAndSettle();
      expect(downloaded, ['chapter-0']);
      expect(
        fixture.container
            .read(downloadQueueProvider)
            .tasks
            .map((task) => task.toJson())
            .toList(),
        unchangedQueue,
      );
      expect(
        find.textContaining('Thư viện đã được thay đổi hoặc khôi phục'),
        findsOneWidget,
      );
      expect((await fixture.repo.find('reader'))!.title, 'Restored');
      expect((await fixture.repo.find('reader'))!.progress, .35);
      finished.complete();
      await tester.pumpAndSettle();
      await _dispose(tester, fixture);
    },
  );

  testWidgets(
    'orientation control sends the requested native preference and resets it on exit',
    (tester) async {
      final calls = <List<dynamic>>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
            if (call.method == 'SystemChrome.setPreferredOrientations') {
              calls.add(call.arguments as List<dynamic>);
            }
            return null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, null),
      );
      final fixture = await _open(tester);
      await tester.tap(find.byTooltip('Hướng màn hình'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Dọc'));
      await tester.pumpAndSettle();
      expect(calls, [
        ['DeviceOrientation.portraitUp'],
      ]);
      await _dispose(tester, fixture);
      expect(calls.last, isEmpty);
    },
  );
}

Scaffold _scaffold(WidgetTester tester) =>
    tester.widget<Scaffold>(find.byKey(const ValueKey('reader-scaffold')));

ScrollController _verticalScroll(WidgetTester tester) => tester
    .widgetList<SingleChildScrollView>(find.byType(SingleChildScrollView))
    .singleWhere(
      (view) =>
          view.scrollDirection == Axis.vertical && view.controller != null,
    )
    .controller!;

typedef _Fixture = ({
  MemoryLibraryRepository repo,
  ProviderContainer container,
  SharedPreferences preferences,
});

Future<_Fixture> _open(
  WidgetTester tester, {
  Size size = const Size(430, 932),
  Brightness brightness = Brightness.dark,
  String kind = 'manga',
  Map<String, Object> stored = const {},
  bool empty = false,
  bool remote = false,
  List<String>? images,
  Completer<void>? findGate,
  bool settle = true,
  bool pushReader = false,
  Future<void> Function(LibraryBook, int)? executor,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);
  SharedPreferences.setMockInitialValues(stored);
  final preferences = await SharedPreferences.getInstance();
  final repo = findGate == null
      ? MemoryLibraryRepository()
      : _DelayedFindRepository(findGate);
  await repo.save(
    LibraryBook(
      id: 'reader',
      title: 'Manga thử giao diện',
      kind: kind,
      engine: remote ? 'vbook' : 'local',
      chapters: empty
          ? []
          : const [
              BookChapter(
                id: 'chapter-0',
                title: 'Chương đầu',
                index: 0,
                read: false,
              ),
              BookChapter(
                id: 'chapter-1',
                title: 'Chương sau',
                index: 1,
                read: false,
              ),
            ],
    ),
  );
  if (!empty) {
    final image = remote
        ? 'https://images.invalid/page.png'
        : await _png(tester);
    for (var index = 0; index < 2; index++) {
      await repo.saveChapter(
        'reader',
        index,
        ReaderContent(
          kind: kind,
          images: kind == 'manga' ? images ?? [image, image] : [],
          html: kind == 'novel' ? '<p>Nội dung đọc thử.</p>' : '',
        ),
      );
    }
  }
  final container = ProviderContainer(
    overrides: [
      preferencesProvider.overrideWithValue(preferences),
      libraryRepositoryProvider.overrideWithValue(repo),
      readerAutoScrollClockProvider.overrideWithValue(tester.binding.clock.now),
      if (executor != null)
        downloadJobExecutorProvider.overrideWithValue(executor),
    ],
  );
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: appTheme(brightness),
        home: pushReader
            ? Scaffold(
                body: Builder(
                  builder: (context) => TextButton(
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => const ReaderScreen(id: 'reader'),
                      ),
                    ),
                    child: const Text('Mở trình đọc'),
                  ),
                ),
              )
            : const ReaderScreen(id: 'reader'),
      ),
    ),
  );
  if (pushReader) {
    await tester.tap(find.text('Mở trình đọc'));
    await tester.pump();
  }
  if (settle) await tester.pumpAndSettle();
  return (repo: repo, container: container, preferences: preferences);
}

class _DelayedFindRepository extends MemoryLibraryRepository {
  _DelayedFindRepository(this.ready);
  final Completer<void> ready;

  @override
  Future<LibraryBook?> find(String id) async {
    await ready.future;
    return super.find(id);
  }
}

Future<String> _png(
  WidgetTester tester, {
  int height = 12,
  int width = 8,
}) async => (await tester.runAsync(() async {
  final recorder = ui.PictureRecorder();
  Canvas(recorder).drawRect(
    Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    Paint()..color = Colors.blue,
  );
  final picture = recorder.endRecording();
  final image = await picture.toImage(width, height);
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  final source =
      'data:image/png;base64,${base64Encode(bytes!.buffer.asUint8List())}';
  image.dispose();
  picture.dispose();
  return source;
}))!;

Future<void> _waitForImages(WidgetTester tester) async {
  await tester.runAsync(() async {
    await Future.wait(
      tester.widgetList<Image>(find.byType(Image)).map((image) {
        final done = Completer<void>();
        final stream = image.image.resolve(ImageConfiguration.empty);
        late ImageStreamListener listener;
        listener = ImageStreamListener(
          (_, _) {
            stream.removeListener(listener);
            if (!done.isCompleted) done.complete();
          },
          onError: (_, _) {
            stream.removeListener(listener);
            if (!done.isCompleted) done.complete();
          },
        );
        stream.addListener(listener);
        return done.future;
      }),
    );
  });
  await tester.pumpAndSettle();
}

Future<void> _dispose(WidgetTester tester, _Fixture fixture) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pumpAndSettle();
  fixture.container.dispose();
  expect(tester.takeException(), isNull);
}
