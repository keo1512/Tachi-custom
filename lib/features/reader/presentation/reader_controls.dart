import 'dart:ui';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

/// Reader chrome overlays pages, keeping the content viewport usable underneath.
class ReaderControls extends StatelessWidget {
  const ReaderControls({
    super.key,
    required this.manga,
    required this.page,
    required this.pageCount,
    required this.position,
    required this.onSeek,
    required this.onPrevious,
    required this.onNext,
    required this.onBookmark,
    required this.onDownload,
    required this.onOrientation,
    required this.onSettings,
  });

  final bool manga;
  final int page, pageCount;
  final double position;
  final ValueChanged<double>? onSeek;
  final VoidCallback? onPrevious, onNext, onBookmark, onDownload;
  final VoidCallback onOrientation, onSettings;

  Widget surface(BuildContext context, Widget child, {double radius = 28}) =>
      ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
          child: ColoredBox(
            color: Theme.of(context).scaffoldBackgroundColor
                .withValues(alpha: .78),
            child: child,
          ),
        ),
      );

  Widget chapterButton(
    BuildContext context,
    String label,
    IconData icon,
    VoidCallback? action,
  ) => surface(
    context,
    IconButton(
      tooltip: label,
      onPressed: action,
      icon: Icon(icon),
      constraints: const BoxConstraints.tightFor(width: 48, height: 48),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final hasPages = manga && pageCount > 0;
    final sliderMax = hasPages ? (pageCount - 1).toDouble() : 1.0;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
          child: Row(
            children: [
              chapterButton(
                context,
                'Chương trước',
                CupertinoIcons.backward_end_fill,
                onPrevious,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: surface(
                  context,
                  SizedBox(
                    height: 48,
                    child: Row(
                      children: [
                        const SizedBox(width: 12),
                        Text(
                          hasPages
                              ? '${page + 1}'
                              : '${(position * 100).round()}%',
                          style: const TextStyle(fontSize: 13),
                        ),
                        Expanded(
                          child: CupertinoSlider(
                            key: const ValueKey('reader-position-slider'),
                            value: hasPages
                                ? page.toDouble().clamp(0, sliderMax)
                                : position.clamp(0, 1),
                            max: sliderMax > 0 ? sliderMax : 1,
                            divisions: hasPages && pageCount > 1
                                ? pageCount - 1
                                : null,
                            onChanged: hasPages && pageCount < 2
                                ? null
                                : onSeek,
                          ),
                        ),
                        Text(
                          hasPages ? '$pageCount' : '100%',
                          style: const TextStyle(fontSize: 13),
                        ),
                        const SizedBox(width: 12),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              chapterButton(
                context,
                'Chương tiếp theo',
                CupertinoIcons.forward_end_fill,
                onNext,
              ),
            ],
          ),
        ),
        surface(
          context,
          SafeArea(
            top: false,
            child: SizedBox(
              height: 64,
              child: Row(
                children: [
                  Expanded(
                    child: IconButton(
                      tooltip: 'Đánh dấu trang',
                      onPressed: onBookmark,
                      icon: const Icon(CupertinoIcons.bookmark),
                    ),
                  ),
                  Expanded(
                    child: IconButton(
                      tooltip: 'Tải chương',
                      onPressed: onDownload,
                      icon: const Icon(CupertinoIcons.arrow_down_to_line),
                    ),
                  ),
                  Expanded(
                    child: IconButton(
                      tooltip: 'Hướng màn hình',
                      onPressed: onOrientation,
                      icon: const Icon(CupertinoIcons.rotate_right),
                    ),
                  ),
                  Expanded(
                    child: IconButton(
                      tooltip: 'Giao diện đọc',
                      onPressed: onSettings,
                      icon: const Icon(CupertinoIcons.gear_alt_fill),
                    ),
                  ),
                ],
              ),
            ),
          ),
          radius: 12,
        ),
      ],
    );
  }
}

class ReaderPageBadge extends StatelessWidget {
  const ReaderPageBadge({super.key, required this.page, required this.total});
  final int page, total;

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: Center(
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Theme.of(context).scaffoldBackgroundColor
              .withValues(alpha: .7),
          borderRadius: BorderRadius.circular(18),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Text(
            '${page + 1} / $total',
            style: const TextStyle(fontSize: 12),
          ),
        ),
      ),
    ),
  );
}

class ReaderAutoScrollStatus extends StatelessWidget {
  const ReaderAutoScrollStatus({
    super.key,
    required this.paused,
    required this.mode,
    required this.speed,
    required this.pageSeconds,
    required this.onToggle,
  });
  final bool paused;
  final String mode;
  final double speed, pageSeconds;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) => Center(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 340),
      child: Material(
        color: Theme.of(context).scaffoldBackgroundColor.withValues(alpha: .9),
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.only(left: 12, right: 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: Text(
                  paused
                      ? 'Đã tạm dừng tự cuộn'
                      : mode == 'page'
                      ? 'Tự cuộn · ${pageSeconds.round()} giây/trang'
                      : 'Tự cuộn · ${speed.round()} px/giây',
                  style: const TextStyle(fontSize: 12),
                ),
              ),
              IconButton(
                key: const ValueKey('reader-auto-scroll-toggle'),
                tooltip: paused ? 'Tiếp tục tự cuộn' : 'Tạm dừng tự cuộn',
                onPressed: onToggle,
                icon: Icon(
                  paused ? CupertinoIcons.play_fill : CupertinoIcons.pause_fill,
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
