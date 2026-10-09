import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/widgets/feedback.dart';
import '../../downloads/presentation/download_queue_controller.dart';
import '../../settings/settings_controller.dart';
import '../domain/library_book.dart';
import '../domain/library_reading.dart';
import 'activity_book_cover.dart';
import 'library_view_model.dart';

class UpdatesScreen extends ConsumerStatefulWidget {
  const UpdatesScreen({super.key});
  @override
  ConsumerState<UpdatesScreen> createState() => _UpdatesScreenState();
}

class _UpdatesScreenState extends ConsumerState<UpdatesScreen> {
  bool updating = false;
  String? category;

  Future<void> update() async {
    if (updating) return;
    setState(() => updating = true);
    final count = await perform(
      context,
      () => ref.read(libraryProvider.notifier).updateAll(),
    );
    if (!mounted) return;
    setState(() => updating = false);
    if (count != null) {
      message(
        context,
        count == 0 ? 'Không có chương mới' : 'Đã tìm thấy $count chương mới',
      );
    }
  }

  List<_UnreadChapter> entries(List<LibraryBook> books) {
    final result = <_UnreadChapter>[];
    for (final book in books.where(
      (book) =>
          book.engine != 'local' &&
          !book.completed &&
          (category == null || book.collection == category),
    )) {
      for (var index = book.chapters.length - 1; index >= 0; index--) {
        if (!chapterIsRead(book, index)) {
          result.add(_UnreadChapter(book, book.chapters[index], index));
        }
      }
    }
    return result;
  }

  Future<void> download(Iterable<_UnreadChapter> chapters) =>
      perform(context, () async {
        final queue = ref.read(downloadQueueProvider.notifier);
        for (final entry in chapters.where(
          (entry) => !entry.chapter.downloaded,
        )) {
          await queue.enqueue(entry.book.id, [entry.chapter.id]);
        }
        await queue.start();
      });

  @override
  Widget build(BuildContext context) {
    final library = ref.watch(libraryProvider);
    final queue = ref.watch(downloadQueueProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Cập nhật'),
        leading: IconButton(
          tooltip: 'Sao lưu và dữ liệu',
          icon: const Icon(Icons.cloud_done_outlined),
          onPressed: () => context.go('/more'),
        ),
        actions: [
          IconButton(
            tooltip: 'Thiết lập',
            icon: const Icon(CupertinoIcons.gear_solid),
            onPressed: () => context.go('/more'),
          ),
          if (updating)
            const Padding(
              padding: EdgeInsets.all(12),
              child: CupertinoActivityIndicator(),
            )
          else
            PopupMenuButton<String>(
              tooltip: 'Tùy chọn cập nhật',
              icon: const Icon(Icons.more_vert),
              onSelected: (action) {
                if (action == 'update') {
                  update();
                } else if (action == 'all-categories') {
                  setState(() => category = null);
                } else if (action.startsWith('category:')) {
                  setState(
                    () => category = action.substring('category:'.length),
                  );
                } else {
                  download(entries(library.value ?? []));
                }
              },
              itemBuilder: (_) => [
                const PopupMenuItem(
                  value: 'update',
                  child: Text('Kiểm tra chương mới'),
                ),
                const PopupMenuItem(
                  value: 'download',
                  child: Text('Tải chương chưa đọc'),
                ),
                const PopupMenuDivider(),
                CheckedPopupMenuItem(
                  value: 'all-categories',
                  checked: category == null,
                  child: const Text('Tất cả kệ'),
                ),
                for (final name
                    in ((library.value ?? [])
                        .map((book) => book.collection)
                        .toSet()
                        .toList()
                      ..sort()))
                  CheckedPopupMenuItem(
                    value: 'category:$name',
                    checked: category == name,
                    child: Text(name),
                  ),
              ],
            ),
        ],
      ),
      body: library.when(
        loading: () => const Center(child: CupertinoActivityIndicator()),
        error: (error, _) => _ActivityEmpty(
          title: 'Không mở được cập nhật',
          description: '$error',
          action: TextButton(
            onPressed: () => ref.invalidate(libraryProvider),
            child: const Text('Thử lại'),
          ),
        ),
        data: (books) {
          final unread = entries(books);
          if (unread.isEmpty) {
            return _ActivityEmpty(
              title: 'Chưa có chương chờ đọc',
              description: 'Kiểm tra chương mới của truyện đã thêm từ nguồn.',
              action: TextButton(
                onPressed: updating ? null : update,
                child: const Text('Kiểm tra cập nhật'),
              ),
            );
          }
          // The model does not store chapter update dates. Keep this heading honest
          // instead of showing invented relative dates from the reference screenshot.
          return RefreshIndicator(
            onRefresh: update,
            child: ListView.builder(
              padding: const EdgeInsets.only(bottom: 16),
              physics: const AlwaysScrollableScrollPhysics(),
              itemCount: unread.length + 1,
              itemBuilder: (context, row) {
                if (row == 0) {
                  return Padding(
                    padding: const EdgeInsets.fromLTRB(16, 14, 16, 18),
                    child: Text(
                      category == null
                          ? 'Chương chưa đọc'
                          : 'Chương chưa đọc · $category',
                      style: const TextStyle(fontSize: 15),
                    ),
                  );
                }
                final entry = unread[row - 1];
                final active = queue.tasks.any(
                  (task) =>
                      task.bookId == entry.book.id &&
                      task.chapterId == entry.chapter.id &&
                      task.status == DownloadJobStatus.active,
                );
                return Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 6,
                  ),
                  child: Row(
                    children: [
                      ActivityBookCover(entry.book),
                      const SizedBox(width: 16),
                      Expanded(
                        child: InkWell(
                          onTap: () => context.push(
                            '/read/${entry.book.id}?chapter=${entry.index}',
                          ),
                          onLongPress: () =>
                              context.push('/book/${entry.book.id}'),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 3),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  entry.book.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontSize: 15,
                                    fontWeight: FontWeight.w400,
                                    color: Color(0xFF99999B),
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  entry.chapter.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontSize: 13,
                                    color: Color(0xFF99999B),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      IconButton(
                        tooltip: entry.chapter.downloaded
                            ? 'Đã tải chương'
                            : 'Tải chương ${entry.chapter.title}',
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(
                          minWidth: 32,
                          minHeight: 44,
                        ),
                        icon: active
                            ? const CupertinoActivityIndicator()
                            : Icon(
                                entry.chapter.downloaded
                                    ? CupertinoIcons.checkmark_circle_fill
                                    : CupertinoIcons.arrow_down_circle,
                                size: 23,
                                color: Theme.of(context).colorScheme.onSurface,
                              ),
                        onPressed: entry.chapter.downloaded || active
                            ? null
                            : () => download([entry]),
                      ),
                    ],
                  ),
                );
              },
            ),
          );
        },
      ),
    );
  }
}

