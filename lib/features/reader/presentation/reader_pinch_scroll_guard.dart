import 'package:flutter/widgets.dart';

/// Let InteractiveViewer own two-finger gestures instead of either scroll axis.
/// Single-finger scrolling and wheel input use the inherited platform physics.
class ReaderPinchScrollGuard extends StatefulWidget {
  const ReaderPinchScrollGuard({super.key, required this.child});
  final Widget child;

  @override
  State<ReaderPinchScrollGuard> createState() => _ReaderPinchScrollGuardState();
}

class _ReaderPinchScrollGuardState extends State<ReaderPinchScrollGuard> {
  final pointers = <int>{};

  void track(int pointer, bool down) {
    final wasPinching = pointers.length > 1;
    down ? pointers.add(pointer) : pointers.remove(pointer);
    if (wasPinching != (pointers.length > 1)) setState(() {});
  }

  @override
  Widget build(BuildContext context) => Listener(
    onPointerDown: (event) => track(event.pointer, true),
    onPointerUp: (event) => track(event.pointer, false),
    onPointerCancel: (event) => track(event.pointer, false),
    child: ScrollConfiguration(
      behavior: pointers.length > 1
          ? ScrollConfiguration.of(context)
                .copyWith(physics: const NeverScrollableScrollPhysics())
          : ScrollConfiguration.of(context),
      child: widget.child,
    ),
  );
}
