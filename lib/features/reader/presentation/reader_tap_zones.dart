import 'package:flutter/material.dart';

enum ReaderTapAction { previous, menu, next }

ReaderTapAction readerTapAction({
  required String layout,
  required Offset point,
  required Size viewport,
  required bool inverted,
}) {
  if (layout == 'off' || viewport.isEmpty) return ReaderTapAction.menu;
  final fraction = layout == 'vertical'
      ? point.dy / viewport.height
      : point.dx / viewport.width;
  if (fraction >= 1 / 3 && fraction < 2 / 3) return ReaderTapAction.menu;
  final previous = fraction < 1 / 3;
  return previous != inverted ? ReaderTapAction.previous : ReaderTapAction.next;
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
    final labels = layout == 'off'
        ? ['Ẩn / hiện điều khiển']
        : [
            inverted ? 'Cuộn xuống' : 'Cuộn lên',
            'Điều khiển',
            inverted ? 'Cuộn lên' : 'Cuộn xuống',
          ];
    return Semantics(
      label: 'Sơ đồ vùng chạm',
      child: SizedBox(
        height: layout == 'vertical' ? 144 : 76,
        child: Flex(
          direction: layout == 'vertical' ? Axis.vertical : Axis.horizontal,
          children: [
            for (final label in labels)
              Expanded(
                child: Container(
                  alignment: Alignment.center,
                  margin: const EdgeInsets.all(2),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.primaryContainer,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(label, textAlign: TextAlign.center),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
