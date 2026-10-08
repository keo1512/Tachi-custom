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
import '../domain/library_book.dart';
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
    final books = await repository.list();
    if (ref.mounted) state = AsyncData(books);
  }

  Future<void> save(LibraryBook book) => _withBook(book.id, () async {
    await repository.save(book);
    await refresh();
  });

  Future<void> updateMetadata(
    String id, {
    bool? favorite,
    bool? completed,
    String? collection,
  }) => _withBook(id, () async {
    final book = await repository.find(id);
    if (book == null) return;
    await repository.save(
      book.copyWith(
        favorite: favorite,
        completed: completed,
        collection: collection,
      ),
    );
    await refresh();
  });

  Future<void> clearHistory(Iterable<String> ids) async {
    try {
      for (final id in ids.toSet()) {
        await _withBook(id, () async {
          final book = await repository.find(id);
          if (book != null) {
            await repository.save(book.copyWith(clearLastRead: true));
          }
        });
      }
    } finally {
      await refresh();
    }
  }

  Future<void> remove(String id) => _withBook(id, () async {
    await repository.remove(id);
    await refresh();
  });
  Future<void> updateProgress(String id, String chapterId, double fraction) =>
      _withBook(id, () async {
        final book = await repository.find(id);
        if (book == null || book.chapters.isEmpty) return;
        final index = book.chapters.indexWhere((c) => c.id == chapterId);
        if (index < 0) return;
        await repository.save(
          book.copyWith(
            currentChapter: index,
            progress: ((index + fraction.clamp(0, 1)) / book.chapters.length)
                .clamp(0, 1),
            lastRead: DateTime.now(),
          ),
        );
        await refresh();
      });
  Future<bool> toggleBookmark(String id, String chapterId, double fraction) =>
      _withBook(id, () async {
        final book = await repository.find(id);
        if (book == null) return false;
        final index = book.chapters.indexWhere((c) => c.id == chapterId);
        if (index < 0) return false;
        final mark = '$index:${fraction.clamp(0, 1).toStringAsFixed(4)}';
        final marks = [...book.bookmarks];
        final added = !marks.remove(mark);
        if (added) marks.add(mark);
        await repository.save(book.copyWith(bookmarks: marks));
        await refresh();
        return added;
      });
  Future<void> removeBookmark(String id, String mark) =>
      _withBook(id, () async {
        final book = await repository.find(id);
        if (book == null) return;
        await repository.save(
          book.copyWith(bookmarks: [...book.bookmarks]..remove(mark)),
        );
        await refresh();
      });

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
      description: detail.description,
      cover: detail.coverUrl,
      kind: detail.kind.name,
      engine: detail.engine.name,
      sourceId: detail.sourceId,
      sourceRef: detail.ref,
      chapters: chapters
          .map((c) => BookChapter(id: c.ref, title: c.title, index: c.index))
          .toList(),
    );
    await save(book);
    return book;
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
  }) {
    final chapterId = book.chapters[index].id;
    return _withBook(book.id, () async {
      final latest = await repository.find(book.id);
      if (latest == null) throw StateError('Sách đã được xóa khỏi thư viện');
      final target = latest.chapters.indexWhere((c) => c.id == chapterId);
      if (target < 0) throw StateError('Chương không còn trong mục lục');
      final cached = await repository.readChapter(book.id, target);
      if (cached != null && (!download || _isOffline(cached))) return cached;
      if (latest.engine == 'local') {
        throw StateError('Không tìm thấy nội dung đã nhập');
      }
      ReaderContent content;
      if (cached != null) {
        content = cached;
      } else {
        final chapter = latest.chapters[target];
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
      if (download) content = await _downloadContent(book.id, content);
      if (download || latest.kind == 'novel') {
        await repository.saveChapter(book.id, target, content);
        final updated = [...latest.chapters];
        updated[target] = updated[target].copyWith(
          downloaded: _isOffline(content),
        );
        await repository.save(latest.copyWith(chapters: updated));
        await refresh();
        return (await repository.readChapter(book.id, target))!;
      }
      return content;
    });
  }

  bool _isOffline(ReaderContent content) {
    bool local(String url) =>
        url.startsWith('data:') || url.startsWith('tachi-asset://');
    if (!content.images.every(local)) return false;
    final document = html.parseFragment(content.html);
    return document
        .querySelectorAll('img')
        .every(
          (image) =>
              local(image.attributes['src'] ?? '') &&
              !image.attributes.containsKey('srcset'),
        );
  }

  Future<ReaderContent> _downloadContent(
    String bookId,
    ReaderContent content,
  ) async {
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
      return saved[url] = await repository.storeAttachment(
        bookId,
        bytes.takeBytes(),
        type,
      );
    }

    final images = <String>[];
    for (final url in content.images) {
      images.add(await downloadImage(url));
    }
    final document = html.parseFragment(content.html);
    for (final image in document.querySelectorAll('img')) {
      image.attributes['src'] = await downloadImage(
        image.attributes['src'] ?? '',
      );
      image.attributes.remove('srcset');
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
      added += await _withBook(book.id, () async {
        final current = await repository.find(book.id);
        if (current == null) return 0;
        final latest = await ref
            .read(sourceRepositoryProvider)
            .chapters(catalogue(current));
        if (latest.map((c) => c.ref).toSet().length != latest.length) {
          throw StateError('Nguồn trả mục lục có mã chương trùng');
        }
        final old = {
          for (var i = 0; i < current.chapters.length; i++)
            current.chapters[i].id: i,
        };
        final previous = latest.map((c) => old[c.ref]).toList();
        final chapters = latest
            .map(
              (c) => BookChapter(
                id: c.ref,
                title: c.title,
                index: c.index,
                downloaded: old[c.ref] == null
                    ? false
                    : current.chapters[old[c.ref]!].downloaded,
              ),
            )
            .toList();
        final previousCurrent = current.chapters.isEmpty
            ? 0
            : current.currentChapter.clamp(0, current.chapters.length - 1);
        final newCurrent = previous.indexOf(previousCurrent);
        final fraction =
            (current.progress * current.chapters.length - previousCurrent)
                .clamp(0.0, 1.0);
        final marks = <String>[];
        for (final mark in current.bookmarks) {
          final split = mark.split(':');
          final index = split.length == 2 ? int.tryParse(split[0]) : null;
          final position = split.length == 2 ? double.tryParse(split[1]) : null;
          if (index == null || position == null || !position.isFinite) continue;
          final mapped = previous.indexOf(index);
          if (mapped >= 0) {
            marks.add('$mapped:${position.clamp(0, 1).toStringAsFixed(4)}');
          }
        }
        await repository.replaceChapterOrder(
          current.copyWith(
            chapters: chapters,
            currentChapter: newCurrent < 0 ? 0 : newCurrent,
            progress: chapters.isEmpty || newCurrent < 0
                ? 0
                : (newCurrent + fraction) / chapters.length,
            bookmarks: marks,
          ),
          previous,
        );
        return chapters.where((c) => !old.containsKey(c.id)).length;
      });
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
