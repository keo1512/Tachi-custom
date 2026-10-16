import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../domain/library_book.dart';

class ActivityBookCover extends StatelessWidget {
  const ActivityBookCover(
    this.book, {
    super.key,
    this.width = 48,
    this.height = 48,
    this.coverImage,
  });
  final LibraryBook book;
  final double width, height;
  final ImageProvider<Object>? coverImage;

  @override
  Widget build(BuildContext context) {
    final fallback = ColoredBox(
      color: Theme.of(context).colorScheme.surfaceContainerHigh,
      child: Center(
        child: Icon(
          book.kind == 'manga' ? CupertinoIcons.book : CupertinoIcons.doc_text,
          size: 23,
        ),
      ),
    );
    Widget cover = fallback;
    if (coverImage != null) {
      cover = Image(
        image: coverImage!,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => fallback,
      );
    } else if (book.cover.startsWith('data:image/')) {
      try {
        cover = Image.memory(
          UriData.parse(book.cover).contentAsBytes(),
          fit: BoxFit.cover,
          errorBuilder: (_, _, _) => fallback,
        );
      } on FormatException {
        cover = fallback;
      }
    } else if (book.cover.isNotEmpty) {
      cover = Image.network(
        book.cover,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => fallback,
      );
    }
    return Semantics(
      image: true,
      label: book.title,
      child: SizedBox(
        width: width,
        height: height,
        child: ClipRRect(borderRadius: BorderRadius.circular(8), child: cover),
      ),
    );
  }
}
