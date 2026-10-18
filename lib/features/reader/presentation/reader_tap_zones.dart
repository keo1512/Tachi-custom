import 'package:flutter/material.dart';

enum ReaderTapAction { previous, menu, next }

/// Non-overlapping unit rectangles, shared by input and the displayed diagram.
class ReaderTapRegion {
  const ReaderTapRegion(this.bounds, this.action);
  final Rect bounds;
  final ReaderTapAction action;
}

List<ReaderTapRegion> readerTapRegions(String layout) {
  const previous = ReaderTapAction.previous;
  const menu = ReaderTapAction.menu;
  const next = ReaderTapAction.next;
  return switch (layout) {
    'horizontal' => const [
      ReaderTapRegion(Rect.fromLTRB(0, 0, 1 / 3, 1), previous),
      ReaderTapRegion(Rect.fromLTRB(1 / 3, 0, 2 / 3, 1), menu),
      ReaderTapRegion(Rect.fromLTRB(2 / 3, 0, 1, 1), next),
    ],
    'vertical' => const [
      ReaderTapRegion(Rect.fromLTRB(0, 0, 1, 1 / 3), previous),
      ReaderTapRegion(Rect.fromLTRB(0, 1 / 3, 1, 2 / 3), menu),
      ReaderTapRegion(Rect.fromLTRB(0, 2 / 3, 1, 1), next),
    ],
    'edges' => const [
      ReaderTapRegion(Rect.fromLTRB(0, 0, .2, 1), previous),
      ReaderTapRegion(Rect.fromLTRB(.2, 0, .8, 1), menu),
      ReaderTapRegion(Rect.fromLTRB(.8, 0, 1, 1), next),
    ],
    'kindle' => const [
      ReaderTapRegion(Rect.fromLTRB(0, 0, 1, .2), menu),
      ReaderTapRegion(Rect.fromLTRB(0, .2, .25, 1), previous),
      ReaderTapRegion(Rect.fromLTRB(.25, .2, 1, 1), next),
    ],
    'lShape' => const [
      ReaderTapRegion(Rect.fromLTRB(0, 0, .7, .3), previous),
      ReaderTapRegion(Rect.fromLTRB(0, .3, .3, .7), previous),
      ReaderTapRegion(Rect.fromLTRB(.3, .3, .7, .7), menu),
      ReaderTapRegion(Rect.fromLTRB(.7, 0, 1, .7), next),
      ReaderTapRegion(Rect.fromLTRB(0, .7, 1, 1), next),
    ],
    _ => const [ReaderTapRegion(Rect.fromLTRB(0, 0, 1, 1), menu)],
  };
}

ReaderTapAction _invert(ReaderTapAction action, bool inverted) =>
    !inverted || action == ReaderTapAction.menu
    ? action
    : action == ReaderTapAction.previous
    ? ReaderTapAction.next
    : ReaderTapAction.previous;

ReaderTapAction readerTapAction({
  required String layout,
  required Offset point,
  required Size viewport,
  required bool inverted,
}) {
  if (viewport.isEmpty ||
      !viewport.width.isFinite ||
      !viewport.height.isFinite ||
      !point.dx.isFinite ||
      !point.dy.isFinite ||
      point.dx < 0 ||
      point.dy < 0 ||
      point.dx >= viewport.width ||
      point.dy >= viewport.height) {
    return ReaderTapAction.menu;
  }
  final normalized = Offset(
    point.dx / viewport.width,
    point.dy / viewport.height,
  );
  for (final region in readerTapRegions(layout)) {
    if (region.bounds.contains(normalized)) {
      return _invert(region.action, inverted);
    }
  }
  return ReaderTapAction.menu;
}

class ReaderTapZoneDiagram extends StatelessWidget {
  const ReaderTapZoneDiagram({
    super.key,
    required this.layout,
    required this.inverted,
  });
  final String layout;
  final bool inverted;
  @override
  Widget build(BuildContext context) {
    final regions = readerTapRegions(layout);
    return Semantics(
      label: 'Sơ đồ vùng chạm',
      child: SizedBox(
        height: ['vertical', 'kindle', 'lShape'].contains(layout) ? 144 : 76,
        child: LayoutBuilder(
          builder: (context, size) => Stack(
            children: [
              for (final region in regions)
                Positioned.fromRect(
                  rect: Rect.fromLTRB(
                    region.bounds.left * size.maxWidth,
                    region.bounds.top * size.maxHeight,
                    region.bounds.right * size.maxWidth,
                    region.bounds.bottom * size.maxHeight,
                  ),
                  child: Container(
                    alignment: Alignment.center,
                    margin: const EdgeInsets.all(2),
                    padding: const EdgeInsets.all(4),
                    decoration: BoxDecoration(
                      color: region.action == ReaderTapAction.menu
                          ? Theme.of(context)
                                .colorScheme
                                .surfaceContainerHighest
                          : Theme.of(context).colorScheme.primaryContainer,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(switch (_invert(region.action, inverted)) {
                        ReaderTapAction.previous => 'Cuộn lên',
                        ReaderTapAction.next => 'Cuộn xuống',
                        ReaderTapAction.menu =>
                          layout == 'off'
                              ? 'Ẩn / hiện điều khiển'
                              : 'Điều khiển',
                      }, textAlign: TextAlign.center),
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