class _UnreadChapter {
  const _UnreadChapter(this.book, this.chapter, this.index);
  final LibraryBook book;
  final BookChapter chapter;
  final int index;
}

class HistoryScreen extends ConsumerStatefulWidget {
  const HistoryScreen({super.key});
  @override
  ConsumerState<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends ConsumerState<HistoryScreen> {
  final search = TextEditingController();
  bool clearing = false, searching = false;

  @override
  void dispose() {
    search.dispose();
    super.dispose();
  }

  Future<void> clear(List<LibraryBook> books) async {
    if (clearing || books.isEmpty) return;
    final confirmed = await showCupertinoDialog<bool>(
      context: context,
      builder: (ctx) => CupertinoAlertDialog(
        title: const Text('Xóa lịch sử đọc?'),
        content: const Text(
          'Vị trí đang đọc, dấu trang và nội dung đã tải vẫn được giữ.',
        ),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Hủy'),
          ),
          CupertinoDialogAction(
            isDestructiveAction: true,
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Xóa lịch sử'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => clearing = true);
    await perform(
      context,
      () => ref
          .read(libraryProvider.notifier)
          .clearHistory(books.map((book) => book.id)),
    );
    if (mounted) setState(() => clearing = false);
  }

  String dateLabel(DateTime date) {
    final now = DateTime.now();
    final local = date.toLocal();
    final days = DateTime(
      now.year,
      now.month,
      now.day,
    ).difference(DateTime(local.year, local.month, local.day)).inDays;
    if (days == 0) return 'Hôm nay';
    if (days == 1) return 'Hôm qua';
    if (days > 1 && days < 8) return '$days ngày trước';
    return '${local.day.toString().padLeft(2, '0')}/${local.month.toString().padLeft(2, '0')}/${local.year}';
  }

  @override
  Widget build(BuildContext context) {
    final library = ref.watch(libraryProvider);
    final incognito = ref.watch(
      settingsProvider.select((settings) => settings.incognitoMode),
    );
    return Scaffold(
      appBar: AppBar(
        title: const Text('Lịch sử'),
        leadingWidth: 96,
        leading: Row(
          children: [
            IconButton(
              tooltip: 'Sao lưu và dữ liệu',
              icon: const Icon(Icons.cloud_done_outlined),
              onPressed: () => context.go('/more'),
            ),
            IconButton(
              tooltip: incognito ? 'Tắt chế độ ẩn danh' : 'Bật chế độ ẩn danh',
              icon: Icon(
                CupertinoIcons.eyeglasses,
                color: incognito ? Theme.of(context).colorScheme.primary : null,
              ),
              onPressed: () => perform(
                context,
                () => ref
                    .read(settingsProvider.notifier)
                    .update(incognitoMode: !incognito),
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Tìm lịch sử',
            icon: const Icon(CupertinoIcons.search),
            onPressed: () => setState(() => searching = !searching),
          ),
          IconButton(
            tooltip: 'Xóa lịch sử đọc',
            icon: const Icon(CupertinoIcons.trash),
            onPressed: clearing
                ? null
                : () => clear(
                    library.value
                            ?.where((book) => book.lastRead != null)
                            .toList() ??
                        [],
                  ),
          ),
        ],
      ),
      body: library.when(
        loading: () => const Center(child: CupertinoActivityIndicator()),
        error: (error, _) => _ActivityEmpty(
          title: 'Không mở được lịch sử',
          description: '$error',
        ),
        data: (books) {
          final query = search.text.trim().toLowerCase();
          final history =
              books
                  .where(
                    (book) =>
                        book.lastRead != null &&
                        (query.isEmpty ||
                            book.title.toLowerCase().contains(query) ||
                            book.chapters.any(
                              (chapter) =>
                                  chapter.title.toLowerCase().contains(query),
                            )),
                  )
                  .toList()
                ..sort((a, b) => b.lastRead!.compareTo(a.lastRead!));
          return Column(
            children: [
              if (incognito)
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 0, 16, 12),
                  child: Text(
                    'Ẩn danh đang bật. Phiên đọc mở mới không lưu tiến độ, lịch sử hoặc thời gian đọc. Dấu trang bạn chủ động thêm vẫn được lưu.',
                    style: TextStyle(fontSize: 13),
                  ),
                ),
              if (searching)
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                  child: CupertinoSearchTextField(
                    controller: search,
                    placeholder: 'Tìm lịch sử',
                    onChanged: (_) => setState(() {}),
                  ),
                ),
              Expanded(
                child: history.isEmpty
                    ? _ActivityEmpty(
                        title: query.isEmpty
                            ? 'Không có lịch sử'
                            : 'Không tìm thấy lịch sử',
                        description: query.isEmpty
                            ? 'Sách bạn đọc sẽ xuất hiện ở đây.'
                            : 'Thử tìm theo tên sách hoặc tên chương.',
                      )
                    : RefreshIndicator(
                        onRefresh: ref.read(libraryProvider.notifier).refresh,
                        child: ListView.builder(
                          physics: const AlwaysScrollableScrollPhysics(),
                          padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
                          itemCount: history.length,
                          itemBuilder: (context, index) {
                            final book = history[index];
                            final chapterIndex = book.chapters.isEmpty
                                ? null
                                : book.currentChapter.clamp(
                                    0,
                                    book.chapters.length - 1,
                                  );
                            final chapter = chapterIndex == null
                                ? null
                                : book.chapters[chapterIndex];
                            return Padding(
                              padding: const EdgeInsets.only(bottom: 16),
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  InkWell(
                                    onTap: () =>
                                        context.push('/book/${book.id}'),
                                    child: ActivityBookCover(
                                      book,
                                      width: 82,
                                      height: 120,
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: InkWell(
                                      onTap: () => context.push(
                                        chapterIndex == null
                                            ? '/book/${book.id}'
                                            : '/read/${book.id}?chapter=$chapterIndex',
                                      ),
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            book.title,
                                            maxLines: 2,
                                            overflow: TextOverflow.ellipsis,
                                            style: const TextStyle(
                                              fontSize: 15,
                                              fontWeight: FontWeight.w600,
                                            ),
                                          ),
                                          const SizedBox(height: 5),
                                          Text(
                                            chapter?.title ?? 'Chưa có chương',
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: const TextStyle(
                                              fontSize: 13,
                                            ),
                                          ),
                                          const SizedBox(height: 5),
                                          Row(
                                            children: [
                                              const Icon(
                                                CupertinoIcons.clock,
                                                size: 15,
                                              ),
                                              const SizedBox(width: 5),
                                              Expanded(
                                                child: Text(
                                                  dateLabel(book.lastRead!),
                                                  style: const TextStyle(
                                                    fontSize: 13,
                                                  ),
                                                ),
                                              ),
                                            ],
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                  IconButton(
                                    tooltip: 'Xóa lịch sử ${book.title}',
                                    icon: const Icon(
                                      CupertinoIcons.trash,
                                      size: 22,
                                    ),
                                    constraints: const BoxConstraints(
                                      minWidth: 32,
                                      minHeight: 44,
                                    ),
                                    padding: EdgeInsets.zero,
                                    onPressed: clearing
                                        ? null
                                        : () => perform(
                                            context,
                                            () => ref
                                                .read(libraryProvider.notifier)
                                                .clearHistory([book.id]),
                                          ),
                                  ),
                                ],
                              ),
                            );
                          },
                        ),
                      ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _ActivityEmpty extends StatelessWidget {
  const _ActivityEmpty({
    required this.title,
    required this.description,
    this.action,
  });
  final String title, description;
  final Widget? action;
  @override
  Widget build(BuildContext context) => Center(
    child: SingleChildScrollView(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 17),
            ),
            const SizedBox(height: 10),
            Text(
              description,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 13),
            ),
            if (action != null) ...[const SizedBox(height: 8), action!],
          ],
        ),
      ),
    ),
  );
}
