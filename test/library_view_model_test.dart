import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tachi_books/features/library/data/library_repository.dart';
import 'package:tachi_books/features/library/domain/library_book.dart';
import 'package:tachi_books/features/library/presentation/library_view_model.dart';
import 'package:tachi_books/features/sources/data/source_repository.dart';
import 'package:tachi_books/features/sources/domain/catalogue.dart';

class FixtureSource extends SourceRepository {
  FixtureSource(this.order, {this.content})
    : super(
        tachimangaUrl: 'http://localhost:4567',
        vbookUrl: 'http://localhost:4570',
      );
  List<String> order;
  ChapterContent? content;
  int chapterCalls = 0;
  @override
  Future<List<CatalogueChapter>> chapters(CatalogueBook book) async =>
      List.generate(
        order.length,
        (i) => CatalogueChapter(ref: order[i], title: order[i], index: i),
      );
  @override
  Future<ChapterContent> chapter(
    CatalogueBook book,
    CatalogueChapter chapter,
  ) async {
    chapterCalls++;
    return content ??
        ChapterContent(kind: ContentKind.novel, html: '<p>${chapter.ref}</p>');
  }
}

class OversizedImageClient extends http.BaseClient {
  int chunksRead = 0;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    Stream<List<int>> stream() async* {
      for (var i = 0; i < 20; i++) {
        chunksRead++;
        yield Uint8List(1024 * 1024);
      }
    }

    return http.StreamedResponse(
      stream(),
      200,
      headers: {'content-type': 'image/png'},
    );
  }
}

class PausingRepository extends MemoryLibraryRepository {
  final started = Completer<void>();
  final release = Completer<void>();
  bool pauseNextSave = false;

  @override
  Future<void> save(LibraryBook book) async {
    if (pauseNextSave) {
      pauseNextSave = false;
      started.complete();
      await release.future;
    }
    await super.save(book);
  }
}

