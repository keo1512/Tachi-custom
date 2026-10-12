import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tachi_books/core/theme/app_theme.dart';
import 'package:tachi_books/features/sources/data/extension_index.dart';
import 'package:tachi_books/features/sources/domain/catalogue.dart';
import 'package:tachi_books/features/sources/presentation/extension_catalogue_controller.dart';
import 'package:tachi_books/features/sources/presentation/extension_catalogue_view.dart';

CatalogueExtension _extension({String icon = '', bool installed = false}) =>
    CatalogueExtension(
      id: 'https://repo.test/plugin.zip',
      name: 'Fixture with a long catalogue title',
      version: '13',
      engine: SourceEngine.vbook,
      packageUrl: 'https://repo.test/plugin.zip',
      iconUrl: icon,
      installed: installed,
      lang: 'vi',
    );

class _FixtureCatalogue extends ExtensionCatalogueController {
  _FixtureCatalogue(this.items);
  final List<ExtensionIndex> items;
  @override
  Future<List<ExtensionIndex>> build() async => items;
}

Future<void> _open(
  WidgetTester tester,
  CatalogueExtension entry, {
  List<CatalogueExtension> installed = const [],
  void Function(CatalogueExtension)? onInstall,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        extensionCatalogueProvider.overrideWith(
          () => _FixtureCatalogue([
            ExtensionIndex(
              'https://repo.test/plugin.json',
              SourceEngine.vbook,
              [entry],
            ),
          ]),
        ),
      ],
      child: MaterialApp(
        theme: appTheme(Brightness.dark),
        home: Scaffold(
          body: ExtensionCatalogueView(
            installed: installed,
            installing: const {},
            onInstall: onInstall ?? (_) {},
            onAdd: () {},
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  tearDown(() {
    debugNetworkImageHttpClientProvider = null;
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
  });

  testWidgets(
    'a real catalogue icon decodes in a 38px slot and installation still selects the original package at 320px',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(320, 568);
      addTearDown(tester.view.reset);
      final requests = <Uri>[];
      final png = await _png(tester);
      debugNetworkImageHttpClientProvider = () => _IconClient(requests, png);
      final entry = _extension(icon: 'https://repo.test/icons/plugin.png');
      final selected = <CatalogueExtension>[];
      await _open(tester, entry, onInstall: selected.add);
      await _waitForImage(tester);
      expect(requests, [Uri.parse(entry.iconUrl)]);
      expect(
        find.byKey(const ValueKey('extension-icon-placeholder')),
        findsNothing,
      );
      expect(tester.getSize(find.byType(ClipRRect)), const Size(38, 38));
      final provider =
          tester.widget<Image>(find.byType(Image)).image as ResizeImage;
      expect(provider.width, 114);
      expect(provider.height, 114);
      await tester.tap(find.text('Cài'));
      expect(selected.single, same(entry));
      expect(selected.single.installed, isFalse);
      expect(selected.single.packageUrl, 'https://repo.test/plugin.zip');
      await _dispose(tester);
    },
  );

  testWidgets(
    'a failed catalogue icon uses a placeholder and leaves the install button usable',
    (tester) async {
      final requests = <Uri>[];
      debugNetworkImageHttpClientProvider = () =>
          _IconClient(requests, Uint8List(0), fail: true);
      final entry = _extension(icon: 'https://repo.test/broken.png');
      final selected = <CatalogueExtension>[];
      await _open(tester, entry, onInstall: selected.add);
      expect(requests, [Uri.parse(entry.iconUrl)]);
      expect(
        find.byKey(const ValueKey('extension-icon-placeholder')),
        findsOneWidget,
      );
      expect(tester.getSize(find.byType(ClipRRect)), const Size(38, 38));
      await tester.tap(find.text('Cài'));
      expect(selected.single, same(entry));
      await _dispose(tester);
    },
  );

  testWidgets(
    'a missing catalogue icon keeps the optional-field fallback without an image request',
    (tester) async {
      await _open(tester, _extension());
      expect(find.byType(Image), findsNothing);
      expect(
        find.byKey(const ValueKey('extension-icon-placeholder')),
        findsOneWidget,
      );
      expect(find.text('Cài'), findsOneWidget);
      await _dispose(tester);
    },
  );

  testWidgets(
    'an installed package reuses its matching catalogue icon when the engine has no icon field',
    (tester) async {
      final requests = <Uri>[];
      final png = await _png(tester);
      debugNetworkImageHttpClientProvider = () => _IconClient(requests, png);
      final entry = _extension(icon: 'https://repo.test/icons/plugin.png');
      await _open(tester, entry, installed: [_extension(installed: true)]);
      await _waitForImage(tester);
      expect(requests, [Uri.parse(entry.iconUrl)]);
      expect(find.byType(Image), findsNWidgets(2));
      expect(
        find.byKey(const ValueKey('extension-icon-placeholder')),
        findsNothing,
      );
      expect(find.text('Đã cài'), findsNWidgets(2));
      expect(find.text('Cài'), findsNothing);
      await _dispose(tester);
    },
  );
}

Future<Uint8List> _png(WidgetTester tester) async =>
    (await tester.runAsync(() async {
      final recorder = ui.PictureRecorder();
      Canvas(
        recorder,
      ).drawRect(const Rect.fromLTWH(0, 0, 8, 8), Paint()..color = Colors.blue);
      final picture = recorder.endRecording();
      final image = await picture.toImage(8, 8);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      final bytes = data!.buffer.asUint8List();
      image.dispose();
      picture.dispose();
      return bytes;
    }))!;

Future<void> _waitForImage(WidgetTester tester) async {
  await tester.runAsync(() async {
    await Future.wait(
      tester.widgetList<Image>(find.byType(Image)).map((image) {
        final done = Completer<void>();
        final stream = image.image.resolve(ImageConfiguration.empty);
        late ImageStreamListener listener;
        listener = ImageStreamListener(
          (_, _) {
            stream.removeListener(listener);
            done.complete();
          },
          onError: (Object error, StackTrace? stack) {
            stream.removeListener(listener);
            done.completeError(error, stack);
          },
        );
        stream.addListener(listener);
        return done.future;
      }),
    );
  });
  await tester.pumpAndSettle();
}

Future<void> _dispose(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pumpAndSettle();
  debugNetworkImageHttpClientProvider = null;
  expect(tester.takeException(), isNull);
}

class _IconClient extends Fake implements HttpClient {
  _IconClient(this.requests, this.png, {this.fail = false});
  final List<Uri> requests;
  final Uint8List png;
  final bool fail;
  @override
  Future<HttpClientRequest> getUrl(Uri url) async {
    requests.add(url);
    if (fail) throw const SocketException('Fixture icon unavailable');
    return _IconRequest(png);
  }
}

class _IconRequest extends Fake implements HttpClientRequest {
  _IconRequest(this.png);
  final Uint8List png;
  @override
  final HttpHeaders headers = _IconHeaders();
  @override
  Future<HttpClientResponse> close() async => _IconResponse(png);
}

class _IconHeaders extends Fake implements HttpHeaders {
  @override
  void add(String name, Object value, {bool preserveHeaderCase = false}) {}
}

class _IconResponse extends Stream<List<int>> implements HttpClientResponse {
  _IconResponse(this.bytes);
  final Uint8List bytes;
  @override
  int get statusCode => 200;
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
