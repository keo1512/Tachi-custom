import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/widgets/feedback.dart';
import '../../library/domain/library_book.dart';
import '../../library/presentation/activity_book_cover.dart';
import '../../library/presentation/library_view_model.dart';
import '../../settings/settings_controller.dart';
import 'download_queue_controller.dart';

class DownloadsScreen extends ConsumerWidget {
  const DownloadsScreen({super.key});

  Future<void> concurrency(BuildContext context, WidgetRef ref) async {
    final value = await showCupertinoModalPopup<int>(
      context: context,
      builder: (ctx) => CupertinoActionSheet(
        title: const Text('Tải xuống đồng thời'),
        actions: [
          for (var count = 1; count <= 4; count++)
            CupertinoActionSheetAction(
              onPressed: () => Navigator.pop(ctx, count),
              child: Text('$count'),
            ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('Hủy'),
        ),
      ),
    );
    if (value != null && context.mounted) {
      await perform(
        context,
        () => ref
            .read(settingsProvider.notifier)
            .update(downloadConcurrency: value),
      );
    }
  }

  void help(BuildContext context) => showCupertinoDialog<void>(
    context: context,
    builder: (ctx) => CupertinoAlertDialog(
      title: const Text('Tải xuống'),
      content: const Text(
        'Chọn tải chương ở trang chi tiết hoặc Cập nhật. Tiếp tục bắt đầu các mục đang chờ; tạm dừng để ngừng bắt đầu mục mới. Các mục đang tải sẽ hoàn tất. Hàng đợi được giữ khi mở lại app. Tải từ nguồn cần kết nối runtime của nguồn đó.',
      ),
      actions: [
        CupertinoDialogAction(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('Đóng'),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final queue = ref.watch(downloadQueueProvider);
    final count = ref.watch(
      settingsProvider.select((settings) => settings.downloadConcurrency),
    );
    final books = ref.watch(libraryProvider).value ?? <LibraryBook>[];
    final runnable = queue.tasks.any(
      (task) =>
          task.status == DownloadJobStatus.pending ||
          task.status == DownloadJobStatus.failed,
    );
    final controller = ref.read(downloadQueueProvider.notifier);
    final colors = Theme.of(context).colorScheme;
    final buttonStyle = FilledButton.styleFrom(
      backgroundColor: const Color(0xFFAFC4FF),
      foregroundColor: Colors.black,
      disabledBackgroundColor: const Color(0xFFAFC4FF),
      disabledForegroundColor: Colors.black,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      minimumSize: const Size(0, 40),
      shape: const StadiumBorder(),
      textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w400),
    );
    return Scaffold(
      appBar: AppBar(
        title: const Text('Tải xuống'),
        actions: [
          IconButton(
            tooltip: 'Thiết lập tải xuống',
            icon: const Icon(CupertinoIcons.gear_solid),
            onPressed: () => concurrency(context, ref),
          ),
          IconButton(
            tooltip: 'Trợ giúp tải xuống',
            icon: const Icon(CupertinoIcons.question_circle_fill),
            onPressed: () => help(context),
          ),
        ],
      ),
      body: Column(
        children: [
          ListTile(
            minTileHeight: 60,
            leading: const Icon(CupertinoIcons.arrow_down_to_line, size: 24),
            title: const Text(
              'Gần đây đã tải xuống',
              style: TextStyle(fontSize: 15),
            ),
            trailing: Icon(
              CupertinoIcons.chevron_right,
              size: 20,
              color: colors.onSurfaceVariant,
            ),
            onTap: () => Navigator.of(context).push(
              CupertinoPageRoute<void>(
                builder: (_) => const RecentDownloadsScreen(),
              ),
            ),
          ),
          const Divider(height: 1, thickness: 1),
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 12, 10, 8),
            child: IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      style: buttonStyle,
                      onPressed:
                          queue.storageError != null ||
                              (!queue.running && !runnable)
                          ? null
                          : () {
                              if (queue.running) {
                                controller.pause();
                              } else {
                                perform(context, controller.retry);
                              }
                            },
                      icon: Icon(
                        queue.running
                            ? CupertinoIcons.pause_fill
                            : CupertinoIcons.play_fill,
                        size: 16,
                      ),
                      label: Text(queue.running ? 'Tạm dừng' : 'Tiếp tục'),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: FilledButton.icon(
                      style: buttonStyle,
                      onPressed: () => concurrency(context, ref),
                      icon: const Icon(CupertinoIcons.bolt_fill, size: 17),
                      label: Text('Tải xuống đồng thời:\n$count'),
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (queue.storageError != null)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                queue.storageError!,
                style: TextStyle(color: colors.error, fontSize: 13),
              ),
            ),
          Expanded(
            child: queue.tasks.isEmpty
                ? const Center(
                    child: SingleChildScrollView(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text('Σ(ಠ_ಠ)', style: TextStyle(fontSize: 40)),
                          SizedBox(height: 24),
                          Text(
                            'Không có tải xuống',
                            style: TextStyle(fontSize: 15),
                          ),
                        ],
                      ),
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    itemCount: queue.tasks.length,
                    itemBuilder: (context, index) {
                      final task = queue.tasks[index];
                      final found = books.where(
                        (book) => book.id == task.bookId,
                      );
                      final book = found.isEmpty ? null : found.first;
                      final chapters = book?.chapters.where(
                        (chapter) => chapter.id == task.chapterId,
                      );
                      final title = chapters == null || chapters.isEmpty
                          ? 'Chương không còn trong mục lục'
                          : chapters.first.title;
                      final status = switch (task.status) {
                        DownloadJobStatus.pending => 'Chờ tải',
                        DownloadJobStatus.active => 'Đang tải',
                        DownloadJobStatus.failed => 'Lỗi: ${task.error}',
                      };
                      return ListTile(
                        leading: book == null
                            ? const Icon(CupertinoIcons.book)
                            : ActivityBookCover(book),
                        title: Text(
                          book?.title ?? 'Sách không còn trong thư viện',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 15),
                        ),
                        subtitle: Text(
                          '$title\n$status',
                          style: const TextStyle(fontSize: 13),
                        ),
                        isThreeLine: true,
                        trailing: task.status == DownloadJobStatus.active
                            ? const CupertinoActivityIndicator()
                            : task.status == DownloadJobStatus.failed
                            ? IconButton(
                                tooltip: 'Thử tải lại',
                                onPressed: () =>
                                    perform(context, controller.retry),
                                icon: const Icon(
                                  CupertinoIcons.arrow_clockwise,
                                ),
                              )
                            : const Icon(CupertinoIcons.clock, size: 20),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class RecentDownloadsScreen extends ConsumerWidget {
  const RecentDownloadsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) => Scaffold(
    appBar: AppBar(title: const Text('Gần đây đã tải xuống')),
    body: ref
        .watch(libraryProvider)
        .when(
          loading: () => const Center(child: CupertinoActivityIndicator()),
          error: (error, _) => Center(child: Text('$error')),
          data: (books) {
            final entries = <({LibraryBook book, int index})>[
              for (final book in books)
                for (var index = 0; index < book.chapters.length; index++)
                  if (book.chapters[index].downloaded)
                    (book: book, index: index),
            ];
            if (entries.isEmpty) {
              return const Center(child: Text('Chưa có chương đã tải'));
            }
            // No download timestamp exists in LibraryBook. List available offline
            // chapters without implying a fabricated most-recent ordering.
            return ListView.builder(
              padding: const EdgeInsets.symmetric(vertical: 12),
              itemCount: entries.length,
              itemBuilder: (context, index) {
                final entry = entries[index];
                return ListTile(
                  leading: ActivityBookCover(entry.book),
                  title: Text(
                    entry.book.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 15),
                  ),
                  subtitle: Text(
                    entry.book.chapters[entry.index].title,
                    style: const TextStyle(fontSize: 13),
                  ),
                  trailing: const Icon(
                    CupertinoIcons.checkmark_circle_fill,
                    size: 22,
                  ),
                  onTap: () => context.push(
                    '/read/${entry.book.id}?chapter=${entry.index}',
                  ),
                );
              },
            );
          },
        ),
  );
}