LibraryBook fixtureBook({String kind = 'novel'}) => LibraryBook(
  id: 'book',
  title: 'Fixture',
  kind: kind,
  engine: 'vbook',
  sourceId: 'fixture',
  sourceRef: 'book-ref',
  currentChapter: 1,
  progress: .5,
  bookmarks: ['1:0.5000', '2:0.2500'],
  chapters: List.generate(
    3,
    (i) => BookChapter(
      id: ['a', 'b', 'c'][i],
      title: ['a', 'b', 'c'][i],
      index: i,
      downloaded: true,
    ),
  ),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('queued metadata and history edits preserve downloaded chapters, progress and bookmarks', () async {
    final repo = PausingRepository();
    final original = fixtureBook().copyWith(
      chapters: fixtureBook().chapters
          .map((chapter) => chapter.copyWith(downloaded: false))
          .toList(),
      lastRead: DateTime.utc(2026, 10, 8),
    );
    await repo.save(original);
    final source = FixtureSource(['a', 'b', 'c']);
    final container = ProviderContainer(
      overrides: [
        libraryRepositoryProvider.overrideWithValue(repo),
        sourceRepositoryProvider.overrideWithValue(source),
      ],
    );
    addTearDown(container.dispose);
    await container.read(libraryProvider.future);
    final vm = container.read(libraryProvider.notifier);

    // Pause after real chapter bytes are cached but before the downloaded flag
    // is persisted. Simulate edits while an older detail screen is still open.
    repo.pauseNextSave = true;
    final download = vm.getContent(original, 0, download: true);
    await repo.started.future;
    final progress = vm.updateProgress('book', 'b', .75);
    final metadata = vm.updateMetadata(
      'book',
      favorite: true,
      completed: true,
      collection: 'Kệ cá nhân',
    );
    final bookmark = vm.toggleBookmark('book', 'c', .42);
    final history = vm.clearHistory(['book', 'already-removed']);
    repo.release.complete();
    await Future.wait([download, progress, metadata, bookmark, history]);

    final restored = (await repo.find('book'))!;
    expect(restored.chapters.map((chapter) => chapter.id), ['a', 'b', 'c']);
    expect(restored.chapters.map((chapter) => chapter.downloaded), [
      true,
      false,
      false,
    ]);
    expect((await repo.readChapter('book', 0))!.html, '<p>a</p>');
    expect(restored.currentChapter, 1);
    expect(restored.progress, closeTo(1.75 / 3, .000001));
    expect(restored.bookmarks, ['1:0.5000', '2:0.2500', '2:0.4200']);
    expect(restored.favorite, isTrue);
    expect(restored.completed, isTrue);
    expect(restored.collection, 'Kệ cá nhân');
    expect(restored.lastRead, isNull);
    expect(source.chapterCalls, 1);
    expect(await repo.find('already-removed'), isNull);
    expect(
      container.read(libraryProvider).requireValue.single.toJson(),
      restored.toJson(),
    );
  });
  test('reordering updates moves cache, read position and bookmarks by chapter identity', () async {
    final repo = MemoryLibraryRepository();
    final original = fixtureBook();
    await repo.save(original);
    for (var i = 0; i < original.chapters.length; i++) {
      await repo.saveChapter(
        original.id,
        i,
        ReaderContent(kind: 'novel', html: original.chapters[i].id),
      );
    }
    final source = FixtureSource(['new', 'c', 'b', 'a']);
    final container = ProviderContainer(
      overrides: [
        libraryRepositoryProvider.overrideWithValue(repo),
        sourceRepositoryProvider.overrideWithValue(source),
      ],
    );
    addTearDown(container.dispose);
    await container.read(libraryProvider.future);
    final vm = container.read(libraryProvider.notifier);
    expect(await vm.updateAll(), 1);
    final book = (await repo.find('book'))!;
    expect(book.currentChapter, 2);
    expect(book.progress, closeTo(2.5 / 4, .000001));
    expect(book.bookmarks, ['2:0.5000', '1:0.2500']);
    expect(await repo.readChapter('book', 0), isNull);
    expect((await repo.readChapter('book', 1))!.html, 'c');
    expect((await repo.readChapter('book', 2))!.html, 'b');
    expect((await repo.readChapter('book', 3))!.html, 'a');
    // A reader that still holds the original book must retrieve b, not new index 1's c.
    expect((await vm.getContent(original, 1)).html, 'b');
    await vm.updateProgress('book', 'b', .75);
    expect((await repo.find('book'))!.progress, closeTo(2.75 / 4, .000001));
    source.order = ['a'];
    await vm.updateAll();
    expect((await repo.readChapter('book', 0))!.html, 'a');
    expect(await repo.readChapter('book', 1), isNull);
    expect((await repo.find('book'))!.bookmarks, isEmpty);
    expect(source.chapterCalls, 0);
  });

  test('web chapter remap rolls back metadata and cache when persistence exceeds capacity', () async {
    SharedPreferences.setMockInitialValues({});
    final repo = await LibraryRepository.openWebPreview();
    final book = fixtureBook();
    await repo.save(book);
    await repo.saveChapter(
      'book',
      0,
      ReaderContent(kind: 'novel', html: 'x' * (2500 * 1024)),
    );
    final replacement = book.copyWith(
      description: 'x' * (1750 * 1024),
      chapters: [book.chapters[2], book.chapters[0], book.chapters[1]],
    );
    await expectLater(
      repo.replaceChapterOrder(replacement, [2, 0, 1]),
      throwsFormatException,
    );
    expect((await repo.find('book'))!.chapters.first.id, 'a');
    expect((await repo.find('book'))!.description, isEmpty);
    expect((await repo.readChapter('book', 0))!.html.length, 2500 * 1024);
    expect(await repo.readChapter('book', 1), isNull);
  });

  test('cached novel remains online until embedded images download with their own headers', () async {
    final repo = MemoryLibraryRepository();
    final book = fixtureBook().copyWith(
      chapters: [const BookChapter(id: 'a', title: 'a', index: 0)],
    );
    await repo.save(book);
    const url = 'https://fixture.example/image.png';
    final source = FixtureSource(
      ['a'],
      content: const ChapterContent(
        kind: ContentKind.novel,
        html: '<p>Text</p><img src="https://fixture.example/image.png">',
        headers: {'Referer': 'https://fixture.example/book'},
        imageHeaders: {
          url: {'X-Image': 'token'},
        },
      ),
    );
    final bytes = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jf1kAAAAASUVORK5CYII=',
    );
    var imageCalls = 0;
    final client = MockClient((request) async {
      imageCalls++;
      expect(request.headers['Referer'], 'https://fixture.example/book');
      expect(request.headers['X-Image'], 'token');
      return http.Response.bytes(
        bytes,
        200,
        headers: {'content-type': 'image/png'},
      );
    });
    final container = ProviderContainer(
      overrides: [
        libraryRepositoryProvider.overrideWithValue(repo),
        sourceRepositoryProvider.overrideWithValue(source),
        chapterHttpClientProvider.overrideWithValue(client),
      ],
    );
    addTearDown(container.dispose);
    await container.read(libraryProvider.future);
    final vm = container.read(libraryProvider.notifier);
    final online = await vm.getContent(book, 0);
    expect(online.headersFor(url)['X-Image'], 'token');
    expect((await repo.find('book'))!.chapters.single.downloaded, isFalse);
    final offline = await vm.getContent(book, 0, download: true);
    expect(offline.html, contains('data:image/png;base64,'));
    expect((await repo.find('book'))!.chapters.single.downloaded, isTrue);
    expect(source.chapterCalls, 1);
    expect(imageCalls, 1);
  });

  test('oversized image stops the stream and never marks a partial chapter offline', () async {
    final repo = MemoryLibraryRepository();
    final book = fixtureBook(kind: 'manga').copyWith(
      chapters: [const BookChapter(id: 'a', title: 'a', index: 0)],
    );
    await repo.save(book);
    final source = FixtureSource(
      ['a'],
      content: const ChapterContent(
        kind: ContentKind.manga,
        images: ['https://fixture.example/image.png'],
      ),
    );
    final client = OversizedImageClient();
    final container = ProviderContainer(
      overrides: [
        libraryRepositoryProvider.overrideWithValue(repo),
        sourceRepositoryProvider.overrideWithValue(source),
        chapterHttpClientProvider.overrideWithValue(client),
      ],
    );
    addTearDown(container.dispose);
    await container.read(libraryProvider.future);
    await expectLater(
      container
          .read(libraryProvider.notifier)
          .getContent(book, 0, download: true),
      throwsStateError,
    );
    expect(client.chunksRead, 9);
    expect(await repo.readChapter('book', 0), isNull);
    expect((await repo.find('book'))!.chapters.single.downloaded, isFalse);
  });
}
