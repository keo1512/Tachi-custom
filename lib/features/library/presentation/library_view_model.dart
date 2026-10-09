import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:html/parser.dart' as html;

import '../data/document_importer.dart';
import '../data/library_repository.dart';
import '../data/library_mutation.dart';
import '../domain/library_book.dart';
import '../domain/library_reading.dart';
import '../../settings/settings_controller.dart';
import '../../sources/data/source_repository.dart';
import '../../sources/domain/catalogue.dart';

final libraryRepositoryProvider = Provider<LibraryRepository>(
  (ref) => throw StateError('Library not initialized'),
);
final sourceRepositoryProvider = Provider<SourceRepository>((ref) {
  final urls = ref.watch(
    settingsProvider.select((s) => (s.tachimangaUrl, s.vbookUrl)),
  );
  final repository = SourceRepository(
    tachimangaUrl: urls.$1,
    vbookUrl: urls.$2,
  );
  ref.onDispose(repository.dispose);
  return repository;
});
final libraryProvider =
    AsyncNotifierProvider<LibraryViewModel, List<LibraryBook>>(
      LibraryViewModel.new,
    );

final chapterHttpClientProvider = Provider<http.Client>((ref) {
  final client = http.Client();
  ref.onDispose(client.close);
  return client;
});

class LibraryViewModel extends AsyncNotifier<List<LibraryBook>> {
  late LibraryRepository repository;
  int _refreshGeneration = 0;
  final Map<String, Future<void>> _pending = {};
  Future<T> _withBook<T>(String id, Future<T> Function() action) {
    final result = (_pending[id] ?? Future<void>.value()).then((_) => action());
    final finished = result.then<void>(
      (_) {},
      onError: (Object error, StackTrace stack) {},
    );
    _pending[id] = finished;
    finished.whenComplete(() {
      if (identical(_pending[id], finished)) _pending.remove(id);
    });
    return result;
  }

  @override
  Future<List<LibraryBook>> build() {
    repository = ref.read(libraryRepositoryProvider);
    return repository.list();
  }

  Future<void> refresh() async {
    final generation = ++_refreshGeneration;
    final books = await repository.list();
    if (ref.mounted && generation == _refreshGeneration) {
      state = AsyncData(books);
    }
  }

  Future<void> save(LibraryBook book) => _withBook(book.id, () async {
    await repository.save(book);
    await refresh();
  });

  Future<LibraryBook?> _mutateBook(
    String id,
    LibraryBook Function(LibraryBook) transform, {
    int? expectedRevision,
  }) {
    final revision = expectedRevision ?? repository.replacementRevision;
    return _withBook(id, () async {
      final result = await repository.mutateBook(
        id,
        transform,
        expectedRevision: revision,
      );
      await refresh();
      return result;
    });
  }

  Future<void> updateMetadata(
    String id, {
    bool? favorite,
    bool? completed,
    String? collection,
    String? author,
    String? series,
    String? notes,
  }) async {
    await _mutateBook(
      id,
      (book) => book.copyWith(
        favorite: favorite,
        completed: completed,
        collection: collection,
        author: author,
        series: series,
        notes: notes,
      ),
    );
  }

  /// Patches only selected metadata on the latest version of each book.
  /// A download, reading update or bookmark queued for the same ID is preserved.
  Future<int> groupBooks(
    Iterable<String> ids, {
    String? collection,
    String? author,
    String? series,
  }) async {
    if (collection == null && author == null && series == null) return 0;
    if (collection != null && collection.trim().isEmpty) {
      throw const FormatException('Tên kệ không được để trống.');
    }
    var changed = 0;
    final revision = repository.replacementRevision;
    try {
      for (final id in ids.toSet()) {
        final updated = await _mutateBook(
          id,
          (latest) => latest.copyWith(
            collection: collection?.trim(),
            author: author?.trim(),
            series: series?.trim(),
          ),
          expectedRevision: revision,
        );
        if (updated != null) changed++;
      }
    } finally {
      await refresh();
    }
    return changed;
  }

  Future<void> clearHistory(Iterable<String> ids) async {
    final revision = repository.replacementRevision;
    try {
      for (final id in ids.toSet()) {
        await _mutateBook(
          id,
          (book) => book.copyWith(clearLastRead: true),
          expectedRevision: revision,
        );
      }
    } finally {
      await refresh();
    }
  }

  Future<void> remove(String id) {
    final revision = repository.replacementRevision;
    return _withBook(id, () async {
      await repository.removeBook(id, expectedRevision: revision);
      await refresh();
    });
  }

