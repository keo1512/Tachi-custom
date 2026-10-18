import 'package:flutter/material.dart';

class ReaderChapterBoundary extends StatelessWidget {
  const ReaderChapterBoundary({
    super.key,
    required this.complete,
    required this.finalChapter,
    required this.nextTitle,
    required this.onNext,
  });
  final bool complete, finalChapter;
  final String? nextTitle;
  final VoidCallback? onNext;
  @override
  Widget build(BuildContext context) => Padding(
    key: const ValueKey('reader-chapter-boundary'),
    // Keep the explicit action reachable above the reader's bottom controls.
    padding: const EdgeInsets.fromLTRB(20, 24, 20, 144),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Divider(),
        Text(
          complete ? 'Hết chương' : 'Cuối danh sách trang',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 8),
        Text(
          !complete
              ? 'Còn trang chưa tải hoặc chưa hiển thị thành công.'
              : finalChapter
              ? 'Đây là chương cuối trong danh sách hiện tại.'
              : nextTitle == null
              ? 'Không còn chương phù hợp với thiết lập bỏ qua.'
              : 'Chương tiếp theo: $nextTitle',
          textAlign: TextAlign.center,
        ),
        if (nextTitle != null) ...[
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: onNext,
            icon: const Icon(Icons.arrow_downward),
            label: const Text('Đọc chương tiếp'),
          ),
        ],
      ],
    ),
  );
}
