import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tachi_books/features/reader/presentation/reader_image_loader.dart';
import 'package:tachi_books/features/sources/domain/catalogue.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tachi_books/features/library/data/library_repository.dart';
import 'package:tachi_books/features/library/domain/library_book.dart';
import 'package:tachi_books/features/library/presentation/library_view_model.dart';
import 'package:tachi_books/features/reader/presentation/reader_screen.dart';
import 'package:tachi_books/features/settings/settings_controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('flutter_tts'),
          (_) async => 1,
        );
  });
  tearDown(() {
    debugNetworkImageHttpClientProvider = null;
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
  });

  for (final legacy in [false, true]) {
    testWidgets(
      'a 1000-page ${legacy ? 'legacy' : 'imported'} vertical reader does not complete a pending or failed final page',
      (tester) async {
        final client = _PendingImageClient();
        debugNetworkImageHttpClientProvider = () => client;
        final page = await _png(tester);
        final images = [
          ...List.filled(999, page),
          'https://images.invalid/final.png',
        ];
        final fixture = await _open(
          tester,
          images,
          mode: 'paged',
          progress: .999,
          chapterRead: legacy ? null : false,
        );
        await tester.pump(const Duration(milliseconds: 100));
        expect(client.requested, isTrue);
        expect(find.byType(PageView), findsNothing);
        expect(find.byType(SingleChildScrollView), findsOneWidget);
        expect(
          (await fixture.repo.find('manga'))!.chapters.single.read,
          isFalse,
        );

        client.response.complete(_ImageResponse(Uint8List(0), statusCode: 503));
        await _waitForImages(tester);
        expect(find.text('Không tải được ảnh'), findsOneWidget);
        expect(find.text('Thử lại ảnh'), findsOneWidget);
        final saved = (await fixture.repo.find('manga'))!;
        expect(saved.chapters.single.read, isFalse);
        expect(saved.progress, closeTo(.999, .00001));
        await _dispose(tester, fixture.container);
        expect(
          (await fixture.repo.find('manga'))!.chapters.single.read,
          isFalse,
        );
      },
    );
  }

  testWidgets(
    'scrolling to the end of a failed vertical manga page keeps it unread',
    (tester) async {
      final client = _PendingImageClient();
      debugNetworkImageHttpClientProvider = () => client;
      final fixture = await _open(tester, [
        await _png(tester),
        'https://images.invalid/vertical-final.png',
      ], mode: 'vertical');
      client.response.complete(_ImageResponse(Uint8List(0), statusCode: 503));
      await _waitForImages(tester);
      expect(find.text('Không tải được ảnh'), findsOneWidget);
      expect(find.text('Thử lại ảnh'), findsOneWidget);
      final scroll = tester
          .widget<SingleChildScrollView>(
            find.byWidgetPredicate(
              (widget) =>
                  widget is SingleChildScrollView && widget.controller != null,
            ),
          )
          .controller!;
      expect(scroll.position.maxScrollExtent, greaterThan(0));
      scroll.jumpTo(scroll.position.maxScrollExtent);
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pumpAndSettle();
      final saved = (await fixture.repo.find('manga'))!;
      expect(saved.progress, 1);
      expect(saved.chapters.single.read, isFalse);
      await _dispose(tester, fixture.container);
      expect((await fixture.repo.find('manga'))!.chapters.single.read, isFalse);
    },
  );

  testWidgets(
    'a failed legacy image retry cannot adopt a restored same-ID chapter',
    (tester) async {
      final client = _PendingImageClient();
      debugNetworkImageHttpClientProvider = () => client;
      final fixture = await _open(tester, [
        'https://images.invalid/legacy.png',
      ], mode: 'vertical');
      client.response.complete(_ImageResponse(Uint8List(0), statusCode: 503));
      await _waitForImages(tester);
      final original = (await fixture.repo.find('manga'))!;
      await fixture.repo.clear();
      await fixture.repo.save(
        original.copyWith(
          title: 'Restored same ID',
          chapters: const [
            BookChapter(
              id: 'replacement-chapter',
              title: 'Replacement chapter',
              index: 0,
              read: false,
              downloaded: true,
            ),
          ],
        ),
      );
      await fixture.repo.saveChapter(
        'manga',
        0,
        ReaderContent(kind: 'manga', images: [await _png(tester)]),
      );
      final snapshot = (await fixture.repo.snapshot()).encode();
      final requests = client.requestCount;
      final retry = find.text('Thử lại ảnh');
      await tester.ensureVisible(retry);
      await tester.tap(retry);
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();
      expect(client.requestCount, requests);
      expect((await fixture.repo.snapshot()).encode(), snapshot);
      expect(find.text('Replacement chapter'), findsNothing);
      expect(find.textContaining('khôi phục'), findsWidgets);
      await _dispose(tester, fixture.container);
    },
  );

  testWidgets(
    'a decoded final vertical page still completes and preserves its end position',
    (tester) async {
      final fixture = await _open(tester, [
        await _png(tester),
        await _png(tester),
      ], mode: 'vertical');
      await _waitForImages(tester);
      expect((await fixture.repo.find('manga'))!.chapters.single.read, isFalse);
      final scroll = tester
          .widget<SingleChildScrollView>(find.byType(SingleChildScrollView))
          .controller!;
      scroll.jumpTo(scroll.position.maxScrollExtent);
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pumpAndSettle();
      final saved = (await fixture.repo.find('manga'))!;
      expect(saved.progress, 1);
      expect(saved.chapters.single.read, isTrue);
      await _dispose(tester, fixture.container);
    },
  );
}

