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
import '../domain/chapter_list_options.dart';
import '../domain/library_update_result.dart';
import '../../settings/settings_controller.dart';
import '../../sources/data/source_repository.dart';
import '../../sources/application/native_runtime_provider.dart';
import '../../sources/data/on_device_source_repository.dart';
import '../../sources/domain/catalogue.dart';
import '../../downloads/presentation/download_deletion_controller.dart';
import 'library_category_controller.dart';
import 'library_preference_writes.dart';
import '../application/library_update_report.dart';
import '../../tasks/application/task_notifications.dart';

final libraryRepositoryProvider = Provider<LibraryRepository>(
  (ref) => throw StateError('Library not initialized'),
);
final sourceRepositoryProvider = Provider<SourceRepository>((ref) {
  final urls = ref.watch(
    settingsProvider.select((s) => (s.tachimangaUrl, s.vbookUrl)),
  );
  final runtimes = ref.read(nativeSourceRuntimesProvider);
  final repository = OnDeviceSourceRepository(
    tachimangaUrl: urls.$1,
    vbookUrl: urls.$2,
    runtimes: {
      for (final entry in runtimes.entries)
        if (entry.key == SourceEngine.tachimanga
            ? urls.$1.isEmpty
            : urls.$2.isEmpty)
          entry.key: entry.value,
    },
    ownsRuntimes: false,
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
  final Map<String, Future<int?>> _chapterUpdates = {};
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
    List<String>? categories,
    String? cover,
    String? title,
    List<String>? alternativeTitles,
    String? artist,
    String? description,
    bool restoreOriginalCover = false,
    int? expectedRevision,
  }) async {
    await _mutateBook(id, (book) {
      if (alternativeTitles != null &&
          (alternativeTitles.length > 2 ||
              alternativeTitles.any((name) => name.trim().isEmpty) ||
              alternativeTitles.toSet().length != alternativeTitles.length)) {
        throw const FormatException(
          'Chỉ được lưu tối đa hai tên khác không trống, không trùng.',
        );
      }
      if (title != null && title.trim().isEmpty) {
        throw const FormatException('Tên truyện không được để trống.');
      }
      return book.copyWith(
        title: title?.trim(),
        alternativeTitles: alternativeTitles,
        artist: artist,
        description: description,
        favorite: favorite,
        completed: completed,
        collection: collection,
        author: author,
        series: series,
        notes: notes,
        categories: categories,
        cover: restoreOriginalCover && book.customCover
            ? book.originalCover
            : cover,
        originalCover: restoreOriginalCover && book.customCover
            ? ''
            : cover != null && !book.customCover
            ? book.cover
            : null,
        customCover: restoreOriginalCover
            ? false
            : cover != null
            ? true
            : null,
      );
    }, expectedRevision: expectedRevision);
  }

  /// Patches only selected metadata on the latest version of each book.
  /// A download, reading update or bookmark queued for the same ID is preserved.
  Future<int> groupBooks(
    Iterable<String> ids, {
    String? collection,
    String? author,
    String? series,
    List<String>? categories,
    int? expectedRevision,
  }) async {
    if (collection == null &&
        author == null &&
        series == null &&
        categories == null) {
      return 0;
    }
    if (categories == null && collection != null && collection.trim().isEmpty) {
      throw const FormatException('Tên kệ không được để trống.');
    }
    var changed = 0;
    final revision = expectedRevision ?? repository.replacementRevision;
    try {
      for (final id in ids.toSet()) {
        final updated = await _mutateBook(
          id,
          (latest) => latest.copyWith(
            collection: collection?.trim(),
            author: author?.trim(),
            series: series?.trim(),
            categories: categories,
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

  Future<void> updateReaderPreferences(
    String id,
    Map<String, dynamic> options, {
    int? expectedRevision,
  }) async {
    await _mutateBook(
      id,
      (book) => book.copyWith(readerPreferences: options),
      expectedRevision: expectedRevision,
    );
  }

  Future<void> clearHistory(
    Iterable<String> ids, {
    int? expectedRevision,
  }) async {
    final revision = expectedRevision ?? repository.replacementRevision;
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

  Future<void> remove(String id, {int? expectedRevision}) {
    final revision = expectedRevision ?? repository.replacementRevision;
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
    final revision = expectedRevision ?? repository.replacementRevision;
    final updated = await _mutateBook(id, (book) {
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
    }, expectedRevision: revision);
    if (read && updated != null && ref.mounted) {
      await ref
          .read(downloadDeletionProvider.notifier)
          .deleteReadChapters(
            updated,
            [chapterId],
            event: DownloadDeletionEvent.manuallyMarkedRead,
            expectedRevision: revision,
          );
    }
  }

  Future<void> updateChapterListPreferences(
    String id,
    Map<String, dynamic> options, {
    int? expectedRevision,
  }) async {
    ChapterListOptions.validateJson(options);
    await _mutateBook(
      id,
      (book) => book.copyWith(chapterListPreferences: options),
      expectedRevision: expectedRevision,
    );
  }

  Future<void> refreshBookDetail(
    String id, {
    int? expectedRevision,
    bool refreshChapters = true,
  }) async {
    final revision = expectedRevision ?? repository.replacementRevision;
    checkLibraryRevision(repository.replacementRevision, revision);
    final book = await repository.find(id);
    if (book == null || book.engine == 'local') return;
    final detail = await ref
        .read(sourceRepositoryProvider)
        .detail(catalogue(book));
    checkLibraryRevision(repository.replacementRevision, revision);
    await _mutateBook(id, (latest) {
      if (bookSourceIdentity(latest) != bookSourceIdentity(book)) {
        throw StateError('Nguồn truyện đã thay đổi.');
      }
      return latest.copyWith(
        title: detail.title,
        author: detail.author,
        artist: detail.artist,
        description: detail.description,
        genres: detail.genres,
        status: detail.status,
        cover: latest.customCover || detail.coverUrl.isEmpty
            ? latest.cover
            : detail.coverUrl,
        originalCover: latest.customCover && detail.coverUrl.isNotEmpty
            ? detail.coverUrl
            : null,
      );
    }, expectedRevision: revision);
    if (refreshChapters) {
      final result = await updateBooks([id], expectedRevision: revision);
      if (result.hasErrors) throw StateError(result.failures.first.message);
    }
  }

  Future<void> markChaptersRead(
    String id,
    Iterable<String> chapterIds,
    bool read, {
    int? expectedRevision,
  }) async {
    final revision = expectedRevision ?? repository.replacementRevision;
    final ids = chapterIds.toSet();
    final updated = await _mutateBook(id, (book) {
      return book.copyWith(
        chapters: [
          for (final (index, chapter) in book.chapters.indexed)
            chapter.copyWith(
              read: ids.contains(chapter.id)
                  ? read
                  : chapterIsRead(book, index),
            ),
        ],
        completed: read ? book.completed : false,
      );
    }, expectedRevision: revision);
    if (read && updated != null && ref.mounted) {
      await ref
          .read(downloadDeletionProvider.notifier)
          .deleteReadChapters(
            updated,
            ids,
            event: DownloadDeletionEvent.manuallyMarkedRead,
            expectedRevision: revision,
          );
    }
  }

  Future<void> resetBookReading(String id, {int? expectedRevision}) async {
    await _mutateBook(
      id,
      (book) => book.copyWith(
        chapters: [
          for (final chapter in book.chapters) chapter.copyWith(read: false),
        ],
        currentChapter: 0,
        progress: 0,
        completed: false,
        clearLastRead: true,
      ),
      expectedRevision: expectedRevision,
    );
  }

  Future<void> setChapterBookmarks(
    String id,
    Iterable<String> chapterIds,
    bool bookmarked, {
    int? expectedRevision,
  }) async {
    final ids = chapterIds.toSet();
    await _mutateBook(id, (book) {
      final indices = {
        for (final (index, chapter) in book.chapters.indexed)
          if (ids.contains(chapter.id)) index,
      };
      final marks = [...book.bookmarks];
      if (bookmarked) {
        for (final index in indices) {
          if (!marks.any(
            (mark) => int.tryParse(mark.split(':').first) == index,
          )) {
            marks.add('$index:0.0000');
          }
        }
      } else {
        marks.removeWhere(
          (mark) => indices.contains(int.tryParse(mark.split(':').first)),
        );
      }
      return book.copyWith(bookmarks: marks);
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
      allowedExtensions: [
        'epub',
        'txt',
        'cbz',
        'zip',
        'cbr',
        'rar',
        'jpg',
        'jpeg',
        'png',
        'webp',
        'gif',
        'avif',
        'heic',
        'heif',
        'jxl',
      ],
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
          defaultCategories: ref
              .read(libraryCategoriesProvider)
              .defaultCategories,
        );
        count++;
      }
    } finally {
      await refresh();
    }
    return count;
  }

  Future<LibraryBook> addFromSource(
    CatalogueBook item, {
    List<String>? categories,
    String sourceName = '',
    int? expectedRevision,
  }) async {
    final revision = expectedRevision ?? repository.replacementRevision;
    checkLibraryRevision(repository.replacementRevision, revision);
    final id = sha256
        .convert(
          utf8.encode('${item.engine.name}:${item.sourceId}:${item.ref}'),
        )
        .toString();
    final existing = await repository.find(id);
    checkLibraryRevision(repository.replacementRevision, revision);
    if (existing != null) return existing;
    final source = ref.read(sourceRepositoryProvider);
    final detail = await source.detail(item);
    checkLibraryRevision(repository.replacementRevision, revision);
    final chapters = await source.chapters(item);
    checkLibraryRevision(repository.replacementRevision, revision);
    final saved = await LibraryPreferenceWrites.serialize(
      ref.read(preferencesProvider),
      () async {
        checkLibraryRevision(repository.replacementRevision, revision);
        if (categories != null) {
          final names = ref
              .read(libraryCategoriesProvider)
              .all(await repository.list())
              .map((category) => category.name)
              .toSet();
          checkLibraryRevision(repository.replacementRevision, revision);
          if (categories.any(
            (name) => name != 'Mặc định' && !names.contains(name),
          )) {
            throw StateError(
              'Danh mục đã thay đổi. Hãy chọn lại trước khi thêm truyện.',
            );
          }
        }
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
          sourceName: sourceName.trim(),
          sourceRef: detail.ref,
          createdAt: DateTime.now(),
          status: detail.status,
          categories:
              categories ??
              ref.read(libraryCategoriesProvider).defaultCategories,
          chapters: chapters
              .map(
                (c) => BookChapter(
                  id: c.ref,
                  title: c.title,
                  index: c.index,
                  read: false,
                  uploadedAt: c.uploadedAt,
                  scanlator: c.scanlator,
                  number: c.number,
                ),
              )
              .toList(),
        );
        // Keep membership validation and insertion in the same category edit queue:
        // a rename/remove must see this new row instead of recreating an old name.
        return repository.insertBook(book, expectedRevision: revision);
      },
    );
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
    int? expectedRevision,
    bool Function()? isCancelled,
  }) async {
    final revision = expectedRevision ?? repository.replacementRevision;
    void continueRequest() {
      checkLibraryRevision(repository.replacementRevision, revision);
      if (isCancelled?.call() ?? false) throw StateError('Đã hủy tải chương.');
    }

    continueRequest();
    if (index < 0 || index >= book.chapters.length) {
      throw StateError('Vị trí chương không hợp lệ');
    }
    final chapterId = book.chapters[index].id;
    final read = await repository.openChapter(book.id, chapterId);
    continueRequest();
    if (read == null) {
      throw StateError('Sách hoặc chương không còn trong thư viện');
    }
    final latest = read.book;
    if (bookSourceIdentity(latest) != bookSourceIdentity(book)) {
      throw StateError('Sách hoặc nguồn đã thay đổi. Hãy mở lại sách.');
    }
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
      continueRequest();
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
        book: catalogue(latest),
        chapter: CatalogueChapter(
          ref: latest.chapters[read.index].id,
          title: latest.chapters[read.index].title,
          index: latest.chapters[read.index].index,
        ),
        continueRequest: continueRequest,
        onPartial: (partial) async {
          await repository.commitChapter(read, partial, downloaded: false);
          await refresh();
        },
      );
    }
    if (download || latest.kind == 'novel') {
      continueRequest();
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
    required CatalogueBook book,
    required CatalogueChapter chapter,
    required Future<void> Function(ReaderContent) onPartial,
    required void Function() continueRequest,
  }) async {
    final client = ref.read(chapterHttpClientProvider);
    final source = ref.read(sourceRepositoryProvider);
    final nativeImages = source.usesNativeImageLoader(book);
    var total = 0;
    final saved = <String, String>{};
    String imageKey(String url, int? page) =>
        nativeImages && page != null ? '$page\u0000$url' : url;
    Future<String> downloadImage(String url, {int? page}) async {
      continueRequest();
      if (url.startsWith('data:') || url.startsWith('tachi-asset://')) {
        return url;
      }
      final key = imageKey(url, page);
      if (saved.containsKey(key)) return saved[key]!;
      final uri = Uri.tryParse(url);
      if (uri == null ||
          !uri.hasAuthority ||
          !['http', 'https'].contains(uri.scheme)) {
        throw StateError('URL ảnh trong chương không hợp lệ');
      }
      if (nativeImages && page != null) {
        final image = await source.fetchImage(book, chapter, page, url);
        total += image.bytes.length;
        if (image.bytes.isEmpty ||
            !image.mimeType.startsWith('image/') ||
            image.bytes.length > LibraryRepository.maxImageBytes ||
            total > 64 * 1024 * 1024) {
          throw StateError('Ảnh không hợp lệ hoặc chương vượt giới hạn tải.');
        }
        return saved[key] =
            'data:${image.mimeType};base64,${base64Encode(image.bytes)}';
      }
      final response = await client
          .send(
            http.Request('GET', uri)..headers.addAll(content.headersFor(url)),
          )
          .timeout(const Duration(seconds: 30));
      if (response.statusCode != 200) {
        await response.stream.listen((_) {}).cancel();
        throw StateError('Tải ảnh thất bại: HTTP ${response.statusCode}');
      }
      final type =
          response.headers['content-type']?.split(';').first.trim() ??
          'image/jpeg';
      if (!type.startsWith('image/')) {
        await response.stream.listen((_) {}).cancel();
        throw StateError('Nguồn trả về dữ liệu không phải ảnh');
      }
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in response.stream.timeout(
        const Duration(seconds: 30),
      )) {
        continueRequest();
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
      return saved[key] =
          'data:$type;base64,${base64Encode(bytes.takeBytes())}';
    }

    final images = <String>[];
    final document = html.parseFragment(content.html);
    try {
      for (var page = 0; page < content.images.length; page++) {
        images.add(await downloadImage(content.images[page], page: page));
      }
      for (final image in document.querySelectorAll('img')) {
        image.attributes['src'] = await downloadImage(
          image.attributes['src'] ?? '',
        );
        image.attributes.remove('srcset');
      }
      continueRequest();
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
                .asMap()
                .entries
                .map(
                  (entry) =>
                      saved[imageKey(entry.value, entry.key)] ?? entry.value,
                )
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
    final revision = repository.replacementRevision;
    final books = await repository.list();
    final result = await updateBooks(
      books.map((book) => book.id),
      expectedRevision: revision,
    );
    if (result.hasErrors) {
      throw StateError(
        'Đã cập nhật ${result.checkedBooks} truyện, thêm '
        '${result.addedChapters} chương; ${result.failures.length} truyện lỗi. '
        '${result.failures.first.title}: ${result.failures.first.message}',
      );
    }
    return result.addedChapters;
  }

  /// Refresh only the IDs captured by a library shelf/category gesture.
  Future<LibraryUpdateResult> updateBooks(
    Iterable<String> bookIds, {
    int? expectedRevision,
    void Function(LibraryUpdateProgress)? onProgress,
    Map<String, String> skipReasons = const {},
  }) async {
    final ids = bookIds.toSet();
    if (ids.any((id) => id.isEmpty)) {
      throw ArgumentError('Thiếu mã truyện cần cập nhật.');
    }
    final revision = expectedRevision ?? repository.replacementRevision;
    final notifications = ref.read(taskNotificationsProvider.notifier);
    final privacyGeneration = notifications.privacyGeneration;
    final privateSession = ref.read(settingsProvider).incognitoMode;
    final books = {for (final book in await repository.list()) book.id: book};
    final titles = {for (final book in books.values) book.id: book.title};
    var checked = 0, added = 0, skipped = 0;
    final failures = <LibraryUpdateFailure>[];
    final skippedDetails = <LibraryUpdateSkipped>[];
    final activity = ref.read(libraryUpdateProgressProvider.notifier);
    final executionGate = ref.read(libraryUpdateExecutionProvider);
    final execution = executionGate.begin();
    var cancelled = false;
    final run = activity.begin();
    void report(String title) {
      final value = LibraryUpdateProgress(
        requestedBooks: ids.length,
        processedBooks: checked + skipped + failures.length,
        checkedBooks: checked,
        addedChapters: added,
        skippedBooks: skipped,
        failedBooks: failures.length,
        currentTitle: title,
      );
      if (ref.mounted) activity.report(run, value);
      onProgress?.call(value);
    }

    report('');
    try {
      for (final id in ids) {
        report(titles[id] ?? id);
        try {
          await executionGate.wait(execution);
          final initial = books[id];
          final reason =
              skipReasons[id] ??
              (initial == null
                  ? 'Truyện không còn trong thư viện'
                  : initial.engine == 'local'
                  ? 'Truyện trên máy'
                  : null);
          if (reason != null) {
            skipped++;
            skippedDetails.add(
              LibraryUpdateSkipped(
                bookId: id,
                title: titles[id] ?? id,
                reason: reason,
              ),
            );
            continue;
          }
          final additions = await _updateBookChapters(id, revision, execution);
          execution.check();
          if (additions == null) {
            skipped++;
            skippedDetails.add(
              LibraryUpdateSkipped(
                bookId: id,
                title: titles[id] ?? id,
                reason: 'Truyện đã xóa hoặc không dùng nguồn online',
              ),
            );
          } else {
            checked++;
            added += additions;
          }
        } catch (error) {
          if (error is LibraryUpdateCancelled) {
            cancelled = true;
            break;
          }
          failures.add(
            LibraryUpdateFailure(
              bookId: id,
              title: titles[id] ?? id,
              message: '$error',
              sourceIdentity: books[id] == null
                  ? ''
                  : '${books[id]!.engine}:${books[id]!.sourceId}',
              sourceName: books[id]?.sourceName ?? '',
            ),
          );
        } finally {
          report('');
        }
      }
    } finally {
      executionGate.finish(execution);
      if (ref.mounted) {
        activity.finish(run);
        await refresh();
      }
    }
    final result = LibraryUpdateResult(
      requestedBooks: ids.length,
      checkedBooks: checked,
      addedChapters: added,
      skippedBooks: skipped,
      failures: failures,
      skipped: skippedDetails,
      revision: revision,
    );
    if (ref.mounted) {
      ref.read(libraryUpdateReportProvider.notifier).completed(result);
    }
    if (cancelled) throw LibraryUpdateCancelled();
    if (ref.mounted) {
      await notifications.updateCompleted(
        checked,
        added,
        failures.length,
        privateSession: privateSession,
        expectedPrivacyGeneration: privacyGeneration,
        isCurrent: () =>
            ref.mounted && repository.replacementRevision == revision,
      );
    }
    return result;
  }

  Future<LibraryUpdateResult> retryFailedUpdates(
    LibraryUpdateResult previous, {
    void Function(LibraryUpdateProgress)? onProgress,
  }) => updateBooks(
    previous.failures.map((failure) => failure.bookId),
    expectedRevision: previous.revision,
    onProgress: onProgress,
  );

  Future<int?> _updateBookChapters(
    String id,
    int revision,
    LibraryUpdateExecution execution,
  ) async {
    final key = '$revision:$id';
    final existing = _chapterUpdates[key];
    if (existing != null) return existing;
    final operation = _fetchBookChapters(id, revision, execution);
    _chapterUpdates[key] = operation;
    try {
      return await operation;
    } finally {
      if (identical(_chapterUpdates[key], operation)) {
        _chapterUpdates.remove(key);
      }
    }
  }

  Future<int?> _fetchBookChapters(
    String id,
    int revision,
    LibraryUpdateExecution execution,
  ) async {
    final notifications = ref.read(taskNotificationsProvider.notifier);
    final privacyGeneration = notifications.privacyGeneration;
    final privateSession = ref.read(settingsProvider).incognitoMode;
    execution.check();
    checkLibraryRevision(repository.replacementRevision, revision);
    final current = await repository.find(id);
    execution.check();
    checkLibraryRevision(repository.replacementRevision, revision);
    if (current == null || current.engine == 'local') return null;
    if (!ref.mounted) throw StateError('Phiên cập nhật đã kết thúc.');
    await ref.read(libraryUpdateExecutionProvider).wait(execution);
    final source = ref.read(sourceRepositoryProvider);
    final latest = await source.chapters(catalogue(current));
    execution.check();
    checkLibraryRevision(repository.replacementRevision, revision);
    if (!ref.mounted) throw StateError('Phiên cập nhật đã kết thúc.');
    if (latest.isEmpty && current.chapters.isNotEmpty) {
      throw StateError(
        'Nguồn trả mục lục trống. Các chương đang có được giữ nguyên.',
      );
    }
    if (latest.any((chapter) => chapter.ref.isEmpty)) {
      throw StateError('Nguồn trả chương thiếu mã định danh.');
    }
    final discoveredAt = DateTime.now();
    final existingIds = current.chapters.map((c) => c.id).toSet();
    final added = await repository.updateChapterOrder(
      current,
      latest
          .map(
            (chapter) => BookChapter(
              id: chapter.ref,
              title: chapter.title,
              index: chapter.index,
              uploadedAt: chapter.uploadedAt,
              discoveredAt: existingIds.contains(chapter.ref)
                  ? null
                  : discoveredAt,
              scanlator: chapter.scanlator,
              number: chapter.number,
            ),
          )
          .toList(),
      expectedRevision: revision,
    );
    if (ref.mounted && added > 0) {
      // This code owns the deduplicated fetch/commit. Two scopes awaiting the
      // same update cannot each announce the same newly discovered chapters.
      await notifications.bookUpdate(
        current.id,
        added,
        privateSession: privateSession,
        expectedPrivacyGeneration: privacyGeneration,
        isCurrent: () {
          if (!ref.mounted || repository.replacementRevision != revision) {
            return false;
          }
          try {
            execution.check();
            return true;
          } on LibraryUpdateCancelled {
            return false;
          }
        },
      );
    }
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
