import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../../core/widgets/book_cover.dart';
import '../domain/library_book.dart';
import '../domain/library_reading.dart';
import 'library_book_metadata.dart';
import 'library_filter_sheet.dart';

class LibraryBookTile extends StatelessWidget {
  const LibraryBookTile({
    super.key,
    required this.book,
    required this.filter,
    this.selected,
    this.onTap,
    this.onLongPress,
    this.onResume,
  });

  final LibraryBook book;
  final LibraryFilter filter;
  final bool? selected;
  final VoidCallback? onTap, onLongPress, onResume;

  static double extraHeight(BuildContext context, LibraryFilter filter) =>
      LibraryBookMetadata.gridRows(filter) *
          (MediaQuery.textScalerOf(context).scale(11) * 1.5 + 2) +
      (filter.showResumeButton ? 36 : 0);

  @override
  Widget build(BuildContext context) {
    final selecting = selected != null;
    final color = Theme.of(context).colorScheme.primary;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: Semantics(
            label: book.title,
            button: true,
            selected: selected,
            child: InkWell(
              key: ValueKey('library-book-${book.id}'),
              onTap: onTap,
              onLongPress: onLongPress,
              child: ExcludeSemantics(
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    BookCover(
                      title: book.title,
                      cover: book.cover,
                      kind: book.kind,
                      unread: filter.showUnreadBadge
                          ? book.chapters.length - readChapterCount(book)
                          : 0,
                      downloaded: book.chapters
                          .where((chapter) => chapter.downloaded)
                          .length,
                      showDownloadedBadge: filter.showDownloadedBadge,
                      showTitle: filter.display != LibraryDisplay.coverOnly,
                      local: filter.showLocalBadge && book.engine == 'local',
                    ),
                    if (selecting)
                      DecoratedBox(
                        decoration: BoxDecoration(
                          color: selected!
                              ? color.withValues(alpha: .18)
                              : Colors.transparent,
                          border: Border.all(
                            color: selected! ? color : Colors.transparent,
                            width: 2,
                          ),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Align(
                          alignment: Alignment.bottomRight,
                          child: Padding(
                            padding: const EdgeInsets.all(3),
                            child: Icon(
                              selected!
                                  ? CupertinoIcons.checkmark_circle_fill
                                  : CupertinoIcons.circle,
                              color: selected! ? color : Colors.white,
                              size: 22,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
        LibraryBookMetadata(book: book, filter: filter, compact: true),
        if (filter.showResumeButton)
          SizedBox(
            height: 36,
            child: IconButton(
              key: ValueKey('library-resume-${book.id}'),
              tooltip: !bookHasReadingProgress(book)
                  ? 'Đọc chương đầu tiên'
                  : 'Tiếp tục đọc',
              onPressed: selecting ? null : onResume,
              icon: const Icon(CupertinoIcons.play_fill, size: 17),
            ),
          ),
      ],
    );
  }
}