  Future<void> updateProgress(
    String id,
    String chapterId,
    double fraction, {
    bool chapterCompleted = false,
    bool inferCompletionFromFraction = true,
    int? expectedRevision,
  }) async {
    if (!fraction.isFinite) {
      throw const FormatException('Vị trí đọc không hợp lệ.');
    }
    await _mutateBook(id, (book) {
      if (book.chapters.isEmpty) return book;
      final index = book.chapters.indexWhere((c) => c.id == chapterId);
      if (index < 0) return book;
      final boundedFraction = fraction.clamp(0.0, 1.0);
      // Freeze legacy inferred flags before moving manga resume position.
      // A jump must not erase previously read chapters or read skipped pages.
      final chapters = inferCompletionFromFraction
          ? [...book.chapters]
          : [
              for (final entry in book.chapters.indexed)
                entry.$2.copyWith(read: chapterIsRead(book, entry.$1)),
            ];
      if ((inferCompletionFromFraction && boundedFraction >= .999) ||
          chapterCompleted) {
        chapters[index] = chapters[index].copyWith(read: true);
      }
      return book.copyWith(
        chapters: chapters,
        currentChapter: index,
        progress: ((index + boundedFraction) / book.chapters.length).clamp(
          0,
          1,
        ),
        lastRead: DateTime.now(),
      );
    }, expectedRevision: expectedRevision);
  }

  Future<void> markChapterRead(
    String id,
    String chapterId,
    bool read, {
    int? expectedRevision,
  }) async {
    await _mutateBook(id, (book) {
      final index = book.chapters.indexWhere(
        (chapter) => chapter.id == chapterId,
      );
      if (index < 0) return book;
      final chapters = book.completed && !read
          ? [
              for (final entry in book.chapters.indexed)
                entry.$2.copyWith(read: chapterIsRead(book, entry.$1)),
            ]
          : [...book.chapters];
      chapters[index] = chapters[index].copyWith(read: read);
      return book.copyWith(
        chapters: chapters,
        completed: read ? book.completed : false,
      );
    }, expectedRevision: expectedRevision);
  }

  Future<bool> toggleBookmark(
    String id,
    String chapterId,
    double fraction, {
    int? expectedRevision,
  }) async {
    if (!fraction.isFinite) {
      throw const FormatException('Vị trí dấu trang không hợp lệ.');
    }
    var added = false;
    await _mutateBook(id, (book) {
      final index = book.chapters.indexWhere((c) => c.id == chapterId);
      if (index < 0) return book;
      final mark = '$index:${fraction.clamp(0, 1).toStringAsFixed(4)}';
      final marks = [...book.bookmarks];
      added = !marks.remove(mark);
      if (added) marks.add(mark);
      return book.copyWith(bookmarks: marks);
    }, expectedRevision: expectedRevision);
    return added;
  }

  Future<void> removeBookmark(
    String id,
    String mark, {
    int? expectedRevision,
  }) async {
    await _mutateBook(
      id,
      (book) => book.copyWith(bookmarks: [...book.bookmarks]..remove(mark)),
      expectedRevision: expectedRevision,
    );
  }

