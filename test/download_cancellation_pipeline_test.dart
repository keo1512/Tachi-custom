import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tachi_books/features/downloads/presentation/download_queue_controller.dart';
import 'package:tachi_books/features/library/data/library_repository.dart';
import 'package:tachi_books/features/library/domain/library_book.dart';
import 'package:tachi_books/features/library/presentation/library_view_model.dart';
import 'package:tachi_books/features/settings/settings_controller.dart';
import 'package:tachi_books/features/sources/data/source_repository.dart';
import 'package:tachi_books/features/sources/domain/catalogue.dart';

const _url = 'https://source.invalid/original-encrypted-page';
final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jf1kAAAAASUVORK5CYII=',
);
LibraryBook _book() => LibraryBook(
  id: 'book',
  title: 'Original',
  engine: 'tachimanga',
  kind: 'manga',
  sourceId: '9223372036854775806',
  sourceRef: '/book',
  progress: .25,
  bookmarks: ['0:.25'],
  notes: 'Keep notes',
  chapters: const [
    BookChapter(id: '/chapter', title: 'Chapter', index: 101, read: false),
  ],
);

class _Source extends SourceRepository {
  _Source({this.native = true}) : super(tachimangaUrl: '', vbookUrl: '');
  final bool native;
  final calls = <int>[];
  final metadataEntered = Completer<void>();
  Completer<void>? metadataRelease, imageRelease;
  int count = 3;
  @override
  bool usesNativeImageLoader(CatalogueBook book) => native;
  @override
  Future<ChapterContent> chapter(
    CatalogueBook book,
    CatalogueChapter chapter,
  ) async {
    expect(chapter.ref, '/chapter');
    expect(chapter.index, 101);
    if (!metadataEntered.isCompleted) metadataEntered.complete();
    if (metadataRelease != null) await metadataRelease!.future;
    return ChapterContent(
      kind: ContentKind.manga,
      images: native
          ? List.filled(count, _url)
          : List.generate(count, (i) => 'https://source.invalid/$i.png'),
      headers: const {'Referer': 'https://source.invalid/book'},
    );
  }

  @override
  Future<SourceImageData> fetchImage(
    CatalogueBook book,
    CatalogueChapter chapter,
    int page,
    String url,
  ) async {
    expect(book.sourceId, '9223372036854775806');
    expect(chapter.ref, '/chapter');
    expect(chapter.index, 101);
    expect(url, _url);
    calls.add(page);
    if (page == 1 && imageRelease != null) await imageRelease!.future;
    return SourceImageData(bytes: _png, mimeType: 'image/png');
  }
}

class _StreamingClient extends http.BaseClient {
  final calls = <String>[];
  final partialEntered = Completer<void>();
  final body = StreamController<List<int>>();
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    expect(request.headers['Referer'], 'https://source.invalid/book');
    calls.add(request.url.path);
    if (request.url.path == '/0.png') {
      return http.StreamedResponse(
        Stream.value(_png),
        200,
        headers: {'content-type': 'image/png'},
      );
    }
    body.onListen = () {
      body.add(_png.sublist(0, 30));
      scheduleMicrotask(partialEntered.complete);
    };
    return http.StreamedResponse(
      body.stream,
      200,
      headers: {'content-type': 'image/png'},
    );
  }
}

Future<void> _until(bool Function() predicate) async {
  for (var i = 0; i < 150; i++) {
    if (predicate()) return;
    await Future<void>.delayed(Duration.zero);
  }
  fail('Download did not reach expected state');
}

