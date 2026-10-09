import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../../domain/library_book.dart';
import '../library_snapshot.dart';

class ExternalChapter {
  const ExternalChapter({
    required this.url,
    required this.title,
    required this.order,
    required this.read,
    this.bookmarked = false,
    this.lastPage = 0,
    this.pageCount = 0,
    this.lastRead = 0,
  });
  final String url, title;
  final int order, lastPage, pageCount, lastRead;
  final bool read, bookmarked;
  double get progress => read
      ? 1
      : pageCount > 1
      ? (lastPage / (pageCount - 1)).clamp(0, 1).toDouble()
      : 0;
}

class ExternalTitle {
  const ExternalTitle({
    required this.source,
    required this.url,
    required this.title,
    this.author = '',
    this.artist = '',
    this.genres = const [],
    this.notes = '',
    this.description = '',
    this.cover = '',
    this.categories = const [],
    this.chapters = const [],
    this.lastRead = 0,
    this.lastChapter = '',
  });
  final String source,
      url,
      title,
      author,
      artist,
      notes,
      description,
      cover,
      lastChapter;
  final List<String> genres;
  final List<String> categories;
  final List<ExternalChapter> chapters;
  final int lastRead;
}

class ConvertedBackup {
  const ConvertedBackup(this.format, this.snapshot, this.warnings);
  final String format;
  final LibrarySnapshot snapshot;
  final List<String> warnings;
}

ConvertedBackup convertExternalLibrary(
  String format,
  List<ExternalTitle> titles, {
  List<String> warnings = const [],
}) {
  final result = <LibrarySnapshotEntry>[];
  final ids = <String>{};
  var multipleCategories = 0;
  var localSources = 0;
  var unknownPagePositions = 0;
  for (final title in titles) {
    if (title.title.trim().isEmpty ||
        title.url.isEmpty ||
        BigInt.tryParse(title.source) == null) {
      throw const FormatException(
        'Sao lưu có tên truyện, URL hoặc ID nguồn không hợp lệ.',
      );
    }
    final id = sha256
        .convert(utf8.encode('tachimanga:${title.source}:${title.url}'))
        .toString();
    if (!ids.add(id)) {
      throw const FormatException('Sao lưu có truyện trùng nguồn và URL.');
    }
    if (title.source == '0') localSources++;
    if (title.categories.length > 1) multipleCategories++;
    // Both verified schemas use source_order=0 for the newest chapter.
    final ordered = title.chapters.indexed.toList()
      ..sort((a, b) {
        final order = b.$2.order.compareTo(a.$2.order);
        return order == 0 ? a.$1.compareTo(b.$1) : order;
      });
    final chapters = ordered.map((entry) => entry.$2).toList();
    var current = chapters.indexWhere(
      (chapter) => chapter.url == title.lastChapter,
    );
    if (current < 0 && chapters.any((chapter) => chapter.lastRead > 0)) {
      current = 0;
      for (var i = 1; i < chapters.length; i++) {
        if (chapters[i].lastRead > chapters[current].lastRead) current = i;
      }
    }
    if (current < 0) current = chapters.indexWhere((chapter) => !chapter.read);
    if (current < 0) current = chapters.isEmpty ? 0 : chapters.length - 1;
    final chapterIds = <String>{};
    for (final chapter in chapters) {
      if (chapter.url.isEmpty ||
          chapter.title.trim().isEmpty ||
          !chapterIds.add(chapter.url) ||
          chapter.lastPage < 0 ||
          chapter.pageCount < 0) {
        throw const FormatException(
          'Sao lưu có chương trống, trùng hoặc vị trí đọc không hợp lệ.',
        );
      }
      if (chapter.lastPage > 0 && chapter.pageCount < 2 && !chapter.read) {
        unknownPagePositions++;
      }
    }
    final lastRead = [
      title.lastRead,
      ...chapters.map((chapter) => chapter.lastRead),
    ].fold<int>(0, (a, b) => a > b ? a : b);
    DateTime? date;
    if (lastRead > 0) {
      try {
        date = DateTime.fromMillisecondsSinceEpoch(lastRead, isUtc: true);
      } on ArgumentError {
        throw const FormatException('Ngày đọc trong sao lưu không hợp lệ.');
      }
    }
    result.add(
      LibrarySnapshotEntry(
        LibraryBook(
          id: id,
          title: title.title,
          author: title.author,
          artist: title.artist,
          genres: title.genres,
          notes: title.notes,
          description: title.description,
          cover: title.cover,
          kind: 'manga',
          engine: 'tachimanga',
          sourceId: title.source,
          sourceRef: title.url,
          collection: title.categories.firstOrNull ?? 'Mặc định',
          currentChapter: current,
          progress: chapters.isEmpty
              ? 0
              : (current + chapters[current].progress) / chapters.length,
          lastRead: date,
          completed:
              chapters.isNotEmpty && chapters.every((chapter) => chapter.read),
          chapters: [
            for (var i = 0; i < chapters.length; i++)
              BookChapter(
                id: chapters[i].url,
                title: chapters[i].title,
                index: i,
                read: chapters[i].read,
                // Source backups contain metadata, never the offline page bytes.
                downloaded: false,
              ),
          ],
          bookmarks: [
            for (var i = 0; i < chapters.length; i++)
              if (chapters[i].bookmarked) '$i:${chapters[i].progress}',
          ],
        ),
        {},
      ),
    );
  }
  return ConvertedBackup(format, LibrarySnapshot(result), [
    ...warnings,
    'Chỉ nhập thư viện, chương, trạng thái đọc, dấu trang và lịch sử gần nhất. '
        'Nội dung offline từ app gốc không được nhập qua adapter này. '
        'Các chương được đánh dấu chưa tải; cần nguồn tương ứng để tải lại.',
    'Extension, thiết lập, tài khoản, tracker và thời gian đọc chi tiết không được nhập.',
    if (multipleCategories > 0)
      '$multipleCategories truyện có nhiều danh mục: '
          'chỉ giữ danh mục đầu tiên theo thứ tự vì thư viện hiện dùng một bộ sưu tập cho mỗi truyện.',
    if (localSources > 0)
      '$localSources truyện thuộc nguồn local: file gốc không có trong backup này.',
    if (unknownPagePositions > 0)
      '$unknownPagePositions chương thiếu số trang nên không thể đổi '
          'vị trí trang thành phần trăm; trạng thái đọc và chương hiện tại vẫn được giữ.',
  ]);
}