typedef _Fixture = ({
  MemoryLibraryRepository repo,
  ProviderContainer container,
});

Future<_Fixture> _open(
  WidgetTester tester,
  List<String> images, {
  required String mode,
  double progress = 0,
  bool? chapterRead = false,
}) async {
  SharedPreferences.setMockInitialValues({'mangaMode': mode});
  final repo = MemoryLibraryRepository();
  await repo.save(
    LibraryBook(
      id: 'manga',
      title: 'Validation fixture',
      kind: 'manga',
      progress: progress,
      chapters: [
        BookChapter(
          id: 'chapter',
          title: 'Chapter',
          index: 0,
          downloaded: true,
          read: chapterRead,
        ),
      ],
    ),
  );
  await repo.saveChapter(
    'manga',
    0,
    ReaderContent(kind: 'manga', images: images),
  );
  final container = ProviderContainer(
    overrides: [
      ordinaryReaderImageLoaderProvider.overrideWithValue((data, page) async {
        if (data.images[page].startsWith('data:')) {
          return loadOrdinaryReaderImage(data, page);
        }
        final client =
            debugNetworkImageHttpClientProvider!() as _PendingImageClient;
        client.requested = true;
        client.requestCount++;
        final response = await client.response.future as _ImageResponse;
        if (response.statusCode != 200) {
          throw const FormatException('Fixture image HTTP error');
        }
        return SourceImageData(bytes: response.bytes, mimeType: 'image/png');
      }),
      preferencesProvider.overrideWithValue(
        await SharedPreferences.getInstance(),
      ),
      libraryRepositoryProvider.overrideWithValue(repo),
    ],
  );
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: ReaderScreen(id: 'manga')),
    ),
  );
  if (debugNetworkImageHttpClientProvider != null) {
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  } else {
    await tester.pumpAndSettle();
  }
  return (repo: repo, container: container);
}

Future<String> _png(WidgetTester tester) async =>
    (await tester.runAsync(() async {
      final recorder = ui.PictureRecorder();
      Canvas(recorder).drawRect(
        const Rect.fromLTWH(0, 0, 8, 900),
        Paint()..color = Colors.blue,
      );
      final picture = recorder.endRecording();
      final image = await picture.toImage(8, 900);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      final source =
          'data:image/png;base64,${base64Encode(data!.buffer.asUint8List())}';
      image.dispose();
      picture.dispose();
      return source;
    }))!;

Future<void> _waitForImages(WidgetTester tester) async {
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 30)),
  );
  await tester.pump();
  await tester.runAsync(() async {
    await Future.wait(
      tester.widgetList<Image>(find.byType(Image)).map((image) {
        final done = Completer<void>();
        final stream = image.image.resolve(ImageConfiguration.empty);
        late ImageStreamListener listener;
        void finish() {
          stream.removeListener(listener);
          if (!done.isCompleted) done.complete();
        }

        listener = ImageStreamListener(
          (_, _) => finish(),
          onError: (_, _) => finish(),
        );
        stream.addListener(listener);
        return done.future;
      }),
    );
  });
  await tester.pumpAndSettle();
}

Future<void> _dispose(WidgetTester tester, ProviderContainer container) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pumpAndSettle();
  container.dispose();
  debugNetworkImageHttpClientProvider = null;
  expect(tester.takeException(), isNull);
}

class _PendingImageClient implements HttpClient {
  final response = Completer<HttpClientResponse>();
  bool requested = false;
  int requestCount = 0;
  @override
  Future<HttpClientRequest> getUrl(Uri uri) async {
    requested = true;
    requestCount++;
    return _ImageRequest(response.future);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _ImageRequest implements HttpClientRequest {
  _ImageRequest(this.response);
  final Future<HttpClientResponse> response;
  @override
  final HttpHeaders headers = _ImageHeaders();
  @override
  Future<HttpClientResponse> close() => response;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _ImageHeaders implements HttpHeaders {
  @override
  void add(String name, Object value, {bool preserveHeaderCase = false}) {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _ImageResponse extends Stream<List<int>> implements HttpClientResponse {
  _ImageResponse(this.bytes, {this.statusCode = 200});
  final Uint8List bytes;
  @override
  final int statusCode;
  @override
  int get contentLength => bytes.length;
  @override
  HttpClientResponseCompressionState get compressionState =>
      HttpClientResponseCompressionState.notCompressed;
  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => Stream<List<int>>.value(bytes).listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
