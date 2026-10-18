import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../../core/widgets/book_cover.dart';
import '../domain/catalogue.dart';

class SourceResultTile extends StatelessWidget {
  const SourceResultTile({
    super.key,
    required this.book,
    required this.onOpen,
    this.coverImage,
    this.inLibrary = false,
    this.showLibraryLabel = false,
    this.pending = false,
    this.list = false,
  });
  final CatalogueBook book;
  final ImageProvider<Object>? coverImage;
  final VoidCallback? onOpen;
  final bool inLibrary, pending, list, showLibraryLabel;

  Widget status() => pending
      ? const CupertinoActivityIndicator()
      : Icon(
          inLibrary
              ? CupertinoIcons.checkmark_circle_fill
              : CupertinoIcons.plus_circle,
          color: inLibrary ? const Color(0xFFAFC4FF) : null,
          size: 22,
        );

  @override
  Widget build(BuildContext context) {
    if (list) {
      return ListTile(
        key: ValueKey('source-result-${book.identity}'),
        leading: SizedBox(
          width: 45,
          height: 64,
          child: BookCover(
            title: book.title,
            cover: book.coverUrl,
            imageProvider: coverImage,
            kind: book.kind.name,
          ),
        ),
        title: Text(book.title, maxLines: 2, overflow: TextOverflow.ellipsis),
        subtitle: inLibrary
            ? const Text('Trong thư viện')
            : book.author.isEmpty
            ? null
            : Text(book.author, maxLines: 1),
        trailing: status(),
        onTap: pending ? null : onOpen,
      );
    }
    return Semantics(
      label:
          '${inLibrary ? 'Mở' : 'Thêm'} ${book.title}${inLibrary ? ' trong thư viện' : ''}',
      button: true,
      child: InkWell(
        key: ValueKey('source-result-${book.identity}'),
        onTap: pending ? null : onOpen,
        child: Stack(
          fit: StackFit.expand,
          children: [
            BookCover(
              title: book.title,
              cover: book.coverUrl,
              imageProvider: coverImage,
              kind: book.kind.name,
              showPlaceholderTitle: !showLibraryLabel,
            ),
            if (pending || inLibrary || !showLibraryLabel)
              Positioned(
                top: 5,
                right: 5,
                left: showLibraryLabel && inLibrary && !pending ? 5 : null,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: showLibraryLabel && inLibrary && !pending
                        ? Theme.of(context).colorScheme.primaryContainer
                        : Theme.of(context).scaffoldBackgroundColor
                              .withValues(alpha: .8),
                    borderRadius: BorderRadius.circular(
                      showLibraryLabel && inLibrary && !pending ? 4 : 16,
                    ),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(3),
                    child: showLibraryLabel && inLibrary && !pending
                        ? Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 4),
                            child: Text(
                              'Trong thư viện',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 11,
                                color: Theme.of(context)
                                    .colorScheme
                                    .onPrimaryContainer,
                              ),
                            ),
                          )
                        : status(),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
