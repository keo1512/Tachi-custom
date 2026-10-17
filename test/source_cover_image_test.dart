import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tachi_books/features/library/domain/library_book.dart';
import 'package:tachi_books/features/library/presentation/library_view_model.dart';
import 'package:tachi_books/features/sources/data/source_repository.dart';
import 'package:tachi_books/features/sources/domain/catalogue.dart';
import 'package:tachi_books/features/sources/presentation/source_cover_image.dart';

const _png =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+ip1sAAAAASUVORK5CYII=';

CatalogueBook _book({
  String source = '2553532324170433933',
  String cover = 'https://images.example/cover.jpg',
  String ref = '/title',
}) => CatalogueBook(
  ref: ref,
  title: 'Title',
  coverUrl: cover,
  sourceId: source,
  kind: ContentKind.manga,
  engine: SourceEngine.tachimanga,
);

class _Covers extends SourceRepository {
  _Covers({this.native = true}) : super(tachimangaUrl: '', vbookUrl: '');
  final bool native;
  int calls = 0;
  bool fail = false;
  Uint8List? bytes;
  Completer<void>? pending;
  @override
  bool usesNativeCoverLoader(CatalogueBook book) => native;
  @override
  Future<SourceImageData> fetchCover(CatalogueBook book) async {
    calls++;
    await pending?.future;
    if (fail) {
      throw const ApiException('Cover failed', code: 'extension_failed');
    }
    return SourceImageData(
      bytes: bytes ?? base64Decode(_png),
      mimeType: 'image/png',
    );
  }
}

final _coverRouteProvider = NotifierProvider<_CoverRoute, bool>(
  _CoverRoute.new,
);

class _CoverRoute extends Notifier<bool> {
  @override
  bool build() => false;

  void changeRoute() => state = true;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tearDown(() {
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
  });

  Future<void> mount(
    WidgetTester tester,
    SourceRepository repository,
    Widget Function(WidgetRef ref) child,
  ) => tester.pumpWidget(
    ProviderScope(
      overrides: [sourceRepositoryProvider.overrideWithValue(repository)],
      child: MaterialApp(home: Consumer(builder: (_, ref, _) => child(ref))),
    ),
  );

  Future<void> waitForDecodedImages(WidgetTester tester) async {
    for (var attempt = 0; attempt < 100; attempt++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
      final images = tester.widgetList<RawImage>(find.byType(RawImage));
      if (images.isNotEmpty && images.every((image) => image.image != null)) {
        return;
      }
    }
    fail('Cover image did not finish decoding.');
  }

  test('native image cache keys isolate source, book, URL and repository', () {
    final first = _Covers();
    final second = _Covers();
    addTearDown(first.dispose);
    addTearDown(second.dispose);
    final image = SourceCoverImage(repository: first, book: _book());
    expect(image, SourceCoverImage(repository: first, book: _book()));
    expect(
      image.hashCode,
      SourceCoverImage(repository: first, book: _book()).hashCode,
    );
    for (final other in [
      SourceCoverImage(repository: second, book: _book()),
      SourceCoverImage(
        repository: first,
        book: _book(source: '9223372036854775806'),
      ),
      SourceCoverImage(
        repository: first,
        book: _book(ref: '/other'),
      ),
      SourceCoverImage(
        repository: first,
        book: _book(cover: 'https://images.example/new.jpg'),
      ),
    ]) {
      expect(image, isNot(other));
    }
    expect(image.toString(), isNot(contains('images.example')));
  });

  testWidgets(
    'clearing cover cache reloads a mounted image without replacing the runtime repository',
    (tester) async {
      final repository = _Covers();
      addTearDown(repository.dispose);
      await mount(
        tester,
        repository,
        (ref) => Column(
          children: [
            Image(image: sourceCoverImage(ref, _book())!),
            TextButton(
              onPressed: () =>
                  ref.read(coverRefreshRevisionProvider.notifier).invalidate(),
              child: const Text('Reload covers'),
            ),
          ],
        ),
      );
      await waitForDecodedImages(tester);
      expect(repository.calls, 1);
      await tester.tap(find.text('Reload covers'));
      await tester.pump();
      await waitForDecodedImages(tester);
      expect(repository.calls, 2);
    },
  );

