import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/widgets/feedback.dart';
import '../../library/domain/library_book.dart';
import '../../library/presentation/activity_book_cover.dart';
import '../../library/presentation/library_view_model.dart';
import '../../settings/settings_controller.dart';
import 'download_actions.dart';
import 'download_queue_controller.dart';
import 'download_queue_bulk_actions.dart';
import 'download_settings_screen.dart';

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
        'Chọn tải chương ở trang chi tiết hoặc Cập nhật. Kéo biểu tượng bên phải để đổi thứ tự truyện. Menu từng chương cho phép tạm dừng, tiếp tục, tải ngay hoặc hủy. Tạm dừng một chương ngừng tải các trang tiếp theo và giữ ảnh đã tải; yêu cầu đang gửi có thể hoàn tất. Tiếp tục một chương khi hàng đợi đang dừng sẽ giữ các chương chờ khác ở trạng thái tạm dừng; nút Tiếp tục mở lại toàn bộ. Tạm dừng toàn bộ ngừng bắt đầu mục mới. Hàng đợi được giữ khi mở lại app. Mục Gần đây đã tải xuống có thể xuất truyện tranh CBZ.',
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
    final bookIds = queue.tasks.map((task) => task.bookId).toSet().toList();
    final runnable = queue.tasks.any(
      (task) =>
          task.status == DownloadJobStatus.pending ||
          task.status == DownloadJobStatus.failed ||
          task.status == DownloadJobStatus.paused,
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
          if (queue.tasks.isNotEmpty)
            IconButton(
              tooltip: 'Hủy tất cả tải xuống',
              onPressed: () => perform(context, controller.cancelAll),
              icon: const Icon(CupertinoIcons.clear_circled),
            ),
          IconButton(
            tooltip: 'Thiết lập tải xuống',
            icon: const Icon(CupertinoIcons.gear_solid),
            onPressed: () => Navigator.of(context).push(
              CupertinoPageRoute<void>(
                builder: (_) => const DownloadSettingsScreen(),
              ),
            ),
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
                                perform(context, controller.resumeAll);
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
          if (queue.tasks.isNotEmpty) const DownloadQueueBulkActions(),
          if (queue.storageError != null)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                queue.storageError!,
                style: TextStyle(color: colors.error, fontSize: 13),
              ),
            ),
          if (queue.pauseReason != null)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                queue.pauseReason!,
                style: const TextStyle(fontSize: 13),
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
                : ReorderableListView.builder(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    buildDefaultDragHandles: false,
                    itemCount: bookIds.length,
                    onReorderItem: (oldIndex, newIndex) {
                      final reordered = [...bookIds];
                      final moved = reordered.removeAt(oldIndex);
                      reordered.insert(newIndex, moved);
                      final destination = newIndex + 1 < reordered.length
                          ? reordered[newIndex + 1]
                          : null;
                      perform(
                        context,
                        () => controller.moveBookBefore(moved, destination),
                      );
                    },
                    itemBuilder: (context, index) {
                      final bookId = bookIds[index];
                      final tasks = queue.tasks
                          .where((task) => task.bookId == bookId)
                          .toList();
                      final found = books.where((book) => book.id == bookId);
                      final book = found.isEmpty ? null : found.first;
                      final revision = ref
                          .read(libraryRepositoryProvider)
                          .replacementRevision;
                      final active = tasks
                          .where(
                            (task) => task.status == DownloadJobStatus.active,
                          )
                          .length;
                      final failed = tasks
                          .where(
                            (task) => task.status == DownloadJobStatus.failed,
                          )
                          .length;
                      final paused = tasks
                          .where(
                            (task) => task.status == DownloadJobStatus.paused,
                          )
                          .length;
                      return ExpansionTile(
                        key: ValueKey('download-book-$bookId'),
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
                          '${tasks.length} chương · $active đang tải${paused == 0 ? '' : ' · $paused tạm dừng'}${failed == 0 ? '' : ' · $failed lỗi'}',
                          style: const TextStyle(fontSize: 13),
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            PopupMenuButton<String>(
                              tooltip: 'Tùy chọn tải ${book?.title ?? bookId}',
                              onSelected: (action) {
                                switch (action) {
                                  case 'now':
                                    perform(
                                      context,
                                      () => controller.downloadBookNow(bookId),
                                    );
                                  case 'cancel':
                                    perform(
                                      context,
                                      () => controller.cancelBook(bookId),
                                    );
                                  case 'next':
                                    enqueueNextDownloads(
                                      context,
                                      ref,
                                      book!,
                                      expectedRevision: revision,
                                    );
                                }
                              },
                              itemBuilder: (_) => [
                                const PopupMenuItem(
                                  value: 'now',
                                  child: Text('Tải ngay'),
                                ),
                                if (book != null && book.engine != 'local')
                                  const PopupMenuItem(
                                    value: 'next',
                                    child: Text('Tải chương tiếp theo'),
                                  ),
                                const PopupMenuItem(
                                  value: 'cancel',
                                  child: Text('Hủy tải truyện'),
                                ),
                              ],
                            ),
                            ReorderableDragStartListener(
                              key: ValueKey('download-drag-$bookId'),
                              index: index,
                              child: const SizedBox(
                                width: 32,
                                height: 48,
                                child: ColoredBox(
                                  color: Colors.transparent,
                                  child: Icon(
                                    CupertinoIcons.line_horizontal_3,
                                    size: 20,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                        children: [
                          for (final task in tasks)
                            ListTile(
                              title: Text(
                                book?.chapters
                                        .where(
                                          (chapter) =>
                                              chapter.id == task.chapterId,
                                        )
                                        .firstOrNull
                                        ?.title ??
                                    'Chương không còn trong mục lục',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 14),
                              ),
                              subtitle: Text(switch (task.status) {
                                DownloadJobStatus.pending => 'Chờ tải',
                                DownloadJobStatus.active => 'Đang tải',
                                DownloadJobStatus.paused => 'Đã tạm dừng',
                                DownloadJobStatus.failed =>
                                  'Lỗi: ${userFacingError(task.error ?? 'Lỗi tải nguồn')}',
                              }),
                              leading: task.status == DownloadJobStatus.active
                                  ? const CupertinoActivityIndicator()
                                  : Icon(
                                      task.status == DownloadJobStatus.failed
                                          ? CupertinoIcons
                                                .exclamationmark_circle
                                          : task.status ==
                                                DownloadJobStatus.paused
                                          ? CupertinoIcons.pause_circle
                                          : CupertinoIcons.clock,
                                      size: 20,
                                    ),
                              trailing: PopupMenuButton<String>(
                                tooltip: 'Tùy chọn chương ${task.chapterId}',
                                onSelected: (action) => perform(
                                  context,
                                  () => switch (action) {
                                    'pause' => controller.pauseJob(
                                      task.identity,
                                    ),
                                    'resume' => controller.resumeJob(
                                      task.identity,
                                    ),
                                    'now' => controller.downloadNow(
                                      task.identity,
                                    ),
                                    _ => controller.cancel(task.identity),
                                  },
                                ),
                                itemBuilder: (_) => [
                                  if (task.status == DownloadJobStatus.active ||
                                      task.status == DownloadJobStatus.pending)
                                    const PopupMenuItem(
                                      value: 'pause',
                                      child: Text('Tạm dừng chương'),
                                    ),
                                  if (task.status == DownloadJobStatus.paused)
                                    const PopupMenuItem(
                                      value: 'resume',
                                      child: Text('Tiếp tục chương'),
                                    ),
                                  const PopupMenuItem(
                                    value: 'now',
                                    child: Text('Tải chương ngay'),
                                  ),
                                  const PopupMenuItem(
                                    value: 'cancel',
                                    child: Text('Hủy tải chương'),
                                  ),
                                ],
                              ),
                            ),
                        ],
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
          error: (error, _) => Center(child: Text(userFacingError(error))),
          data: (books) {
            final revision = ref
                .read(libraryRepositoryProvider)
                .replacementRevision;
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
                  trailing:
                      entry.book.engine == 'local' && entry.book.kind != 'manga'
                      ? const Icon(
                          CupertinoIcons.checkmark_circle_fill,
                          size: 22,
                        )
                      : PopupMenuButton<String>(
                          tooltip: entry.book.kind == 'manga'
                              ? 'Xuất CBZ ${entry.book.chapters[entry.index].title}'
                              : 'Tùy chọn ${entry.book.chapters[entry.index].title}',
                          onSelected: (action) {
                            if (action == 'delete' || action == 'delete-book') {
                              deleteDownloadedChapters(
                                context,
                                ref,
                                entry.book,
                                action == 'delete'
                                    ? [entry.book.chapters[entry.index].id]
                                    : entry.book.chapters
                                          .where(
                                            (chapter) => chapter.downloaded,
                                          )
                                          .map((chapter) => chapter.id),
                                expectedRevision: revision,
                              );
                            } else {
                              saveDownloadedCbz(
                                context,
                                ref,
                                entry.book,
                                expectedRevision: revision,
                                chapterIds: action == 'chapter'
                                    ? [entry.book.chapters[entry.index].id]
                                    : null,
                              );
                            }
                          },
                          itemBuilder: (_) => [
                            if (entry.book.kind == 'manga') ...const [
                              PopupMenuItem(
                                value: 'chapter',
                                child: Text('Xuất chương này thành CBZ'),
                              ),
                              PopupMenuItem(
                                value: 'book',
                                child: Text('Xuất các chương đã tải thành CBZ'),
                              ),
                            ],
                            if (entry.book.engine != 'local') ...const [
                              PopupMenuItem(
                                value: 'delete',
                                child: Text('Xóa nội dung tải của chương'),
                              ),
                              PopupMenuItem(
                                value: 'delete-book',
                                child: Text('Xóa các chương đã tải của truyện'),
                              ),
                            ],
                          ],
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