Future<(ProviderContainer, MemoryLibraryRepository, LibraryBook)> _setup(
  _Source source, {
  http.Client? client,
}) async {
  final prefs = await SharedPreferences.getInstance(),
      repo = MemoryLibraryRepository();
  final book = _book();
  await repo.save(book);
  final container = ProviderContainer(
    overrides: [
      preferencesProvider.overrideWithValue(prefs),
      libraryRepositoryProvider.overrideWithValue(repo),
      sourceRepositoryProvider.overrideWithValue(source),
      chapterHttpClientProvider.overrideWithValue(
        client ??
            MockClient((_) async {
              fail('Native images must use the original engine transform');
            }),
      ),
    ],
  );
  await container.read(libraryProvider.future);
  return (container, repo, book);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(
    () => SharedPreferences.setMockInitialValues({'downloadConcurrency': 1}),
  );

  test('default queue cancellation retains fully returned native pages and re-enqueue downloads only the missing page', () async {
    final source = _Source()..imageRelease = Completer<void>();
    final (container, repo, book) = await _setup(source);
    addTearDown(container.dispose);
    final queue = container.read(downloadQueueProvider.notifier);
    await queue.enqueue(book.id, ['/chapter']);
    await queue.start();
    await _until(() => source.calls.length == 2);
    await queue.cancelBook(book.id);
    source.imageRelease!.complete();
    await _until(() => !container.read(downloadQueueProvider).running);
    expect(source.calls, [
      0,
      1,
    ], reason: 'No next native page is requested after cancellation.');
    final partial = await repo.readChapter(book.id, 0);
    expect(partial, isNotNull);
    expect(partial!.images, [
      'data:image/png;base64,${base64Encode(_png)}',
      'data:image/png;base64,${base64Encode(_png)}',
      _url,
    ]);
    final saved = (await repo.find(book.id))!;
    expect(saved.chapters.single.downloaded, isFalse);
    expect(saved.chapters.single.read, isFalse);
    expect(saved.progress, book.progress);
    expect(saved.bookmarks, book.bookmarks);
    expect(saved.notes, book.notes);
    source.calls.clear();
    await queue.enqueue(book.id, ['/chapter']);
    await queue.start();
    await _until(() => !container.read(downloadQueueProvider).running);
    expect(source.calls, [2]);
    expect((await repo.find(book.id))!.chapters.single.downloaded, isTrue);
    expect(
      (await repo.readChapter(
        book.id,
        0,
      ))!.images.every((url) => url.startsWith('data:image/')),
      isTrue,
    );
  });

  test('pause and resume default queue retains staged native pages and only downloads missing pages', () async {
    final source = _Source()..imageRelease = Completer<void>();
    final (container, repo, book) = await _setup(source);
    addTearDown(container.dispose);
    final queue = container.read(downloadQueueProvider.notifier);
    final identity = DownloadJob(
      bookId: book.id,
      chapterId: '/chapter',
    ).identity;
    await queue.enqueue(book.id, ['/chapter']);
    await queue.start();
    await _until(() => source.calls.length == 2);
    await queue.pauseJob(identity);
    source.imageRelease!.complete();
    await _until(() => !container.read(downloadQueueProvider).running);
    expect(source.calls, [0, 1]);
    expect(
      container.read(downloadQueueProvider).tasks.single.status,
      DownloadJobStatus.paused,
    );
    expect((await repo.find(book.id))!.chapters.single.downloaded, false);
    expect(
      (await repo.readChapter(
        book.id,
        0,
      ))!.images.where((url) => url.startsWith('data:image/')).length,
      2,
    );
    source.calls.clear();
    await queue.resumeJob(identity);
    await _until(() => container.read(downloadQueueProvider).tasks.isEmpty);
    expect(source.calls, [2]);
    expect((await repo.find(book.id))!.chapters.single.downloaded, true);
    expect((await repo.find(book.id))!.bookmarks, book.bookmarks);
    expect((await repo.find(book.id))!.progress, book.progress);
  });

  test('cancel while source chapter metadata is pending dispatches no images and never creates cache', () async {
    final source = _Source()..metadataRelease = Completer<void>();
    final (container, repo, book) = await _setup(source);
    addTearDown(container.dispose);
    final queue = container.read(downloadQueueProvider.notifier);
    await queue.enqueue(book.id, ['/chapter']);
    await queue.start();
    await source.metadataEntered.future;
    await queue.cancelAll();
    source.metadataRelease!.complete();
    await _until(() => !container.read(downloadQueueProvider).running);
    expect(source.calls, isEmpty);
    expect(await repo.readChapter(book.id, 0), isNull);
    expect((await repo.find(book.id))!.toJson(), book.toJson());
  });

  test('cancel raw HTTP during a partial byte stream discards that page but retains earlier complete original bytes', () async {
    final source = _Source(native: false), client = _StreamingClient();
    final (container, repo, book) = await _setup(source, client: client);
    addTearDown(container.dispose);
    final queue = container.read(downloadQueueProvider.notifier);
    await queue.enqueue(book.id, ['/chapter']);
    await queue.start();
    await client.partialEntered.future;
    await Future<void>.delayed(Duration.zero);
    await queue.cancelBook(book.id);
    client.body.add(_png.sublist(30));
    await client.body.close();
    await _until(() => !container.read(downloadQueueProvider).running);
    expect(client.calls, ['/0.png', '/1.png']);
    final partial = (await repo.readChapter(book.id, 0))!;
    expect(partial.images, [
      'data:image/png;base64,${base64Encode(_png)}',
      'https://source.invalid/1.png',
      'https://source.invalid/2.png',
    ]);
    expect((await repo.find(book.id))!.chapters.single.downloaded, isFalse);
    expect((await repo.find(book.id))!.progress, book.progress);
  });
}
