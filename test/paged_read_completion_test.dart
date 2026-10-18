import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
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

  for (final layout in [
    'leftToRight',
    'rightToLeft',
    'verticalPages',
    'doublePage',
  ]) {
    testWidgets(
      '$layout waits for a real decoded image and never completes a failed page',
      (tester) async {
        final client = _PendingImageClient();
        debugNetworkImageHttpClientProvider = () => client;
        final fixture = await _open(
          tester,
          const ['https://images.invalid/paged-error.png'],
          progress: .5,
          layout: layout,
        );
        await tester.pump(const Duration(milliseconds: 100));
        expect(client.requested, true);
        expect((await fixture.repo.find('paged'))!.chapters.first.read, false);
        client.response.complete(_ImageResponse(Uint8List(0), statusCode: 503));
        await _waitForImages(tester);
        expect(find.text('Không tải được ảnh'), findsOneWidget);
        expect((await fixture.repo.find('paged'))!.chapters.first.read, false);
        await _dispose(tester, fixture.container);
        expect((await fixture.repo.find('paged'))!.chapters.first.read, false);
      },
    );
    testWidgets(
      '$layout incognito retains metadata and a restored library rejects the old page',
      (tester) async {
        final fixture = await _open(
          tester,
          await _images(tester, 3),
          private: true,
          layout: layout,
        );
        await _waitForImages(tester);
        final original = (await fixture.repo.find('paged'))!.toJson();
        final view = tester.widget<PageView>(find.byType(PageView));
        view.controller!.jumpToPage(layout == 'doublePage' ? 1 : 2);
        await tester.pump(const Duration(milliseconds: 600));
        await _waitForImages(tester);
        expect((await fixture.repo.find('paged'))!.toJson(), original);
        final replacement = (await fixture.repo.find('paged'))!
            .copyWith(title: 'Sau khôi phục', progress: .1);
        await fixture.repo.clear();
        await fixture.repo.save(replacement);
        await tester.tap(find.byTooltip('Đánh dấu trang'));
        await tester.pumpAndSettle();
        expect(
          (await fixture.repo.find('paged'))!.toJson(),
          replacement.toJson(),
        );
        await _dispose(tester, fixture.container);
      },
    );
  }

  for (final mode in ['paged', 'rtl']) {
    testWidgets(
      'legacy $mode preference uses continuous pages and completes only at the decoded end',
      (tester) async {
        final images = await _images(tester, 3);
        final fixture = await _open(tester, images, mode: mode);
        await _waitForImages(tester);
        expect((await fixture.repo.find('paged'))!.chapters.first.read, false);

        expect(find.byType(PageView), findsNothing);
        final scroll = tester
            .widget<SingleChildScrollView>(find.byType(SingleChildScrollView))
            .controller!;
        // Old paged/RTL preferences cannot replace the requested continuous flow.
        expect(
          fixture.container.read(preferencesProvider).getString('mangaMode'),
          mode,
        );
        scroll.jumpTo(tester.getSize(find.byType(Image).first).height + 10);
        await tester.pump(const Duration(milliseconds: 600));
        await tester.pumpAndSettle();
        expect((await fixture.repo.find('paged'))!.chapters.first.read, false);

        scroll.jumpTo(scroll.position.maxScrollExtent);
        await tester.pump(const Duration(milliseconds: 600));
        await tester.pumpAndSettle();
        final saved = (await fixture.repo.find('paged'))!;
        expect(saved.chapters.first.read, true);
        expect(saved.chapters.last.read, false);
        expect(saved.currentChapter, 0);
        expect(saved.progress, closeTo(.5, .0001));

        await _dispose(tester, fixture.container);
        final reopened = await _open(
          tester,
          images,
          mode: mode,
          repo: fixture.repo,
        );
        await _waitForImages(tester);
        final restored = tester
            .widget<SingleChildScrollView>(find.byType(SingleChildScrollView))
            .controller!;
        expect(restored.offset, closeTo(restored.position.maxScrollExtent, 1));
        expect(
          (await fixture.repo.find('paged'))!.progress,
          closeTo(.5, .0001),
        );
        await _dispose(tester, reopened.container);
      },
    );
  }

  testWidgets(
    'a single-page chapter completes only after its pending image decodes',
    (tester) async {
      final bytes = await _png(tester, Colors.green);
      final client = _PendingImageClient();
      debugNetworkImageHttpClientProvider = () => client;
      final fixture = await _open(tester, const [
        'https://images.invalid/single.png',
      ], progress: .5);
      await tester.pump(const Duration(milliseconds: 100));
      expect(client.requested, true);
      expect((await fixture.repo.find('paged'))!.chapters.first.read, false);
      client.response.complete(_ImageResponse(bytes));
      await _waitForImages(tester);
      final saved = (await fixture.repo.find('paged'))!;
      expect(saved.chapters.first.read, true);
      expect(
        saved.progress,
        .5,
        reason:
            'The continuous reader retains the previously saved end fraction.',
      );
      await _dispose(tester, fixture.container);
    },
  );

  testWidgets(
    'a failed last image does not mark an imported unread chapter read',
    (tester) async {
      final client = _PendingImageClient();
      debugNetworkImageHttpClientProvider = () => client;
      final fixture = await _open(tester, const [
        'https://images.invalid/failure.png',
      ], progress: .5);
      expect((await fixture.repo.find('paged'))!.chapters.first.read, false);
      client.response.complete(_ImageResponse(Uint8List(0), statusCode: 503));
      await _waitForImages(tester);
      expect(find.text('Không tải được ảnh'), findsOneWidget);
      expect(find.text('Thử lại ảnh'), findsOneWidget);
      expect((await fixture.repo.find('paged'))!.chapters.first.read, false);
      await _dispose(tester, fixture.container);
      expect((await fixture.repo.find('paged'))!.chapters.first.read, false);
    },
  );

  testWidgets(
    'incognito keeps read flags and all reading metadata through last-page completion',
    (tester) async {
      final images = await _images(tester, 2);
      final fixture = await _open(tester, images, private: true);
      await _waitForImages(tester);
      final original = (await fixture.repo.find('paged'))!.toJson();
      await fixture.container
          .read(settingsProvider.notifier)
          .update(incognitoMode: false);
      await tester.pumpAndSettle();
      final scroll = tester
          .widget<SingleChildScrollView>(find.byType(SingleChildScrollView))
          .controller!;
      scroll.jumpTo(scroll.position.maxScrollExtent);
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pumpAndSettle();
      await _waitForImages(tester);
      expect((await fixture.repo.find('paged'))!.toJson(), original);
      await _dispose(tester, fixture.container);
      expect((await fixture.repo.find('paged'))!.toJson(), original);
    },
  );

  testWidgets(
    'an old displayed reader cannot write completion or bookmarks into a restored book',
    (tester) async {
      final images = await _images(tester, 2);
      final fixture = await _open(tester, images);
      await _waitForImages(tester);
      final replacement = (await fixture.repo.find('paged'))!
          .copyWith(title: 'Restored title', progress: .1);
      await fixture.repo.clear();
      await fixture.repo.save(replacement);
      final scroll = tester
          .widget<SingleChildScrollView>(find.byType(SingleChildScrollView))
          .controller!;
      scroll.jumpTo(scroll.position.maxScrollExtent);
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pumpAndSettle();
      await _waitForImages(tester);
      // Let the failed progress toast leave before explicitly testing bookmark.
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Đánh dấu trang'));
      await tester.pumpAndSettle();
      expect(
        (await fixture.repo.find('paged'))!.toJson(),
        replacement.toJson(),
      );
      await _dispose(tester, fixture.container);
      expect(
        (await fixture.repo.find('paged'))!.toJson(),
        replacement.toJson(),
      );
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
  String mode = 'paged',
  String layout = 'continuous',
  bool private = false,
  double progress = 0,
  MemoryLibraryRepository? repo,
}) async {
  SharedPreferences.setMockInitialValues({
    'mangaMode': mode,
    'readerOptionsV1': jsonEncode({'mangaLayout': layout}),
    'incognitoMode': private,
  });
  final preferences = await SharedPreferences.getInstance();
  final library = repo ?? MemoryLibraryRepository();
  if (repo == null) {
    await library.save(
      LibraryBook(
        id: 'paged',
        title: 'Imported manga',
        kind: 'manga',
        progress: progress,
        chapters: const [
          BookChapter(
            id: 'first',
            title: 'First chapter',
            index: 0,
            downloaded: true,
            read: false,
          ),
          BookChapter(
            id: 'second',
            title: 'Second chapter',
            index: 1,
            downloaded: true,
            read: false,
          ),
        ],
      ),
    );
    await library.saveChapter(
      'paged',
      0,
      ReaderContent(kind: 'manga', images: images),
    );
  }
  final container = ProviderContainer(
    overrides: [
      preferencesProvider.overrideWithValue(preferences),
      libraryRepositoryProvider.overrideWithValue(library),
    ],
  );
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: ReaderScreen(id: 'paged')),
    ),
  );
  await tester.pumpAndSettle();
  expect(
    find.byType(PageView),
    layout == 'continuous' ? findsNothing : findsOneWidget,
  );
  if (layout == 'continuous') {
    expect(find.byType(SingleChildScrollView), findsOneWidget);
  }
  return (repo: library, container: container);
}

Future<Uint8List> _png(WidgetTester tester, Color color) async {
  return (await tester.runAsync(() async {
    final recorder = ui.PictureRecorder();
    Canvas(recorder)
        .drawRect(const Rect.fromLTWH(0, 0, 8, 8), Paint()..color = color);
    final picture = recorder.endRecording();
    final image = await picture.toImage(8, 8);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    final bytes = data!.buffer.asUint8List();
    image.dispose();
    picture.dispose();
    return bytes;
  }))!;
}

Future<List<String>> _images(WidgetTester tester, int count) async {
  final images = <String>[];
  for (var i = 0; i < count; i++) {
    final png = await _png(tester, Colors.primaries[i]);
    images.add('data:image/png;base64,${base64Encode(png)}');
  }
  return images;
}

Future<void> _waitForImages(WidgetTester tester) async {
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
  @override
  Future<HttpClientRequest> getUrl(Uri uri) async {
    requested = true;
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
