import 'package:flutter/widgets.dart';

/// Hold a page and move upward/downward to change speed in 10 px/s steps.
/// The reader owns the timer so lifecycle/loading guards apply to both modes.
class ReaderHoldScroll extends StatefulWidget {
  const ReaderHoldScroll({
    super.key,
    required this.enabled,
    required this.speed,
    required this.onSpeed,
    required this.onStop,
    required this.child,
  });
  final bool enabled;
  final double speed;
  final ValueChanged<double> onSpeed;
  final VoidCallback onStop;
  final Widget child;

  @override
  State<ReaderHoldScroll> createState() => _ReaderHoldScrollState();
}

class _ReaderHoldScrollState extends State<ReaderHoldScroll>
    with WidgetsBindingObserver {
  bool holding = false;
  double initialSpeed = 40;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  void stop() {
    if (!holding) return;
    holding = false;
    widget.onStop();
  }

  @override
  void didUpdateWidget(covariant ReaderHoldScroll oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.enabled) stop();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) stop();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => GestureDetector(
    behavior: HitTestBehavior.translucent,
    onLongPressStart: widget.enabled
        ? (_) {
            holding = true;
            initialSpeed = widget.speed.clamp(10.0, 200.0);
            widget.onSpeed(initialSpeed);
          }
        : null,
    onLongPressMoveUpdate: widget.enabled
        ? (details) {
            if (!holding) return;
            final steps = (-details.offsetFromOrigin.dy / 40).round();
            widget.onSpeed((initialSpeed + steps * 10).clamp(10.0, 200.0));
          }
        : null,
    onLongPressEnd: widget.enabled ? (_) => stop() : null,
    onLongPressCancel: widget.enabled ? stop : null,
    child: widget.child,
  );
}
