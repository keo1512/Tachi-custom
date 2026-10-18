import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tachi_books/features/library/domain/library_book.dart';
import 'package:tachi_books/features/reader/domain/reader_options.dart';
import 'package:tachi_books/features/reader/presentation/continuous_manga_reader.dart';
import 'package:tachi_books/features/sources/domain/catalogue.dart';

final _bytes = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAABAAAAAgCAIAAACU62+bAAAAIUlEQVR4nGP4z8BAEiJN9aiGUQ1DS8OgdNSohlENA6MBAEGm/hCBgiIOAAAAAElFTkSuQmCC',
);
final _content = ReaderContent(
  kind: 'manga',
  images: ['fixture:1', 'fixture:2'],
);

Future<void> _drain(WidgetTester tester) async {
  // Image descriptors run on the engine outside the widget fake clock.
  await tester.runAsync(() async {
    await Future<void>.delayed(const Duration(milliseconds: 30));
  });
  for (var i = 0; i < 4; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _mount(
  WidgetTester tester,
  GlobalKey<ContinuousMangaReaderState> key,
  ScrollController scroll,
  Future<ReaderContent> Function(int) load, {
  bool Function()? current,
  Future<SourceImageData> Function(int, int)? image,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(430, 932);
  addTearDown(tester.view.reset);
  final book = LibraryBook(
    id: 'fixture',
    title: 'Fixture',
    kind: 'manga',
    chapters: [
      for (var i = 0; i < 8; i++)
        BookChapter(id: '$i', title: 'Chapter $i', index: i),
    ],
  );
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: ContinuousMangaReader(
          key: key,
          book: book,
          initialChapter: 0,
          initialContent: _content,
          initialFraction: 0,
          options: const ReaderOptions(),
          margins: EdgeInsets.zero,
          scroll: scroll,
          viewportKey: GlobalKey(),
          loadChapter: load,
          fetchImage: (chapter, _, page) async => image == null
              ? SourceImageData(bytes: _bytes, mimeType: 'image/png')
              : await image(chapter, page),
          isCurrent: current ?? () => true,
          onLocation: (_) {},
          onProgress: (_) {},
          onPageActions: (_, _) {},
        ),
      ),
    ),
  );
  await _drain(tester);
}

void main() {
  testWidgets(
    'next chapter failure keeps current pages and retries only after user action',
    (tester) async {
      final key = GlobalKey<ContinuousMangaReaderState>();
      final scroll = ScrollController();
      var attempts = 0;
      await _mount(tester, key, scroll, (index) async {
        attempts++;
        if (attempts == 1) {
          throw const FormatException('Fixture chapter unavailable');
        }
        return _content;
      });
      expect(attempts, 1);
      expect(key.currentState!.retainedChapters, 1);
      expect(
        find.byKey(const ValueKey('continuous-image:0:0')),
        findsOneWidget,
      );
      final retry = find.text('Thử lại chương');
      await tester.ensureVisible(retry);
      await tester.tap(retry);
      await _drain(tester);
      expect(attempts, 2);
      expect(key.currentState!.retainedChapters, 2);
      expect(
        find.byKey(const ValueKey('continuous-image:1:0')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      scroll.dispose();
    },
  );

  for (final dispose in [false, true]) {
    testWidgets(
      'a late prefetched chapter cannot publish after ${dispose ? 'dispose' : 'library replacement'}',
      (tester) async {
        final key = GlobalKey<ContinuousMangaReaderState>();
        final scroll = ScrollController(), gate = Completer<ReaderContent>();
        var current = true, calls = 0;
        await _mount(tester, key, scroll, (_) {
          calls++;
          return gate.future;
        }, current: () => current);
        expect(calls, 1);
        current = false;
        if (dispose) await tester.pumpWidget(const SizedBox.shrink());
        gate.complete(_content);
        await _drain(tester);
        expect(
          find.byKey(const ValueKey('continuous-image:1:0')),
          findsNothing,
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        scroll.dispose();
      },
    );
  }

  testWidgets(
    'long reading retains at most three chapters and bounded nearby images',
    (tester) async {
      final key = GlobalKey<ContinuousMangaReaderState>();
      final scroll = ScrollController();
      final calls = <int>[];
      await _mount(tester, key, scroll, (index) async {
        calls.add(index);
        return _content;
      });
      for (var chapter = 1; chapter < 7; chapter++) {
        expect(key.currentState!.jumpToChapter(chapter), isTrue);
        await _drain(tester);
        expect(key.currentState!.location!.chapter, chapter);
        expect(key.currentState!.retainedChapters, lessThanOrEqualTo(3));
        expect(key.currentState!.retainedImages, lessThanOrEqualTo(10));
        final pageTop = tester
            .getRect(find.byKey(ValueKey('continuous-image:$chapter:0')))
            .top;
        final viewportTop = tester
            .getRect(find.byType(SingleChildScrollView))
            .top;
        expect(
          pageTop,
          closeTo(viewportTop, 1),
          reason: 'Pruning a previous chapter must preserve the current scroll anchor',
        );
      }
      expect(calls.where((c) => c == 1).length, 1);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      scroll.dispose();
    },
  );

  testWidgets(
    'a late image changing page height preserves the visible scroll anchor',
    (tester) async {
      final key = GlobalKey<ContinuousMangaReaderState>();
      final scroll = ScrollController(), gate = Completer<SourceImageData>();
      await _mount(
        tester,
        key,
        scroll,
        (_) async => _content,
        image: (chapter, page) async {
          if (chapter == 0 && page == 0) return gate.future;
          return SourceImageData(bytes: _bytes, mimeType: 'image/png');
        },
      );
      scroll.jumpTo(300);
      await tester.pump();
      final before = key.currentState!.location!.fraction;
      gate.complete(SourceImageData(bytes: _bytes, mimeType: 'image/png'));
      await _drain(tester);
      expect(key.currentState!.location!.fraction, closeTo(before, .001));
      expect(key.currentState!.location!.chapter, 0);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      scroll.dispose();
    },
  );
}
