import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tachi_books/features/library/data/library_repository.dart';
import 'package:tachi_books/features/library/data/library_snapshot.dart';
import 'package:tachi_books/features/library/domain/library_book.dart';
import 'package:tachi_books/features/library/presentation/library_view_model.dart';
import 'package:tachi_books/features/reader/presentation/reader_screen.dart';
import 'package:tachi_books/features/reader/presentation/native_manga_image_window.dart';
import 'package:tachi_books/features/settings/settings_controller.dart';
import 'package:tachi_books/features/sources/data/source_repository.dart';
import 'package:tachi_books/features/sources/domain/catalogue.dart';

const _url = 'https://fixture.invalid/encrypted-page';
const _png =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=';

LibraryBook _book() => LibraryBook(
  id: 'native-images',
  title: 'Native images',
  engine: 'tachimanga',
  kind: 'manga',
  sourceId: '9223372036854775806',
  sourceRef: '/series',
  chapters: const [
    BookChapter(
      id: '/chapter',
      title: 'Original chapter',
      index: 7,
      read: false,
    ),
  ],
);

class _ImageSource extends SourceRepository {
  _ImageSource() : super(tachimangaUrl: '', vbookUrl: '');
  final pages = <int>[];
  bool failSecond = false;
  int browserCalls = 0;
  Completer<void>? blocked;
  int count = 2;
  @override
  bool usesNativeImageLoader(CatalogueBook book) => true;
  @override
  bool canOpenNativeWebsite(CatalogueBook book) => true;
  @override
  Future<void> openWebsite(CatalogueBook book) async {
    browserCalls++;
    failSecond = false;
  }

