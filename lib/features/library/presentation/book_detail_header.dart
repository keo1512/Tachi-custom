import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../domain/library_book.dart';
import '../domain/reading_statistics.dart';
import 'book_cover_viewer.dart';
import 'library_source_label.dart';

class BookDetailHeader extends StatelessWidget {
  const BookDetailHeader({
    super.key,
    required this.book,
    required this.descriptionExpanded,
    required this.onToggleDescription,
    required this.onFavorite,
    required this.onEditNotes,
    required this.onResume,
    this.coverImage,
    this.onCopySource,
    this.onOpenWebsite,
    this.onSearchTitle,
    this.onSearchAuthor,
    this.onSearchGenre,
  });

  final LibraryBook book;
  final ImageProvider<Object>? coverImage;
  final bool descriptionExpanded;
  final VoidCallback onToggleDescription, onFavorite, onEditNotes;
  final VoidCallback? onResume, onCopySource, onOpenWebsite;
  final VoidCallback? onSearchTitle, onSearchAuthor;
  final ValueChanged<String>? onSearchGenre;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final secondary = theme.colorScheme.onSurface.withValues(alpha: .64);
    final background = theme.scaffoldBackgroundColor;
    final image = coverImage ?? _coverProvider(book.cover);
    final chapter = book.chapters.isEmpty
        ? null
        : book.chapters[book.currentChapter.clamp(0, book.chapters.length - 1)];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Stack(
          children: [
            Positioned.fill(
              child: ExcludeSemantics(
                child: _Artwork(
                  key: const ValueKey('book-detail-background'),
                  cover: book.cover,
                  coverImage: image,
                ),
              ),
            ),
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      background.withValues(alpha: .76),
                      background.withValues(alpha: .82),
                      background,
                    ],
                  ),
                ),
              ),
            ),
            Padding(
              padding: EdgeInsets.fromLTRB(
                12,
                MediaQuery.paddingOf(context).top + kToolbarHeight + 12,
                12,
                16,
              ),
              child: LayoutBuilder(
                builder: (context, size) {
                  final coverWidth = (size.maxWidth * .27).clamp(88.0, 124.0);
                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        width: coverWidth,
                        height: coverWidth * 1.43,
                        child: GestureDetector(
                          key: const ValueKey('book-detail-open-cover'),
                          onTap: image == null
                              ? null
                              : () => Navigator.of(context).push<void>(
                                  MaterialPageRoute(
                                    fullscreenDialog: true,
                                    builder: (_) => BookCoverViewer(
                                      title: book.title,
                                      image: image,
                                    ),
                                  ),
                                ),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(10),
                            child: Semantics(
                              image: true,
                              button: image != null,
                              label: 'Bìa ${book.title}',
                              child: _Artwork(
                                key: const ValueKey('book-detail-cover'),
                                cover: book.cover,
                                coverImage: image,
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            GestureDetector(
                              onLongPress: onSearchTitle,
                              child: Tooltip(
                                message: book.title,
                                child: Text(
                                  book.title,
                                  maxLines: 4,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontSize: 20,
                                    height: 1.18,
                                  ),
                                ),
                              ),
                            ),
                            for (final name in book.alternativeTitles) ...[
                              const SizedBox(height: 5),
                              Text(
                                name,
                                key: ValueKey('book-alternative-title-$name'),
                                style: TextStyle(
                                  color: secondary,
                                  fontSize: 12,
                                ),
                              ),
                            ],
                            if (book.author.isNotEmpty) ...[
                              const SizedBox(height: 6),
                              GestureDetector(
                                onLongPress: onSearchAuthor,
                                child: Text(
                                  book.author,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: secondary,
                                    fontSize: 13,
                                  ),
                                ),
                              ),
                            ],
                            if (book.artist.isNotEmpty) ...[
                              const SizedBox(height: 5),
                              Text(
                                'Họa sĩ: ${book.artist}',
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: secondary,
                                  fontSize: 12,
                                ),
                              ),
                            ],
                            const SizedBox(height: 7),
                            Text(
                              librarySourceLabel(book),
                              style: TextStyle(color: secondary, fontSize: 12),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              switch (book.status) {
                                1 => 'Đang tiến hành',
                                2 => 'Đã hoàn tất',
                                3 => 'Đã được cấp phép',
                                4 => 'Đã kết thúc xuất bản',
                                5 => 'Đã hủy',
                                6 => 'Tạm ngừng',
                                _ => 'Chưa rõ trạng thái phát hành',
                              },
                              style: TextStyle(color: secondary, fontSize: 12),
                            ),
                            if (book.lastUpdated != null) ...[
                              const SizedBox(height: 5),
                              Text(
                                'Cập nhật: ${book.lastUpdated!.day}/${book.lastUpdated!.month}/${book.lastUpdated!.year}',
                                style: TextStyle(
                                  color: secondary,
                                  fontSize: 12,
                                ),
                              ),
                            ],
                            const SizedBox(height: 6),
                            Text(
                              'Trạng thái đọc: ${readingStateLabel(readingStateOf(book))}',
                              key: const ValueKey('book-detail-reading-state'),
                              style: TextStyle(color: secondary, fontSize: 12),
                            ),
                            const SizedBox(height: 6),
                            Row(
                              children: [
                                Icon(
                                  CupertinoIcons.book,
                                  size: 16,
                                  color: secondary,
                                ),
                                const SizedBox(width: 5),
                                Expanded(
                                  child: Text(
                                    book.completed
                                        ? 'Đã đọc xong'
                                        : '${(book.progress * 100).round()}% đã đọc',
                                    style: TextStyle(
                                      color: secondary,
                                      fontSize: 12,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            if (onCopySource != null) ...[
                              const SizedBox(height: 9),
                              SelectableText(
                                book.sourceRef,
                                maxLines: 3,
                                style: TextStyle(
                                  color: secondary,
                                  fontSize: 12,
                                  height: 1.3,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            children: [
              Expanded(
                child: Row(
                  children: [
                    Icon(
                      CupertinoIcons.bookmark_fill,
                      size: 20,
                      color: theme.colorScheme.primary,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        'Trong thư viện',
                        maxLines: 2,
                        style: TextStyle(
                          color: theme.colorScheme.primary,
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: TextButton.icon(
                  onPressed: onFavorite,
                  icon: Icon(
                    book.favorite
                        ? CupertinoIcons.heart_fill
                        : CupertinoIcons.heart,
                    size: 20,
                  ),
                  label: const Text(
                    'Yêu thích',
                    style: TextStyle(fontSize: 12),
                  ),
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                  ),
                ),
              ),
              if (onOpenWebsite != null || onCopySource != null)
                Expanded(
                  child: TextButton.icon(
                    onPressed: onOpenWebsite ?? onCopySource,
                    icon: Icon(
                      onOpenWebsite != null
                          ? CupertinoIcons.globe
                          : CupertinoIcons.link,
                      size: 19,
                    ),
                    label: Text(
                      onOpenWebsite != null ? 'Xem trang web' : 'Địa chỉ nguồn',
                      style: const TextStyle(fontSize: 12),
                    ),
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                    ),
                  ),
                ),
            ],
          ),
        ),
        if (book.description.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 2),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SelectionArea(
                  child: Text(
                    book.description,
                    key: const ValueKey('book-detail-description'),
                    maxLines: descriptionExpanded ? null : 3,
                    overflow: descriptionExpanded
                        ? TextOverflow.visible
                        : TextOverflow.fade,
                    style: const TextStyle(fontSize: 14, height: 1.45),
                  ),
                ),
                IconButton(
                  tooltip: descriptionExpanded
                      ? 'Thu gọn giới thiệu'
                      : 'Mở rộng giới thiệu',
                  onPressed: onToggleDescription,
                  icon: Icon(
                    descriptionExpanded
                        ? CupertinoIcons.chevron_up
                        : CupertinoIcons.chevron_down,
                    size: 18,
                  ),
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ),
          ),
        if (book.genres.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final genre in book.genres)
                  GestureDetector(
                    onTap: onSearchGenre == null
                        ? null
                        : () => onSearchGenre!(genre),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 9,
                        vertical: 8,
                      ),
                      decoration: BoxDecoration(
                        border: Border.all(
                          color: secondary.withValues(alpha: .55),
                        ),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        genre,
                        style: TextStyle(fontSize: 12, color: secondary),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        if (book.notes.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 6, 16, 12),
            child: GestureDetector(
              onTap: onEditNotes,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Ghi chú cá nhân',
                    style: TextStyle(
                      color: theme.colorScheme.primary,
                      fontSize: 13,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    book.notes,
                    maxLines: 4,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 13, height: 1.4),
                  ),
                ],
              ),
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 18),
          child: SizedBox(
            width: double.infinity,
            child: CupertinoButton.filled(
              key: const ValueKey('book-detail-resume'),
              onPressed: onResume,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              borderRadius: BorderRadius.circular(100),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    book.lastRead == null ? 'Bắt đầu đọc' : 'Đọc tiếp',
                    style: const TextStyle(fontSize: 14),
                  ),
                  if (book.lastRead != null && chapter != null) ...[
                    const SizedBox(width: 5),
                    Flexible(
                      child: Text(
                        chapter.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 14),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _Artwork extends StatefulWidget {
  const _Artwork({super.key, required this.cover, this.coverImage});
  final String cover;
  final ImageProvider<Object>? coverImage;

  @override
  State<_Artwork> createState() => _ArtworkState();
}

class _ArtworkState extends State<_Artwork> {
  ImageProvider<Object>? provider;

  @override
  void initState() {
    super.initState();
    resolveCover();
  }

  @override
  void didUpdateWidget(_Artwork oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.cover != widget.cover ||
        oldWidget.coverImage != widget.coverImage) {
      resolveCover();
    }
  }

  void resolveCover() {
    provider = widget.coverImage ?? _coverProvider(widget.cover);
  }

  @override
  Widget build(BuildContext context) {
    final fallback = ColoredBox(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Center(
        child: Icon(
          CupertinoIcons.book,
          size: 32,
          color: Theme.of(context).colorScheme.onSurface.withValues(alpha: .35),
        ),
      ),
    );
    if (provider == null) return fallback;
    return Image(
      image: provider!,
      fit: BoxFit.cover,
      errorBuilder: (_, _, _) => fallback,
    );
  }
}

ImageProvider<Object>? _coverProvider(String cover) {
  try {
    if (cover.startsWith('data:')) {
      return MemoryImage(base64Decode(cover.substring(cover.indexOf(',') + 1)));
    }
    final url = Uri.tryParse(cover);
    if (url != null &&
        ['http', 'https'].contains(url.scheme) &&
        url.hasAuthority) {
      return NetworkImage(cover);
    }
  } on FormatException {
    return null;
  }
  return null;
}
