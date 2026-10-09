import 'dart:convert';

import 'package:html/parser.dart' as html;

import '../domain/library_book.dart';
import '../domain/library_reading.dart';

class LibraryChapterRead {
  const LibraryChapterRead({
    required this.book,
    required this.index,
    required this.revision,
    this.content,
  });
  final LibraryBook book;
  final int index, revision;
  final ReaderContent? content;
  String get chapterId => book.chapters[index].id;
}

String bookSourceIdentity(LibraryBook book) =>
    jsonEncode([book.engine, book.sourceId, book.sourceRef, book.kind]);

void checkLibraryRevision(int actual, int? expected) {
  if (expected != null && actual != expected) {
    throw StateError(
      'Thư viện đã được thay đổi hoặc khôi phục. Hãy mở lại sách trước khi tiếp tục.',
    );
  }
}

void checkChapterContent(LibraryBook book, ReaderContent content) {
  if (content.kind != book.kind || !['novel', 'manga'].contains(content.kind)) {
    throw StateError('Nguồn trả nội dung không đúng loại sách.');
  }
  bool imageUrl(String source) {
    if (source.startsWith('data:image/') ||
        source.startsWith('tachi-asset://')) {
      return true;
    }
    final uri = Uri.tryParse(source);
    return uri != null &&
        uri.hasAuthority &&
        ['http', 'https'].contains(uri.scheme);
  }

  if (content.kind == 'manga') {
    if (content.images.isEmpty ||
        content.images.any((source) => !imageUrl(source))) {
      throw StateError('Nguồn chưa trả về trang ảnh hợp lệ cho chương.');
    }
  } else {
    final document = html.parseFragment(content.html);
    for (final hidden in document.querySelectorAll('script, style')) {
      hidden.remove();
    }
    if ((document.text ?? '').trim().isEmpty &&
        !document
            .querySelectorAll('img')
            .any((image) => imageUrl(image.attributes['src'] ?? ''))) {
      throw StateError('Nguồn trả nội dung chương trống.');
    }
  }
}

bool chapterIsOffline(ReaderContent content) {
  bool local(String source) =>
      source.startsWith('data:image/') || source.startsWith('tachi-asset://');
  if (!content.images.every(local)) return false;
  return html
      .parseFragment(content.html)
      .querySelectorAll('img')
      .every(
        (image) =>
            local(image.attributes['src'] ?? '') &&
            !image.attributes.containsKey('srcset'),
      );
}

class ChapterOrderChange {
  const ChapterOrderChange(this.book, this.previousIndices, this.additions);
  final LibraryBook book;
  final List<int?> previousIndices;
  final int additions;
}

/// Use the latest metadata and chapter flags, never the pre-network copy.
ChapterOrderChange remapChapterOrder(
  LibraryBook book,
  List<BookChapter> incoming,
) {
  if (book.engine == 'tachimanga' &&
      book.chapters.any((chapter) => RegExp(r'^\d+$').hasMatch(chapter.id)) &&
      incoming.any((chapter) => !RegExp(r'^\d+$').hasMatch(chapter.id))) {
    throw StateError(
      'Truyện cũ dùng số thứ tự làm mã chương. Chưa thể xác minh chuyển sang '
      'URL chương; mục lục, nội dung đã tải và dấu trang được giữ nguyên.',
    );
  }
  if (incoming.map((chapter) => chapter.id).toSet().length != incoming.length) {
    throw StateError('Nguồn trả mục lục có mã chương trùng');
  }
  final old = {
    for (var index = 0; index < book.chapters.length; index++)
      book.chapters[index].id: index,
  };
  final previous = incoming.map((chapter) => old[chapter.id]).toList();
  final chapters = incoming.map((chapter) {
    final oldIndex = old[chapter.id];
    return chapter.copyWith(
      downloaded: oldIndex == null ? false : book.chapters[oldIndex].downloaded,
      read: oldIndex == null ? false : chapterIsRead(book, oldIndex),
    );
  }).toList();
  final current = book.chapters.isEmpty
      ? 0
      : book.currentChapter.clamp(0, book.chapters.length - 1);
  final newCurrent = previous.indexOf(current);
  final fraction = (book.progress * book.chapters.length - current).clamp(
    0.0,
    1.0,
  );
  final marks = <String>[];
  for (final mark in book.bookmarks) {
    final parts = mark.split(':');
    final index = parts.length == 2 ? int.tryParse(parts[0]) : null;
    final position = parts.length == 2 ? double.tryParse(parts[1]) : null;
    if (index == null || position == null || !position.isFinite) continue;
    final mapped = previous.indexOf(index);
    if (mapped >= 0) {
      marks.add('$mapped:${position.clamp(0, 1).toStringAsFixed(4)}');
    }
  }
  return ChapterOrderChange(
    book.copyWith(
      chapters: chapters,
      completed: book.completed && previous.every((index) => index != null),
      currentChapter: newCurrent < 0 ? 0 : newCurrent,
      progress: chapters.isEmpty || newCurrent < 0
          ? 0
          : (newCurrent + fraction) / chapters.length,
      bookmarks: marks,
    ),
    previous,
    incoming.where((chapter) => !old.containsKey(chapter.id)).length,
  );
}
