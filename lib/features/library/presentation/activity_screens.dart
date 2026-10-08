import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/widgets/feedback.dart';
import '../domain/library_book.dart';
import 'library_view_model.dart';

class UpdatesScreen extends ConsumerStatefulWidget {
  const UpdatesScreen({super.key});
  @override
  ConsumerState<UpdatesScreen> createState() => _UpdatesScreenState();
}

class _UpdatesScreenState extends ConsumerState<UpdatesScreen> {
  bool updating = false;

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

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Cập nhật'),
      actions: [
        if (updating)
          const Padding(
            padding: EdgeInsets.all(12),
            child: SizedBox(
              width: 20,
              height: 20,
              child: CupertinoActivityIndicator(),
            ),
          )
        else
          IconButton(
            tooltip: 'Kiểm tra chương mới',
            onPressed: update,
            icon: const Icon(CupertinoIcons.arrow_clockwise, size: 21),
          ),
      ],
    ),
    body: ref
        .watch(libraryProvider)
        .when(
          loading: () => const Center(child: CupertinoActivityIndicator()),
          error: (error, _) => _ActivityEmpty(
            icon: CupertinoIcons.exclamationmark_circle,
            title: 'Không mở được cập nhật',
            description: '$error',
            action: TextButton(
              onPressed: () => ref.invalidate(libraryProvider),
              child: const Text('Thử lại'),
            ),
          ),
          data: (books) {
            final entries = <_UnreadChapter>[];
            final online =
                books
                    .where((book) => book.engine != 'local' && !book.completed)
                    .toList()
                  ..sort(
                    (a, b) => (b.lastRead ?? DateTime(1970)).compareTo(
                      a.lastRead ?? DateTime(1970),
                    ),
                  );
            for (final book in online) {
              final first = (book.progress * book.chapters.length)
                  .floor()
                  .clamp(0, book.chapters.length);
              for (final chapter in book.chapters.skip(first)) {
                entries.add(_UnreadChapter(book, chapter));
              }
            }
            if (entries.isEmpty) {
              return _ActivityEmpty(
                icon: CupertinoIcons.arrow_down_circle,
                title: 'Chưa có chương chờ đọc',
                description: 'Kiểm tra chương mới của truyện đã thêm từ nguồn. Sách nhập từ file nằm trong Thư viện.',
                action: TextButton.icon(
                  onPressed: updating ? null : update,
                  icon: const Icon(CupertinoIcons.arrow_clockwise),
                  label: const Text('Kiểm tra cập nhật'),
                ),
              );
            }
            return RefreshIndicator(
              onRefresh: update,
              child: ListView.separated(
                physics: const AlwaysScrollableScrollPhysics(),
                itemCount: entries.length + 1,
                separatorBuilder: (_, _) =>
                    const Divider(height: 1, indent: 68),
                itemBuilder: (context, index) {
                  if (index == 0) {
                    return Padding(
                      padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
                      child: Text(
                        '${entries.length} chương chưa đọc · ${online.length} truyện đang theo dõi',
                        style: const TextStyle(
                          fontSize: 13,
                          color: Colors.grey,
                        ),
                      ),
                    );
                  }
                  final entry = entries[index - 1];
                  return ListTile(
                    minTileHeight: 64,
                    minVerticalPadding: 4,
                    horizontalTitleGap: 12,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 2,
                    ),
                    leading: _ActivityCover(entry.book),
                    title: Text(
                      entry.book.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    subtitle: Text(
                      entry.chapter.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        color: CupertinoColors.secondaryLabel.resolveFrom(
                          context,
                        ),
                      ),
                    ),
                    trailing: Icon(
                      entry.chapter.downloaded
                          ? CupertinoIcons.arrow_down_circle_fill
                          : CupertinoIcons.chevron_right,
                      size: 15,
                      color: entry.chapter.downloaded
                          ? Theme.of(context).colorScheme.primary
                          : Colors.grey,
                    ),
                    onTap: () => context.push(
                      '/read/${entry.book.id}?chapter=${entry.chapter.index}',
                    ),
                    onLongPress: () => context.push('/book/${entry.book.id}'),
                  );
                },
              ),
            );
          },
        ),
  );
}

class _UnreadChapter {
  const _UnreadChapter(this.book, this.chapter);
  final LibraryBook book;
  final BookChapter chapter;
}