  testWidgets('catalogue and backdrop share one native fetch and decode', (
    tester,
  ) async {
    final repository = _Covers()..pending = Completer<void>();
    addTearDown(repository.dispose);
    await mount(
      tester,
      repository,
      (ref) => Row(
        children: [
          for (var i = 0; i < 2; i++)
            Image(
              image: sourceCoverImage(ref, _book())!,
              errorBuilder: (_, _, _) => const Text('failed'),
            ),
        ],
      ),
    );
    await tester.pump();
    expect(repository.calls, 1);
    repository.pending!.complete();
    await tester.pumpAndSettle();
    await waitForDecodedImages(tester);
    expect(find.text('failed'), findsNothing);
    expect(
      tester
          .widgetList<RawImage>(find.byType(RawImage))
          .every((image) => image.image != null),
      isTrue,
    );
    expect(repository.calls, 1);
  });

  testWidgets('failed native fetch is evicted so a remount retries', (
    tester,
  ) async {
    final repository = _Covers()..fail = true;
    addTearDown(repository.dispose);
    Widget child(WidgetRef ref) => Image(
      image: sourceCoverImage(ref, _book())!,
      errorBuilder: (_, _, _) => const Text('failed'),
    );
    await mount(tester, repository, child);
    await tester.pumpAndSettle();
    expect(find.text('failed'), findsOneWidget);
    expect(repository.calls, 1);
    await tester.pumpWidget(const SizedBox.shrink());
    repository.fail = false;
    await mount(tester, repository, child);
    await tester.pumpAndSettle();
    await waitForDecodedImages(tester);
    expect(repository.calls, 2);
    expect(find.text('failed'), findsNothing);
  });

  testWidgets('mounted covers follow a changed runtime routing repository', (
    tester,
  ) async {
    final first = _Covers();
    final second = _Covers();
    addTearDown(first.dispose);
    addTearDown(second.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sourceRepositoryProvider.overrideWith(
            (ref) => ref.watch(_coverRouteProvider) ? second : first,
          ),
        ],
        child: MaterialApp(
          home: Consumer(
            builder: (_, ref, _) => Image(
              image: sourceCoverImage(ref, _book())!,
              errorBuilder: (_, _, _) => const Text('failed'),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await waitForDecodedImages(tester);
    expect(first.calls, 1);
    expect(second.calls, 0);

    final container = ProviderScope.containerOf(
      tester.element(find.byType(Image)),
    );
    container.read(_coverRouteProvider.notifier).changeRoute();
    await tester.pumpAndSettle();
    await waitForDecodedImages(tester);
    expect(second.calls, 1);
    expect(first.calls, 1);
    expect(find.text('failed'), findsNothing);
  });

  testWidgets('native oversized bytes fail before image decoding', (
    tester,
  ) async {
    final repository = _Covers()..bytes = Uint8List(8 * 1024 * 1024 + 1);
    addTearDown(repository.dispose);
    await mount(
      tester,
      repository,
      (ref) => Image(
        image: sourceCoverImage(ref, _book())!,
        errorBuilder: (_, _, _) => const Text('failed'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('failed'), findsOneWidget);
    expect(repository.calls, 1);
  });

  testWidgets(
    'local covers stay stable and never initialize the source repository',
    (tester) async {
      ImageProvider<Object>? first;
      ImageProvider<Object>? second;
      final book = LibraryBook(
        id: 'local',
        title: 'Local',
        engine: 'local',
        cover: 'data:image/png;base64,$_png',
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            sourceRepositoryProvider.overrideWith(
              (ref) => throw StateError('No engine for local cover'),
            ),
          ],
          child: MaterialApp(
            home: Consumer(
              builder: (_, ref, _) {
                first = libraryCoverImage(ref, book);
                second = libraryCoverImage(
                  ref,
                  book.copyWith(title: 'Renamed'),
                );
                return Image(
                  image: first!,
                  errorBuilder: (_, _, _) => const Text('failed'),
                );
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await waitForDecodedImages(tester);
      expect(first, second);
      expect(find.text('failed'), findsNothing);
      expect(first.toString(), isNot(contains(_png)));
    },
  );

  testWidgets('companions retain NetworkImage and invalid URLs do not load', (
    tester,
  ) async {
    final repository = _Covers(native: false);
    addTearDown(repository.dispose);
    await mount(tester, repository, (ref) {
      expect(sourceCoverImage(ref, _book()), isA<NetworkImage>());
      expect(
        sourceCoverImage(ref, _book(cover: 'file:///private/cover')),
        isNull,
      );
      expect(
        sourceCoverImage(
          ref,
          _book(cover: 'https://user:pass@example.test/cover'),
        ),
        isNull,
      );
      expect(sourceCoverImage(ref, _book(cover: '')), isNull);
      return const SizedBox.shrink();
    });
    expect(repository.calls, 0);
  });
}
