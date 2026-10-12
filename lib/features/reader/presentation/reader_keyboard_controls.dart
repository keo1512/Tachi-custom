import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// External keys scroll the same continuous viewport as touch and the slider.
/// Chapter jumps require Control, leaving left/right keys available to controls.
class ReaderKeyboardControls extends StatelessWidget {
  const ReaderKeyboardControls({
    super.key,
    required this.scroll,
    required this.canScroll,
    required this.onChapter,
    required this.child,
  });
  final ScrollController scroll;
  final bool Function() canScroll;
  final ValueChanged<int> onChapter;
  final Widget child;
  void move(double delta, {double? edge}) {
    if (!canScroll() || !scroll.hasClients) return;
    final position = scroll.position;
    scroll.jumpTo(
      (edge ?? (scroll.offset + delta)).clamp(
        position.minScrollExtent,
        position.maxScrollExtent,
      ),
    );
  }

  void page(int direction) {
    if (!scroll.hasClients) return;
    move(direction * scroll.position.viewportDimension * .85);
  }

  @override
  Widget build(BuildContext context) => CallbackShortcuts(
    bindings: {
      const SingleActivator(LogicalKeyboardKey.arrowDown): () => move(80),
      const SingleActivator(LogicalKeyboardKey.arrowUp): () => move(-80),
      const SingleActivator(LogicalKeyboardKey.pageDown): () => page(1),
      const SingleActivator(LogicalKeyboardKey.pageUp): () => page(-1),
      const SingleActivator(LogicalKeyboardKey.space): () => page(1),
      const SingleActivator(LogicalKeyboardKey.space, shift: true): () =>
          page(-1),
      const SingleActivator(LogicalKeyboardKey.home): () => move(0, edge: 0),
      const SingleActivator(LogicalKeyboardKey.end): () {
        if (scroll.hasClients) move(0, edge: scroll.position.maxScrollExtent);
      },
      const SingleActivator(LogicalKeyboardKey.arrowRight, control: true): () {
        if (canScroll()) onChapter(1);
      },
      const SingleActivator(LogicalKeyboardKey.arrowLeft, control: true): () {
        if (canScroll()) onChapter(-1);
      },
    },
    child: Focus(autofocus: true, child: child),
  );
}
