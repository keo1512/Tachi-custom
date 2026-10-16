import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tachi_books/core/widgets/book_cover.dart';
import 'package:tachi_books/features/library/domain/library_book.dart';
import 'package:tachi_books/features/library/presentation/activity_book_cover.dart';
import 'package:tachi_books/features/library/presentation/book_detail_header.dart';
import 'package:tachi_books/features/library/presentation/library_book_metadata.dart';
import 'package:tachi_books/features/library/presentation/library_book_tile.dart';
import 'package:tachi_books/features/library/presentation/library_filter_sheet.dart';
import 'package:tachi_books/features/library/presentation/library_source_label.dart';
import 'package:tachi_books/features/sources/domain/catalogue.dart';
import 'package:tachi_books/features/sources/presentation/source_result_tile.dart';

void main() {
  final bytes = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+ip1sAAAAASUVORK5CYII=',
  );
  final book = LibraryBook(
    id: 'stable-library-id',
    title: 'Một tựa truyện',
    engine: 'tachimanga',
    sourceId: '2550859402019262988',
    sourceName: 'TruyenQQ',
    sourceRef: '/truyen/mot-tua-truyen',
    cover: 'https://covers.example/cover.jpg',
  );

  test('source labels use verified name, URL host or friendly fallback', () {
    expect(librarySourceLabel(book), 'TruyenQQ');
    expect(
      librarySourceLabel(
        book.copyWith(
          sourceName: '',
          sourceRef: 'https://truyenqq.example/truyen/mot-tua-truyen',
        ),
      ),
      'truyenqq.example',
    );
    expect(
      librarySourceLabel(book.copyWith(sourceName: book.sourceId)),
      'Nguồn Tachimanga',
    );
    expect(
      librarySourceLabel(book.copyWith(sourceName: '', engine: 'vbook')),
      'Nguồn vBook',
    );
    expect(
      librarySourceLabel(book.copyWith(engine: 'local')),
      'Trong thiết bị',
    );
    expect(book.sourceId, '2550859402019262988');
  });

  for (final size in const [Size(320, 568), Size(430, 932)]) {
    testWidgets(
      'detail displays source name and shared injected cover at $size',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = size;
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });
        final before = book.toJson();
        final provider = MemoryImage(bytes);
        Future<void> mount(ImageProvider<Object> image) async {
          await tester.pumpWidget(
            MaterialApp(
              home: MediaQuery(
                data: MediaQueryData(
                  size: size,
                  textScaler: TextScaler.linear(1.5),
                ),
                child: Scaffold(
                  body: SingleChildScrollView(
                    child: BookDetailHeader(
                      book: book,
                      coverImage: image,
                      descriptionExpanded: false,
                      onToggleDescription: () {},
                      onFavorite: () {},
                      onEditNotes: () {},
                      onResume: () {},
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
        }

        await mount(provider);
        expect(find.text('TruyenQQ'), findsOneWidget);
        expect(find.textContaining(book.sourceId), findsNothing);
        final images = tester.widgetList<Image>(find.byType(Image)).toList();
        expect(images, hasLength(2));
        expect(
          images.every((image) => identical(image.image, provider)),
          isTrue,
        );
        expect(tester.takeException(), isNull);

        // A new image provider must replace both artwork layers while the book's
        // stored cover URL stays the same (for example after a source refresh).
        final replacement = MemoryImage(base64Decode(base64Encode(bytes)));
        await mount(replacement);
        expect(
          tester
              .widgetList<Image>(find.byType(Image))
              .every((image) => identical(image.image, replacement)),
          isTrue,
        );
        expect(book.toJson(), before);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'cover consumers preserve injected provider without ProviderScope',
    (tester) async {
      final provider = MemoryImage(bytes);
      const filter = LibraryFilter(showSource: true);
      final catalogue = CatalogueBook(
        ref: book.sourceRef,
        title: book.title,
        coverUrl: book.cover,
        sourceId: book.sourceId,
        kind: ContentKind.manga,
        engine: SourceEngine.tachimanga,
      );
      for (final child in <Widget>[
        BookCover(
          title: book.title,
          cover: book.cover,
          imageProvider: provider,
        ),
        LibraryBookTile(book: book, filter: filter, coverImage: provider),
        SourceResultTile(book: catalogue, onOpen: () {}, coverImage: provider),
        SourceResultTile(
          book: catalogue,
          onOpen: () {},
          coverImage: provider,
          list: true,
        ),
        ActivityBookCover(book, coverImage: provider),
      ]) {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Center(
                child: SizedBox(width: 200, height: 300, child: child),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.widget<Image>(find.byType(Image)).image, same(provider));
        expect(tester.takeException(), isNull);
      }
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: LibraryBookMetadata(book: book, filter: filter),
          ),
        ),
      );
      expect(find.text('TruyenQQ'), findsOneWidget);
      expect(find.textContaining(book.sourceId), findsNothing);
    },
  );

  testWidgets(
    'standalone detail data cover shares one provider for both layers',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: BookDetailHeader(
                book: book.copyWith(
                  cover: 'data:image/png;base64,${base64Encode(bytes)}',
                ),
                descriptionExpanded: false,
                onToggleDescription: () {},
                onFavorite: () {},
                onEditNotes: () {},
                onResume: () {},
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final images = tester.widgetList<Image>(find.byType(Image)).toList();
      expect(images, hasLength(2));
      expect(images[0].image, same(images[1].image));
      expect(tester.takeException(), isNull);
    },
  );
}