  @override
  Future<ChapterContent> chapter(
    CatalogueBook book,
    CatalogueChapter chapter,
  ) async =>
      ChapterContent(kind: ContentKind.manga, images: List.filled(count, _url));
  @override
  Future<SourceImageData> fetchImage(
    CatalogueBook book,
    CatalogueChapter chapter,
    int page,
    String url,
  ) async {
    expect(book.sourceId, '9223372036854775806');
    expect(chapter.ref, '/chapter');
    expect(chapter.index, 7);
    expect(url, _url);
    pages.add(page);
    if (blocked != null) await blocked!.future;
    if (page == 1 && failSecond) {
      throw const ApiException('Image transform failed');
    }
    return SourceImageData(
      bytes: Uint8List.fromList([...base64Decode(_png)]),
      mimeType: 'image/png',
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('flutter_tts'),
          (_) async => 1,
        );
  });

  Future<(ProviderContainer, MemoryLibraryRepository, LibraryBook)> setup(
    _ImageSource source,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    final repo = MemoryLibraryRepository();
    final book = _book();
    await repo.save(book);
    final container = ProviderContainer(
      overrides: [
        preferencesProvider.overrideWithValue(prefs),
        libraryRepositoryProvider.overrideWithValue(repo),
        sourceRepositoryProvider.overrideWithValue(source),
        chapterHttpClientProvider.overrideWithValue(
          MockClient((request) async {
            fail(
              'Native image bytes must come from the extension, not raw HTTP',
            );
          }),
        ),
      ],
    );
    await container.read(libraryProvider.future);
    return (container, repo, book);
  }

  test('offline download runs each original page through the engine even with identical URLs', () async {
    final source = _ImageSource();
    final (container, repo, book) = await setup(source);
    addTearDown(container.dispose);
    final result = await container
        .read(libraryProvider.notifier)
        .getContent(book, 0, download: true);
    expect(source.pages, [0, 1]);
    expect(
      result.images.every((url) => url.startsWith('data:image/png;base64,')),
      true,
    );
    final stored = await repo.find(book.id);
    expect(stored!.chapters.single.downloaded, true);
    expect(stored.chapters.single.read, false);
    source.pages.clear();
    await container
        .read(libraryProvider.notifier)
        .getContent(stored, 0, download: true);
    expect(source.pages, isEmpty);
  });

  test('failed transformation preserves completed pages and retries the missing original index', () async {
    final source = _ImageSource()..failSecond = true;
    final (container, repo, book) = await setup(source);
    addTearDown(container.dispose);
    final vm = container.read(libraryProvider.notifier);
    await expectLater(
      vm.getContent(book, 0, download: true),
      throwsA(isA<ApiException>()),
    );
    final partial = await repo.openChapter(book.id, '/chapter');
    expect(partial!.content!.images.first.startsWith('data:'), true);
    expect(partial.content!.images.last, _url);
    expect(partial.book.chapters.single.downloaded, false);
    source.pages.clear();
    source.failSecond = false;
    await vm.getContent(partial.book, 0, download: true);
    expect(source.pages, [1]);
  });

  test('restore while a native image request is pending cannot overwrite the replacement library', () async {
    final source = _ImageSource()..blocked = Completer<void>();
    final (container, repo, book) = await setup(source);
    addTearDown(container.dispose);
    final pending = container
        .read(libraryProvider.notifier)
        .getContent(book, 0, download: true);
    await Future<void>.delayed(Duration.zero);
    final expectation = expectLater(pending, throwsA(isA<StateError>()));
    await repo.replaceSnapshot(
      LibrarySnapshot([
        LibrarySnapshotEntry(
          LibraryBook(id: 'replacement', title: 'Replacement'),
          {},
        ),
      ]),
      expectedFingerprint: (await repo.snapshot()).fingerprint,
    );
    source.blocked!.complete();
    await expectation;
    expect((await repo.list()).map((item) => item.id), ['replacement']);
  });

  testWidgets(
    'page retry fetches only the failed original page and keeps its neighbour',
    (tester) async {
      final source = _ImageSource()..failSecond = true;
      final (container, _, book) = await setup(source);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(home: ReaderScreen(id: book.id)),
        ),
      );
      await tester.pumpAndSettle();
      expect(source.pages, [0, 1]);
      expect(find.text('Không tải được ảnh'), findsOneWidget);
      final retry = find.text('Thử lại ảnh');
      await tester.ensureVisible(retry);
      await tester.pumpAndSettle();
      source.failSecond = false;
      await tester.tap(retry);
      // The page's double-tap zoom recognizer delays the first tap.
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();
      expect(source.pages, [0, 1, 1]);
      expect(find.text('Không tải được ảnh'), findsNothing);
      expect(find.byType(Image), findsNWidgets(2));
      expect(
        (await container.read(libraryRepositoryProvider).find(book.id))!
            .chapters
            .single
            .downloaded,
        false,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      container.dispose();
    },
  );

  testWidgets(
    'retry from a reader opened before restore cannot fetch the replacement library',
    (tester) async {
      final source = _ImageSource()..failSecond = true;
      final (container, repo, book) = await setup(source);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(home: ReaderScreen(id: book.id)),
        ),
      );
      await tester.pumpAndSettle();
      expect(source.pages, [0, 1]);
      await repo.clear();
      await repo.save(book.copyWith(title: 'Replacement'));
      final replacement = (await repo.snapshot()).encode();
      source.failSecond = false;
      final retry = find.text('Thử lại ảnh');
      await tester.ensureVisible(retry);
      await tester.tap(retry);
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();
      expect(source.pages, [0, 1]);
      expect((await repo.snapshot()).encode(), replacement);
      expect(
        find.text(
          'Thư viện đã được thay đổi hoặc khôi phục. Hãy mở lại sách trước khi tiếp tục.',
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      container.dispose();
    },
  );

  testWidgets(
    'reader renders engine bytes and does not reload them when toggling controls',
    (tester) async {
      final source = _ImageSource();
      final (container, repo, book) = await setup(source);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(home: ReaderScreen(id: book.id)),
        ),
      );
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        for (final image in tester.widgetList<Image>(find.byType(Image))) {
          expect(image.image, isA<ResizeImage>());
          expect(
            (image.image as ResizeImage).imageProvider,
            isA<MemoryImage>(),
          );
          final stream = image.image.resolve(ImageConfiguration.empty);
          final ready = Completer<void>();
          late ImageStreamListener listener;
          listener = ImageStreamListener(
            (_, _) {
              stream.removeListener(listener);
              ready.complete();
            },
            onError: (error, stack) {
              stream.removeListener(listener);
              ready.completeError(error, stack);
            },
          );
          stream.addListener(listener);
          await ready.future;
        }
      });
      await tester.pumpAndSettle();
      expect(find.byType(Image), findsNWidgets(2));
      expect(source.pages, [0, 1]);
      await tester.tapAt(const Offset(12, 200));
      await tester.pumpAndSettle();
      expect(source.pages, [0, 1]);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      container.dispose();
    },
  );

  testWidgets(
    'long pages keep their full layout while their decoded bitmap and image cache are bounded',
    (tester) async {
      tester.view.devicePixelRatio = 3;
      tester.view.physicalSize = const Size(1290, 2796);
      addTearDown(tester.view.reset);
      final data = (await tester.runAsync(() async {
        final recorder = ui.PictureRecorder();
        Canvas(recorder).drawRect(
          const Rect.fromLTWH(0, 0, 1000, 5000),
          Paint()..color = Colors.blue,
        );
        final picture = recorder.endRecording();
        final image = await picture.toImage(1000, 5000);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        image.dispose();
        picture.dispose();
        return SourceImageData(
          bytes: bytes!.buffer.asUint8List(),
          mimeType: 'image/png',
        );
      }))!;
      final loaded = NativeMangaImage(data, 1000, 5000);
      await tester.pumpWidget(
        MaterialApp(
          home: SingleChildScrollView(
            child: NativeMangaPage(
              image: loaded,
              aspectRatio: .2,
              error: null,
              loading: false,
              onReady: (_) {},
            ),
          ),
        ),
      );
      final image = tester.widget<Image>(find.byType(Image));
      final provider = image.image as ResizeImage;
      expect(
        provider.width! * provider.height!,
        lessThanOrEqualTo(4 * 1024 * 1024),
      );
      expect(provider.width, lessThan(1000));
      expect(provider.height, lessThanOrEqualTo(8192));
      expect(provider.policy, ResizeImagePolicy.fit);
      expect(
        tester.getSize(find.byType(NativeMangaPage)).height,
        closeTo(430 * 5, .01),
      );
      await tester.runAsync(() async {
        final ready = Completer<void>();
        final stream = provider.resolve(ImageConfiguration.empty);
        late ImageStreamListener listener;
        listener = ImageStreamListener((decoded, _) {
          expect(
            decoded.image.width * decoded.image.height,
            lessThanOrEqualTo(4 * 1024 * 1024),
          );
          stream.removeListener(listener);
          ready.complete();
        });
        stream.addListener(listener);
        await ready.future;
      });
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      final key = await provider.obtainKey(ImageConfiguration.empty);
      expect(
        PaintingBinding.instance.imageCache.statusForKey(key).tracked,
        false,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'native resume preserves the within-page fraction while neighbour heights load',
    (tester) async {
      final source = _ImageSource()..count = 20;
      final (container, repo, book) = await setup(source);
      await repo.save(book.copyWith(progress: .625));
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(home: ReaderScreen(id: book.id)),
        ),
      );
      await tester.pumpAndSettle();
      expect(source.pages, [12, 11, 13, 10, 14]);
      final target = find.byKey(const ValueKey('native-page:1:12'));
      final viewport = tester.getRect(find.byType(SingleChildScrollView));
      final page = tester.getRect(target);
      expect(page.top, closeTo(viewport.top - page.height * .5, 1));
      expect((await repo.find(book.id))!.progress, closeTo(.625, .0001));
      expect(find.byType(Image), findsNWidgets(5));
      final slider = find.byKey(const ValueKey('reader-position-slider'));
      for (final index in [17, 3, 12]) {
        tester.widget<CupertinoSlider>(slider).onChanged!(index.toDouble());
        await tester.runAsync(() async {
          await Future<void>.delayed(const Duration(milliseconds: 60));
        });
        await tester.pumpAndSettle();
        expect(find.byType(Image), findsNWidgets(5));
        expect(
          tester
              .widgetList<NativeMangaPage>(find.byType(NativeMangaPage))
              .where((page) => page.image != null)
              .length,
          5,
        );
      }
      expect(source.pages.where((i) => i == 12).length, 2);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      container.dispose();
    },
  );

  testWidgets(
    'a blocked page cannot block seeking a 1000-page native chapter or queue intermediate pages',
    (tester) async {
      final gate = Completer<void>();
      final source = _ImageSource()
        ..count = 1000
        ..blocked = gate;
      final (container, repo, book) = await setup(source);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(home: ReaderScreen(id: book.id)),
        ),
      );
      // Do not settle the deliberately pending native request/spinner.
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(source.pages, [0]);
      final slider = find.byKey(const ValueKey('reader-position-slider'));
      for (final page in [50, 400, 700, 999]) {
        tester.widget<CupertinoSlider>(slider).onChanged!(page.toDouble());
      }
      await tester.pump();
      await tester.pump();
      final scroll = tester
          .widget<SingleChildScrollView>(find.byType(SingleChildScrollView))
          .controller!;
      expect(tester.widget<CupertinoSlider>(slider).value, 999);
      expect(scroll.offset, greaterThan(scroll.position.maxScrollExtent * .99));
      expect(source.pages, [0]);
      expect(find.byType(CircularProgressIndicator), findsNWidgets(3));
      gate.complete();
      await tester.runAsync(() async {
        for (var i = 0; i < 40 && source.pages.length < 4; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
      });
      await tester.pumpAndSettle();
      expect(source.pages, [0, 999, 998, 997]);
      expect(
        tester
            .widgetList<NativeMangaPage>(find.byType(NativeMangaPage))
            .where((page) => page.image != null)
            .length,
        3,
      );
      expect(find.byType(Image), findsNWidgets(3));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      container.dispose();
    },
  );

  testWidgets(
    'reader retries failed native pages after completing the source browser',
    (tester) async {
      final source = _ImageSource()..failSecond = true;
      final (container, repo, book) = await setup(source);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(home: ReaderScreen(id: book.id)),
        ),
      );
      await tester.pumpAndSettle();
      expect(source.pages, [0, 1]);
      expect(find.byType(Image), findsOneWidget);
      expect(find.byTooltip('Xem trang web'), findsOneWidget);
      await tester.tap(find.byTooltip('Xem trang web'));
      await tester.pumpAndSettle();
      expect(source.browserCalls, 1);
      expect(source.pages, [0, 1, 0, 1]);
      expect(find.byType(Image), findsNWidgets(2));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      container.dispose();
    },
  );
}