class HistoryScreen extends ConsumerStatefulWidget {
  const HistoryScreen({super.key});
  @override
  ConsumerState<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends ConsumerState<HistoryScreen> {
  bool clearing = false;

  Future<void> clear(List<LibraryBook> books) async {
    if (clearing || books.isEmpty) return;
    final confirmed = await showCupertinoDialog<bool>(
      context: context,
      builder: (ctx) => CupertinoAlertDialog(
        title: const Text('Xóa lịch sử đọc?'),
        content: const Text(
          'Xóa danh sách đọc gần đây. Vị trí đang đọc, dấu trang và nội dung đã tải vẫn được giữ.',
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
    final today = DateTime(now.year, now.month, now.day);
    final local = date.toLocal();
    final day = DateTime(local.year, local.month, local.day);
    if (day == today) return 'Hôm nay';
    if (day == today.subtract(const Duration(days: 1))) return 'Hôm qua';
    return '${local.day.toString().padLeft(2, '0')}/${local.month.toString().padLeft(2, '0')}/${local.year}';
  }

  @override
  Widget build(BuildContext context) {
    final library = ref.watch(libraryProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Lịch sử'),
        actions: [
          IconButton(
            tooltip: 'Xóa lịch sử đọc',
            onPressed: clearing
                ? null
                : () => clear(
                    library.value
                            ?.where((book) => book.lastRead != null)
                            .toList() ??
                        [],
                  ),
            icon: const Icon(CupertinoIcons.trash, size: 21),
          ),
        ],
      ),
      body: library.when(
        loading: () => const Center(child: CupertinoActivityIndicator()),
        error: (error, _) => _ActivityEmpty(
          icon: CupertinoIcons.exclamationmark_circle,
          title: 'Không mở được lịch sử',
          description: '$error',
          action: TextButton(
            onPressed: () => ref.invalidate(libraryProvider),
            child: const Text('Thử lại'),
          ),
        ),
        data: (books) {
          final history = books.where((book) => book.lastRead != null).toList()
            ..sort((a, b) => b.lastRead!.compareTo(a.lastRead!));
          if (history.isEmpty) {
            return const _ActivityEmpty(
              icon: CupertinoIcons.clock,
              title: 'Những trang vừa đọc',
              description: 'Manga, truyện chữ và ebook bạn mở sẽ xuất hiện ở đây để đọc tiếp.',
            );
          }
          return RefreshIndicator(
            onRefresh: ref.read(libraryProvider.notifier).refresh,
            child: ListView.builder(
              physics: const AlwaysScrollableScrollPhysics(),
              itemCount: history.length,
              itemBuilder: (context, index) {
                final book = history[index];
                final label = dateLabel(book.lastRead!);
                final chapter = book.chapters.isEmpty
                    ? null
                    : book.chapters[book.currentChapter.clamp(
                        0,
                        book.chapters.length - 1,
                      )];
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (index == 0 ||
                        dateLabel(history[index - 1].lastRead!) != label)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 14, 16, 7),
                        child: Text(
                          label,
                          style: const TextStyle(
                            fontWeight: FontWeight.w600,
                            color: Colors.grey,
                            fontSize: 13,
                          ),
                        ),
                      ),
                    ListTile(
                      minTileHeight: 64,
                      minVerticalPadding: 4,
                      horizontalTitleGap: 12,
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 2,
                      ),
                      leading: _ActivityCover(book),
                      title: Text(
                        book.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      subtitle: Text(
                        '${chapter?.title ?? 'Chưa có chương'} · ${(book.progress * 100).round()}%',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          color: CupertinoColors.secondaryLabel.resolveFrom(
                            context,
                          ),
                        ),
                      ),
                      trailing: IconButton(
                        tooltip: 'Chi tiết sách',
                        icon: const Icon(CupertinoIcons.ellipsis, size: 21),
                        onPressed: () => context.push('/book/${book.id}'),
                      ),
                      onTap: () => context.push(
                        chapter == null
                            ? '/book/${book.id}'
                            : '/read/${book.id}?chapter=${chapter.index}',
                      ),
                    ),
                    const Divider(height: 1, indent: 68),
                  ],
                );
              },
            ),
          );
        },
      ),
    );
  }
}

class _ActivityCover extends StatelessWidget {
  const _ActivityCover(this.book);
  final LibraryBook book;
  @override
  Widget build(BuildContext context) {
    final fallback = ColoredBox(
      color: Theme.of(context).colorScheme.primaryContainer,
      child: Center(
        child: Icon(
          book.kind == 'manga' ? CupertinoIcons.book : CupertinoIcons.doc_text,
          color: Theme.of(context).colorScheme.primary,
          size: 20,
        ),
      ),
    );
    return SizedBox(
      width: 38,
      height: 52,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(3),
        child: book.cover.startsWith('data:image/')
            ? Image.memory(
                UriData.parse(book.cover).contentAsBytes(),
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => fallback,
              )
            : book.cover.isNotEmpty
            ? Image.network(
                book.cover,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => fallback,
              )
            : fallback,
      ),
    );
  }
}

class _ActivityEmpty extends StatelessWidget {
  const _ActivityEmpty({
    required this.icon,
    required this.title,
    required this.description,
    this.action,
  });
  final IconData icon;
  final String title, description;
  final Widget? action;

  @override
  Widget build(BuildContext context) => Center(
    child: SingleChildScrollView(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 340),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                icon,
                size: 36,
                color: CupertinoColors.secondaryLabel.resolveFrom(context),
              ),
              const SizedBox(height: 12),
              Text(
                title,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                description,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 13,
                  height: 1.4,
                  color: CupertinoColors.secondaryLabel.resolveFrom(context),
                ),
              ),
              if (action != null) ...[const SizedBox(height: 8), action!],
            ],
          ),
        ),
      ),
    ),
  );
}
