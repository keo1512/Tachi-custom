import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../domain/library_book.dart';
import '../domain/library_reading.dart';
import 'library_filter_sheet.dart';

/// The same enabled facts are shown in list, grid and cover-only layouts.
/// Grid rows reserve space below the cover rather than obscuring its artwork.
class LibraryBookMetadata extends StatelessWidget {
  const LibraryBookMetadata({
    super.key,
    required this.book,
    required this.filter,
    this.compact = false,
  });

  final LibraryBook book;
  final LibraryFilter filter;
  final bool compact;

  static int gridRows(LibraryFilter filter) => [
    filter.showSource,
    filter.showReadingStatus,
    filter.showReadCount,
    filter.showFavoriteBadge,
    filter.showLastUpdated,
    filter.showPublicationStatus,
  ].where((enabled) => enabled).length;

  List<({String key, String text, IconData icon})> get entries {
    final read = readChapterCount(book);
    final source = book.engine == 'local'
        ? 'Trong thiết bị'
        : book.sourceName.isNotEmpty
        ? book.sourceName
        : Uri.tryParse(book.sourceRef)?.host.isNotEmpty == true
        ? Uri.parse(book.sourceRef).host
        : '${book.engine == 'vbook' ? 'vBook' : 'Tachimanga'} · ${book.sourceId}';
    final update = book.lastUpdated?.toLocal();
    return [
      if (filter.showSource)
        (key: 'source', text: source, icon: CupertinoIcons.globe),
      if (filter.showReadingStatus)
        (
          key: 'reading',
          text:
              book.completed ||
                  (book.chapters.isNotEmpty && read == book.chapters.length)
              ? 'Đã đọc'
              : bookHasReadingProgress(book)
              ? 'Đang đọc'
              : 'Chưa đọc',
          icon: CupertinoIcons.book,
        ),
      if (filter.showReadCount)
        (
          key: 'read',
          text: '$read chương đã đọc',
          icon: CupertinoIcons.checkmark,
        ),
      if (!compact && filter.showUnreadBadge)
        (
          key: 'unread',
          text: '${book.chapters.length - read} chương chưa đọc',
          icon: CupertinoIcons.bookmark,
        ),
      if (!compact && filter.showDownloadedBadge)
        (
          key: 'downloaded',
          text:
              '${book.chapters.where((chapter) => chapter.downloaded).length} chương đã tải',
          icon: CupertinoIcons.arrow_down_circle,
        ),
      if (!compact && filter.showLocalBadge && book.engine == 'local')
        (key: 'local', text: 'Truyện trong máy', icon: CupertinoIcons.folder),
      if (filter.showFavoriteBadge)
        (
          key: 'favorite',
          text: book.favorite ? 'Yêu thích' : 'Chưa yêu thích',
          icon: book.favorite
              ? CupertinoIcons.heart_fill
              : CupertinoIcons.heart,
        ),
      if (filter.showLastUpdated)
        (
          key: 'updated',
          text: update == null
              ? 'Chưa cập nhật'
              : 'Cập nhật ${update.day}/${update.month}/${update.year}',
          icon: CupertinoIcons.clock,
        ),
      if (filter.showPublicationStatus)
        (
          key: 'status',
          text: switch (book.status) {
            1 => 'Đang tiến hành',
            2 => 'Đã hoàn tất',
            3 => 'Đã được cấp phép',
            4 => 'Đã kết thúc xuất bản',
            5 => 'Đã hủy',
            6 => 'Tạm ngừng',
            _ => 'Chưa rõ trạng thái phát hành',
          },
          icon: CupertinoIcons.info_circle,
        ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final rows = entries;
    if (rows.isEmpty) return const SizedBox.shrink();
    final color = Theme.of(context).colorScheme.onSurfaceVariant;
    Widget row(({String key, String text, IconData icon}) entry) => Tooltip(
      message: entry.text,
      child: Semantics(
        label: entry.text,
        child: ExcludeSemantics(
          child: Row(
            key: ValueKey('library-metadata-${book.id}-${entry.key}'),
            mainAxisSize: compact ? MainAxisSize.max : MainAxisSize.min,
            children: [
              Icon(entry.icon, size: compact ? 11 : 13, color: color),
              SizedBox(width: compact ? 2 : 4),
              if (compact)
                Expanded(
                  child: Text(
                    entry.text,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 11, color: color),
                  ),
                )
              else
                Flexible(
                  child: Text(
                    entry.text,
                    style: TextStyle(fontSize: 12, color: color),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
    return compact
        ? Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [for (final entry in rows) row(entry)],
          )
        : Wrap(
            spacing: 10,
            runSpacing: 4,
            children: [for (final entry in rows) row(entry)],
          );
  }
}
