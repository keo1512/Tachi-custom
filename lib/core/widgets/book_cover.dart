import 'dart:convert';

import 'package:flutter/material.dart';

class BookCover extends StatelessWidget {
  const BookCover({
    super.key,
    required this.title,
    this.cover = '',
    this.imageProvider,
    this.kind = 'novel',
    this.unread = 0,
    this.downloaded = 0,
    this.showDownloadedBadge = false,
    this.showTitle = true,
    this.local = false,
  });
  final String title, cover, kind;
  final ImageProvider<Object>? imageProvider;
  final int unread, downloaded;
  final bool showDownloadedBadge;
  final bool showTitle, local;

  @override
  Widget build(BuildContext context) {
    final image = imageProvider ?? _coverProvider(cover);
    final colors = <List<Color>>[
      [const Color(0xFF203A46), const Color(0xFF65817C)],
      [const Color(0xFFB98660), const Color(0xFF503D39)],
      [const Color(0xFF474A71), const Color(0xFF9894A4)],
      [const Color(0xFF3F6656), const Color(0xFF9CA981)],
    ];
    final palette =
        colors[title.codeUnits.fold<int>(0, (a, b) => a + b) % colors.length];
    return Semantics(
      label: title,
      image: true,
      child: ExcludeSemantics(
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: Stack(
            fit: StackFit.expand,
            children: [
              DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: palette,
                  ),
                ),
              ),
              if (image != null)
                Image(
                  image: image,
                  fit: BoxFit.cover,
                  frameBuilder: (_, child, frame, synchronous) =>
                      synchronous || frame != null
                      ? child
                      : const Center(
                          child: Icon(
                            Icons.hourglass_top,
                            key: ValueKey('book-cover-loading'),
                            size: 20,
                            color: Colors.white70,
                          ),
                        ),
                  errorBuilder: (_, _, _) => const Center(
                    child: Tooltip(
                      message: 'Chưa tải được ảnh bìa',
                      child: Icon(
                        Icons.broken_image_outlined,
                        key: ValueKey('book-cover-error'),
                        size: 24,
                        color: Colors.white70,
                      ),
                    ),
                  ),
                ),
              if (image == null)
                LayoutBuilder(
                  builder: (_, constraints) => Padding(
                    padding: EdgeInsets.all(constraints.maxWidth * .12),
                    child: Center(
                      child: Text(
                        title,
                        maxLines: 4,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontFamily: 'NotoSerif',
                          fontSize: (constraints.maxWidth * .13).clamp(13, 24),
                          height: 1.2,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ),
                ),
              const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.center,
                    end: Alignment.bottomCenter,
                    colors: [Colors.transparent, Color(0xCC000000)],
                  ),
                ),
              ),
              if (showTitle)
                Positioned(
                  left: 5,
                  right: 5,
                  bottom: 5,
                  child: Text(
                    title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              Positioned(
                left: 8,
                right: 8,
                top: 8,
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.topLeft,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (local)
                        const Icon(Icons.folder, size: 16, color: Colors.white),
                      if (unread > 0)
                        _Badge('$unread', const Color(0xFFAFC4FF)),
                      if (showDownloadedBadge && downloaded > 0)
                        _Badge('$downloaded', const Color(0xFF34835C)),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

ImageProvider<Object>? _coverProvider(String cover) {
  if (cover.isEmpty) return null;
  try {
    if (cover.startsWith('data:')) {
      return MemoryImage(base64Decode(cover.substring(cover.indexOf(',') + 1)));
    }
    return NetworkImage(cover);
  } on FormatException {
    return null;
  }
}

class _Badge extends StatelessWidget {
  const _Badge(this.text, this.color);
  final String text;
  final Color color;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 3),
    decoration: BoxDecoration(
      color: color,
      borderRadius: BorderRadius.circular(8),
    ),
    child: Text(
      text,
      style: const TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w400,
        color: Colors.black,
      ),
    ),
  );
}