  Future<int> importFiles() async {
    final result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['epub', 'txt', 'cbz', 'zip'],
    );
    if (result.isEmpty) return 0;
    var count = 0;
    try {
      for (final file in result) {
        final size = await file.length();
        if (size != null && size > 64 * 1024 * 1024) {
          throw StateError('File vượt giới hạn nhập 64 MB');
        }
        await DocumentImporter().import(
          file.name,
          await file.readAsBytes(),
          repository,
        );
        count++;
      }
    } finally {
      await refresh();
    }
    return count;
  }

  Future<LibraryBook> addFromSource(CatalogueBook item) async {
    final revision = repository.replacementRevision;
    final id = sha256
        .convert(
          utf8.encode('${item.engine.name}:${item.sourceId}:${item.ref}'),
        )
        .toString();
    final existing = await repository.find(id);
    if (existing != null) return existing;
    final source = ref.read(sourceRepositoryProvider);
    final detail = await source.detail(item);
    final chapters = await source.chapters(item);
    final book = LibraryBook(
      id: id,
      title: detail.title,
      author: detail.author,
      artist: detail.artist,
      genres: detail.genres,
      description: detail.description,
      cover: detail.coverUrl,
      kind: detail.kind.name,
      engine: detail.engine.name,
      sourceId: detail.sourceId,
      sourceRef: detail.ref,
      chapters: chapters
          .map(
            (c) => BookChapter(
              id: c.ref,
              title: c.title,
              index: c.index,
              read: false,
            ),
          )
          .toList(),
    );
    final saved = await repository.insertBook(book, expectedRevision: revision);
    await refresh();
    return saved;
  }

  CatalogueBook catalogue(LibraryBook book) => CatalogueBook(
    ref: book.sourceRef,
    title: book.title,
    author: book.author,
    description: book.description,
    coverUrl: book.cover,
    sourceId: book.sourceId,
    kind: book.kind == 'manga' ? ContentKind.manga : ContentKind.novel,
    engine: book.engine == 'vbook'
        ? SourceEngine.vbook
        : SourceEngine.tachimanga,
  );

  Future<ReaderContent> getContent(
    LibraryBook book,
    int index, {
    bool download = false,
  }) async {
    if (index < 0 || index >= book.chapters.length) {
      throw StateError('Vị trí chương không hợp lệ');
    }
    final chapterId = book.chapters[index].id;
    final read = await repository.openChapter(book.id, chapterId);
    if (read == null) {
      throw StateError('Sách hoặc chương không còn trong thư viện');
    }
    final latest = read.book;
    final cached = read.content;
    if (cached != null) checkChapterContent(latest, cached);
    if (cached != null && (!download || chapterIsOffline(cached))) {
      if (chapterIsOffline(cached) && !latest.chapters[read.index].downloaded) {
        final saved = await repository.commitChapter(
          read,
          cached,
          downloaded: true,
        );
        await refresh();
        return saved;
      }
      return cached;
    }
    if (latest.engine == 'local') {
      throw StateError('Không tìm thấy nội dung đã nhập');
    }
    ReaderContent content;
    if (cached != null) {
      content = cached;
    } else {
      final chapter = latest.chapters[read.index];
      final result = await ref
          .read(sourceRepositoryProvider)
          .chapter(
            catalogue(latest),
            CatalogueChapter(
              ref: chapter.id,
              title: chapter.title,
              index: chapter.index,
            ),
          );
      content = ReaderContent(
        kind: result.kind.name,
        html: result.html,
        images: result.images,
        headers: result.headers,
        imageHeaders: result.imageHeaders,
      );
    }
    checkChapterContent(latest, content);
    if (download) {
      content = await _downloadContent(
        content,
        onPartial: (partial) async {
          await repository.commitChapter(read, partial, downloaded: false);
          await refresh();
        },
      );
    }
    if (download || latest.kind == 'novel') {
      final saved = await repository.commitChapter(
        read,
        content,
        downloaded: chapterIsOffline(content),
      );
      await refresh();
      return saved;
    }
    final current = await repository.openChapter(book.id, chapterId);
    checkLibraryRevision(repository.replacementRevision, read.revision);
    if (current == null ||
        bookSourceIdentity(current.book) != bookSourceIdentity(latest)) {
      throw StateError('Sách hoặc nguồn đã thay đổi.');
    }
    if (current.content != null && chapterIsOffline(current.content!)) {
      return current.content!;
    }
    return content;
  }

  Future<ReaderContent> _downloadContent(
    ReaderContent content, {
    required Future<void> Function(ReaderContent) onPartial,
  }) async {
    final client = ref.read(chapterHttpClientProvider);
    var total = 0;
    final saved = <String, String>{};
    Future<String> downloadImage(String url) async {
      if (url.startsWith('data:') || url.startsWith('tachi-asset://')) {
        return url;
      }
      if (saved.containsKey(url)) return saved[url]!;
      final uri = Uri.tryParse(url);
      if (uri == null ||
          !uri.hasAuthority ||
          !['http', 'https'].contains(uri.scheme)) {
        throw StateError('URL ảnh trong chương không hợp lệ');
      }
      final response = await client
          .send(
            http.Request('GET', uri)..headers.addAll(content.headersFor(url)),
          )
          .timeout(const Duration(seconds: 30));
      if (response.statusCode != 200) {
        throw StateError('Tải ảnh thất bại: HTTP ${response.statusCode}');
      }
      final type =
          response.headers['content-type']?.split(';').first.trim() ??
          'image/jpeg';
      if (!type.startsWith('image/')) {
        throw StateError('Nguồn trả về dữ liệu không phải ảnh');
      }
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in response.stream.timeout(
        const Duration(seconds: 30),
      )) {
        total += chunk.length;
        if (bytes.length + chunk.length > LibraryRepository.maxImageBytes ||
            total > 64 * 1024 * 1024) {
          throw StateError('Chương vượt giới hạn tải 64 MB hoặc ảnh vượt 8 MB');
        }
        bytes.add(chunk);
      }
      if (bytes.isEmpty) throw StateError('Ảnh tải về rỗng');
      // Keep bytes staged in memory until the revision-checked atomic commit;
      // a removed/restored book must not recreate attachment files mid-request.
      return saved[url] =
          'data:$type;base64,${base64Encode(bytes.takeBytes())}';
    }

    final images = <String>[];
    final document = html.parseFragment(content.html);
    try {
      for (final url in content.images) {
        images.add(await downloadImage(url));
      }
      for (final image in document.querySelectorAll('img')) {
        image.attributes['src'] = await downloadImage(
          image.attributes['src'] ?? '',
        );
        image.attributes.remove('srcset');
      }
    } catch (_) {
      if (saved.isNotEmpty) {
        final partial = html.parseFragment(content.html);
        for (final image in partial.querySelectorAll('img')) {
          final source = image.attributes['src'];
          if (saved.containsKey(source)) {
            image.attributes['src'] = saved[source]!;
            image.attributes.remove('srcset');
          }
        }
        // Save only complete images. An interrupted byte stream is discarded.
        // The chapter stays online and the next attempt skips these local pages.
        await onPartial(
          ReaderContent(
            kind: content.kind,
            html: partial.outerHtml,
            images: content.images
                .map((source) => saved[source] ?? source)
                .toList(),
            headers: content.headers,
            imageHeaders: content.imageHeaders,
          ),
        );
      }
      rethrow;
    }
    return ReaderContent(
      kind: content.kind,
      html: document.outerHtml,
      images: images,
    );
  }

  Future<int> updateAll() async {
    var added = 0;
    for (final book in await repository.list()) {
      if (book.engine == 'local') continue;
      final revision = repository.replacementRevision;
      final current = await repository.find(book.id);
      if (current == null) continue;
      checkLibraryRevision(repository.replacementRevision, revision);
      final latest = await ref
          .read(sourceRepositoryProvider)
          .chapters(catalogue(current));
      if (latest.isEmpty && current.chapters.isNotEmpty) {
        throw StateError(
          'Nguồn trả mục lục trống. Các chương đang có được giữ nguyên.',
        );
      }
      final chapters = latest
          .map((c) => BookChapter(id: c.ref, title: c.title, index: c.index))
          .toList();
      added += await repository.updateChapterOrder(
        current,
        chapters,
        expectedRevision: revision,
      );
    }
    await refresh();
    return added;
  }

  Future<void> addExample() async {
    const id = 'example-original-v1';
    if (await repository.find(id) != null) return;
    const texts = [
      '<h2>Một nơi dành cho những trang sách</h2><p>Buổi sáng, Linh mở cửa sổ. Trên bàn là cuốn sách còn đọc dở từ tối qua. Cô đánh dấu dòng cuối cùng, rồi dành cho mình vài phút yên tĩnh trước khi bắt đầu ngày mới.</p><p>Một tủ sách không cần lớn. Nó chỉ cần giữ được những điều ta muốn quay lại: một câu chuyện, một ý tưởng, hay một trang làm mình dừng lâu hơn thường lệ.</p>',
      '<h2>Đọc theo nhịp của mình</h2><p>Có ngày ta chỉ đọc một trang. Có ngày một chương kéo theo cả buổi chiều. Linh thích đổi nền sang màu giấy, tăng khoảng cách dòng, rồi để điện thoại xuống đúng lúc câu chuyện cần một khoảng nghỉ.</p><p>Điều quan trọng là biết mình đã dừng ở đâu, để lần sau có thể tiếp tục nhẹ nhàng.</p>',
      '<h2>Mang theo câu chuyện</h2><p>Trước chuyến đi, Linh tải những chương muốn đọc. Khi tàu ra khỏi thành phố và mất sóng, tủ sách vẫn ở đó. Cô mở lại trang vừa dừng, nhìn ra cửa kính, rồi đọc tiếp.</p><p>Nội dung mẫu này do dự án tự viết để thử reader. Bạn có thể nhập EPUB, TXT hoặc CBZ của mình từ nút thêm trong thư viện.</p>',
    ];
    final book = LibraryBook(
      id: id,
      title: 'Một khoảng để đọc',
      author: 'TachiBooks · nội dung mẫu',
      description: 'Ba chương ngắn do dự án tự viết để bạn thử font, nền, bookmark và lưu tiến độ.',
      kind: 'novel',
      engine: 'local',
      chapters: List.generate(
        texts.length,
        (i) => BookChapter(
          id: '$id-$i',
          title: ['Tủ sách nhỏ', 'Nhịp đọc', 'Đọc ngoại tuyến'][i],
          index: i,
          downloaded: true,
        ),
      ),
    );
    for (var i = 0; i < texts.length; i++) {
      await repository.saveChapter(
        id,
        i,
        ReaderContent(kind: 'novel', html: texts[i]),
      );
    }
    await save(book);
  }
}
