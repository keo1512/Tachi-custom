import 'package:flutter/material.dart';

import '../domain/library_update_result.dart';
import '../../../core/format/error_messages.dart';

class LibraryUpdateReportPanel extends StatelessWidget {
  const LibraryUpdateReportPanel({
    super.key,
    this.report,
    this.progress,
    required this.busy,
    required this.onRetry,
  });
  final LibraryUpdateResult? report;
  final LibraryUpdateProgress? progress;
  final bool busy;
  final VoidCallback onRetry;
  @override
  Widget build(BuildContext context) {
    final value = progress;
    if (!busy && report == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (busy && value != null) ...[
            LinearProgressIndicator(value: value.fraction),
            Text(
              '${value.processedBooks}/${value.requestedBooks} truyện · ${value.addedChapters} chương mới · ${value.failedBooks} lỗi',
              key: const ValueKey('update-progress'),
            ),
            if (value.currentTitle.isNotEmpty)
              Text(
                value.currentTitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
          ] else if (report != null) ...[
            Text(
              'Đã kiểm tra ${report!.checkedBooks} truyện · ${report!.addedChapters} chương mới · ${report!.skippedBooks} bỏ qua · ${report!.failures.length} lỗi',
            ),
            Wrap(
              spacing: 8,
              children: [
                TextButton(
                  onPressed: () => _details(context),
                  child: const Text('Chi tiết kết quả'),
                ),
                if (report!.hasErrors)
                  TextButton(
                    onPressed: busy ? null : onRetry,
                    child: Text(
                      'Thử lại ${report!.failures.length} truyện lỗi',
                    ),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _details(BuildContext context) => showModalBottomSheet<void>(
    context: context,
    useSafeArea: true,
    isScrollControlled: true,
    builder: (ctx) => SizedBox(
      height: MediaQuery.sizeOf(ctx).height * .75,
      child: Column(
        children: [
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text('Kết quả cập nhật'),
          ),
          Expanded(
            child: ListView(
              children: [
                if (report!.failures.isEmpty && report!.skipped.isEmpty)
                  const ListTile(
                    title: Text('Tất cả truyện đã được kiểm tra thành công.'),
                  ),
                for (final group in report!.failuresBySource.entries) ...[
                  ListTile(
                    title: Text(
                      'Lỗi nguồn: ${group.value.first.sourceName.isNotEmpty
                          ? group.value.first.sourceName
                          : group.key.isEmpty
                          ? 'Chưa xác định'
                          : group.key}',
                    ),
                  ),
                  for (final failure in group.value)
                    ListTile(
                      title: Text(failure.title),
                      subtitle: Text(userFacingError(failure.message)),
                    ),
                ],
                if (report!.skipped.isNotEmpty)
                  const ListTile(title: Text('Truyện bỏ qua')),
                for (final skipped in report!.skipped)
                  ListTile(
                    title: Text(skipped.title),
                    subtitle: Text(skipped.reason),
                  ),
              ],
            ),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Đóng'),
          ),
        ],
      ),
    ),
  );
}
