import 'package:flutter/material.dart';

import '../domain/reader_options.dart';

/// Source ordinals stay stable when visual pages are paired or inverted.
class PagedMangaReader extends StatelessWidget {
  const PagedMangaReader({
    super.key,
    required this.viewportKey,
    required this.controller,
    required this.options,
    required this.pageCount,
    required this.onChanged,
    required this.page,
    required this.boundary,
  });
  final Key viewportKey;
  final PageController controller;
  final ReaderOptions options;
  final int pageCount;
  final ValueChanged<int> onChanged;
  final Widget Function(int index, double width, double height) page;
  final Widget boundary;

  @override
  Widget build(BuildContext context) {
    final perView = options.pagesPerView;
    final count = (pageCount / perView).ceil();
    final margins = options.pageMargins(MediaQuery.orientationOf(context));
    return PageView.builder(
      key: viewportKey,
      controller: controller,
      scrollDirection: options.mangaLayout == 'verticalPages'
          ? Axis.vertical
          : Axis.horizontal,
      reverse: options.mangaLayout == 'rightToLeft',
      onPageChanged: onChanged,
      itemCount: count + 1,
      itemBuilder: (context, index) {
        if (index == count) return SingleChildScrollView(child: boundary);
        final ordinals = [
          for (
            var offset = 0;
            offset < perView && index * perView + offset < pageCount;
            offset++
          )
            index * perView + offset,
        ];
        final ordered = options.invertDoublePages && perView == 2
            ? ordinals.reversed.toList()
            : ordinals;
        return Padding(
          padding: EdgeInsets.fromLTRB(margins.left, 0, margins.right, 0),
          child: LayoutBuilder(
            builder: (context, bounds) {
              final gap = perView == 2 ? options.gap : 0.0;
              final width = ((bounds.maxWidth - gap) / perView).clamp(
                1.0,
                double.infinity,
              );
              return Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  for (var slot = 0; slot < ordered.length; slot++) ...[
                    if (slot > 0) SizedBox(width: gap),
                    SizedBox(
                      width: width,
                      height: bounds.maxHeight,
                      child: page(ordered[slot], width, bounds.maxHeight),
                    ),
                  ],
                ],
              );
            },
          ),
        );
      },
    );
  }
}
