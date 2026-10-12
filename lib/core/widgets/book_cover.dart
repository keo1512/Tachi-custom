import 'dart:convert';

import 'package:flutter/material.dart';

class BookCover extends StatelessWidget {
  const BookCover({
    super.key,
    required this.title,
    this.cover = '',
    this.kind = 'novel',
    this.unread = 0,
    this.downloaded = 0,
    this.showDownloadedBadge = false,
    this.showTitle = true,
    this.local = false,
  });
  final String title, cover, kind;
  final int unread, downloaded;
  final bool showDownloadedBadge;
  final bool showTitle, local;

  @override
  Widget build(BuildContext context) {
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
              if (cover.startsWith('data:'))
                Image.memory(
                  base64Decode(cover.substring(cover.indexOf(',') + 1)),
                  fit: BoxFit.cover,
                  errorBuilder: (_, _, _) => const SizedBox.shrink(),
                )
              else if (cover.isNotEmpty)
                Image.network(
                  cover,
                  fit: BoxFit.cover,
                  errorBuilder: (_, _, _) => const SizedBox.shrink(),
                ),
              if (cover.isEmpty)
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
              if(showTitle) Positioned(
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
                child: Row(
                  children: [
                    if(local) const Icon(Icons.folder, size:16,color:Colors.white),
                    if (unread > 0)
                      Flexible(
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          child: _Badge('$unread', const Color(0xFFAFC4FF)),
                        ),
                      ),
                    if (showDownloadedBadge && downloaded > 0)
                      _Badge('$downloaded', const Color(0xFF34835C)),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
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
