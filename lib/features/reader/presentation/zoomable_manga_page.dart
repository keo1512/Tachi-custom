import 'package:flutter/material.dart';

class ZoomableMangaPage extends StatefulWidget {
  const ZoomableMangaPage({
    super.key,
    required this.child,
    this.enabled = true,
  });
  final Widget child;
  final bool enabled;
  @override
  State<ZoomableMangaPage> createState() => _ZoomableMangaPageState();
}

class _ZoomableMangaPageState extends State<ZoomableMangaPage> {
  final transform = TransformationController();
  Offset doubleTap = Offset.zero;
  bool zoomed = false;
  @override
  void dispose() {
    transform.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant ZoomableMangaPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.enabled) {
      transform.value = Matrix4.identity();
      zoomed = false;
    }
  }

  @override
  Widget build(BuildContext context) => widget.enabled
      ? GestureDetector(
          onDoubleTapDown: (details) => doubleTap = details.localPosition,
          onDoubleTap: () {
            setState(() {
              zoomed = !zoomed;
              transform.value = zoomed
                  ? (Matrix4.identity()
                      ..translateByDouble(-doubleTap.dx, -doubleTap.dy, 0, 1)
                      ..scaleByDouble(2, 2, 1, 1))
                  : Matrix4.identity();
            });
          },
          child: InteractiveViewer(
            transformationController: transform,
            minScale: 1,
            maxScale: 4,
            panEnabled: zoomed,
            onInteractionEnd: (_) => setState(
              () => zoomed = transform.value.getMaxScaleOnAxis() > 1.01,
            ),
            child: widget.child,
          ),
        )
      : widget.child;
}
