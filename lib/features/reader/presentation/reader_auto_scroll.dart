import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

final readerAutoScrollClockProvider = Provider<DateTime Function()>(
  (ref) => DateTime.now,
);

/// A scroll offset changes continuously; it never substitutes page-button taps.
class ReaderAutoScroll {
  ReaderAutoScroll(
    this.scroll, {
    required this.canScroll,
    DateTime Function()? clock,
    this.onNextPage,
    this.pageReady,
  }) : clock = clock ?? DateTime.now;
  final ScrollController scroll;
  final bool Function() canScroll;
  final DateTime Function() clock;
  final VoidCallback? onNextPage;
  final bool Function()? pageReady;
  Timer? _timer;
  DateTime? _last;
  double speed = 40;
  double? _pageSeconds;
  double _pageElapsed = 0;
  bool get running => _timer != null;
  void start(double pixelsPerSecond) {
    _pageSeconds = null;
    _pageElapsed = 0;
    speed = pixelsPerSecond.clamp(10, 200);
    if (_timer != null) return;
    _last = clock();
    _timer = Timer.periodic(const Duration(milliseconds: 16), (_) => tick());
  }

  void startTimed(double seconds) {
    final interval = seconds.clamp(2.0, 120.0);
    if (_pageSeconds != interval) _pageElapsed = 0;
    _pageSeconds = interval;
    if (_timer != null) return;
    _last = clock();
    _timer = Timer.periodic(const Duration(milliseconds: 16), (_) => tick());
  }

  void tick() {
    final now = clock();
    final previous = _last;
    _last = now;
    if (previous == null ||
        !canScroll() ||
        (_pageSeconds != null && pageReady != null
            ? !pageReady!()
            : !scroll.hasClients ||
                  scroll.position.isScrollingNotifier.value)) {
      _pageElapsed = 0;
      return;
    }
    // Bound delayed frames to avoid jumping after suspension or an expensive decode.
    final elapsed =
        now.difference(previous).inMicroseconds.clamp(0, 100000) / 1000000;
    final interval = _pageSeconds;
    if (interval != null) {
      _pageElapsed += elapsed;
      if (_pageElapsed >= interval) {
        _pageElapsed = 0;
        onNextPage?.call();
      }
      return;
    }
    final offset = (scroll.offset + speed * elapsed).clamp(
      0.0,
      scroll.position.maxScrollExtent,
    );
    if (offset != scroll.offset) scroll.jumpTo(offset);
  }

  void pause() {
    _timer?.cancel();
    _timer = null;
    _last = null;
    _pageElapsed = 0;
  }

  void dispose() => pause();
}
