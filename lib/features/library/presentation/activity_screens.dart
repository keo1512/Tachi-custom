import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/widgets/feedback.dart';
import '../../downloads/presentation/download_queue_controller.dart';
import '../../settings/settings_controller.dart';
import '../../sources/presentation/source_cover_image.dart';
import '../domain/library_book.dart';
import '../domain/library_reading.dart';
import '../domain/library_update_events.dart';
import 'activity_book_cover.dart';
import 'library_view_model.dart';
import '../application/library_update_report.dart';
import '../domain/library_update_result.dart';
import 'library_update_report_panel.dart';
import 'library_source_label.dart';
import 'library_locations.dart';

class UpdatesScreen extends ConsumerStatefulWidget {
  const UpdatesScreen({super.key});
  @override
  ConsumerState<UpdatesScreen> createState() => _UpdatesScreenState();
}

class _UpdatesScreenState extends ConsumerState<UpdatesScreen> {
  bool updating = false;
  bool unreadOnly = false, includeExistingUnread = false;
  String? category;
  LibraryUpdateProgress? progress;
  bool selecting = false, selectionBusy = false;
  final selected = <String>{};
  int? selectionRevision;
  String? selectionAnchor;

  String entryKey(LibraryUpdateEntry entry) =>
      jsonEncode([entry.book.id, entry.chapter.id]);

  void finishSelection() => setState(() {
    selecting = false;
    selected.clear();
    selectionRevision = null;
    selectionAnchor = null;
  });

  void select(LibraryUpdateEntry entry) {
    if (selectionBusy) return;
    setState(() {
      if (!selecting) {
        selecting = true;
        selectionRevision = ref
            .read(libraryRepositoryProvider)
            .replacementRevision;
      }
      final identity = entryKey(entry);
      if (!selected.add(identity)) selected.remove(identity);
      selectionAnchor = identity;
    });
  }

  void selectRange(LibraryUpdateEntry entry, List<LibraryUpdateEntry> visible) {
    if (!selecting || selectionAnchor == null) {
      select(entry);
      return;
    }
    if (selectionBusy) return;
    final first = visible.indexWhere(
      (item) => entryKey(item) == selectionAnchor,
    );
    final last = visible.indexWhere(
      (item) => entryKey(item) == entryKey(entry),
    );
    if (first < 0 || last < 0) return;
    setState(() {
      final start = first < last ? first : last;
      final end = first < last ? last : first;
      selected.addAll(visible.sublist(start, end + 1).map(entryKey));
    });
  }

  Future<void> selectionAction(
    String action,
    List<LibraryUpdateEntry> visible,
  ) async {
    if (selectionBusy || selectionRevision == null) return;
    if (action == 'all' || action == 'invert') {
      setState(() {
        final values = visible.map(entryKey).toSet();
        if (action == 'invert') values.removeAll(selected);
        selected
          ..clear()
          ..addAll(values);
      });
      return;
    }
    final chosen = visible
        .where((entry) => selected.contains(entryKey(entry)))
        .toList();
    if (chosen.isEmpty) return;
    final revision = selectionRevision!;
    setState(() => selectionBusy = true);
    final done = await perform(context, () async {
      if (action == 'download') {
        final queue = ref.read(downloadQueueProvider.notifier);
        for (final entry in chosen.where(
          (entry) => !entry.chapter.downloaded,
        )) {
          await queue.enqueue(entry.book.id, [
            entry.chapter.id,
          ], expectedRevision: revision);
        }
        await queue.start();
      } else {
        final groups = <String, List<String>>{};
        for (final entry in chosen) {
          groups.putIfAbsent(entry.book.id, () => []).add(entry.chapter.id);
        }
        await ref
            .read(libraryProvider.notifier)
            .markManyChaptersRead(
              groups,
              action == 'read',
              expectedRevision: revision,
            );
      }
      return true;
    });
    if (!mounted) return;
    setState(() => selectionBusy = false);
    if (done == true) finishSelection();
  }

  Future<void> retryFailed() async {
    final previous = ref.read(libraryUpdateReportProvider);
    if (updating || previous == null || !previous.hasErrors) return;
    setState(() {
      updating = true;
      progress = null;
    });
    await perform(
      context,
      () => ref
          .read(libraryProvider.notifier)
          .retryFailedUpdates(
            previous,
            onProgress: (value) {
              if (mounted) setState(() => progress = value);
            },
          ),
    );
    if (mounted) setState(() => updating = false);
  }

  Future<void> update() async {
    if (updating) return;
    setState(() {
      updating = true;
      progress = null;
    });
    final repository = ref.read(libraryRepositoryProvider);
    final revision = repository.replacementRevision;
    final ids = updateCategoryBookIds(
      ref.read(libraryProvider).value ?? [],
      category,
    );
    final result = await perform(
      context,
      () => ref
          .read(libraryProvider.notifier)
          .updateBooks(
            ids,
            expectedRevision: revision,
            onProgress: (value) {
              if (mounted) setState(() => progress = value);
            },
          ),
    );
    if (!mounted) return;
    setState(() => updating = false);
    if (result != null) {
      message(
        context,
        result.hasErrors
            ? 'Đã kiểm tra ${result.checkedBooks} truyện, có ${result.addedChapters} chương mới; ${result.failures.length} truyện lỗi. ${result.failures.first.title}: ${result.failures.first.message}'
            : result.addedChapters == 0
            ? 'Không có chương mới'
            : 'Đã tìm thấy ${result.addedChapters} chương mới',
      );
    }
  }

  List<LibraryUpdateEntry> entries(List<LibraryBook> books) =>
      libraryUpdateEntries(
        books,
        category: category,
        unreadOnly: unreadOnly,
        includeExistingUnread: includeExistingUnread,
      );

  Future<void> download(
    Iterable<LibraryUpdateEntry> chapters,
  ) => perform(context, () async {
    final revision = ref.read(libraryRepositoryProvider).replacementRevision;
    final queue = ref.read(downloadQueueProvider.notifier);
    for (final entry in chapters.where((entry) => !entry.chapter.downloaded)) {
      await queue.enqueue(entry.book.id, [
        entry.chapter.id,
      ], expectedRevision: revision);
    }
    await queue.start();
  });

  Future<void> chapterActions(LibraryUpdateEntry entry) async {
    final revision = ref.read(libraryRepositoryProvider).replacementRevision;
    final read = chapterIsRead(entry.book, entry.index);
    final action = await showCupertinoModalPopup<String>(
      context: context,
      builder: (ctx) => CupertinoActionSheet(
        title: Text(entry.chapter.title),
        actions: [
          CupertinoActionSheetAction(
            onPressed: () => Navigator.pop(ctx, 'read'),
            child: Text(read ? 'Đánh dấu chưa đọc' : 'Đánh dấu đã đọc'),
          ),
          CupertinoActionSheetAction(
            onPressed: () => Navigator.pop(ctx, 'book'),
            child: const Text('Mở truyện'),
          ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('Hủy'),
        ),
      ),
    );
    if (!mounted || action == null) return;
    if (action == 'book') {
      context.push(libraryBookLocation(entry.book.id));
      return;
    }
    await perform(
      context,
      () => ref
          .read(libraryProvider.notifier)
          .markChaptersRead(
            entry.book.id,
            [entry.chapter.id],
            !read,
            expectedRevision: revision,
          ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final library = ref.watch(libraryProvider);
    final queue = ref.watch(downloadQueueProvider);
    final report = ref.watch(libraryUpdateReportProvider);
    final currentProgress = ref.watch(libraryUpdateProgressProvider);
    final visible = entries(library.value ?? []);
    if (selecting &&
        selectionRevision !=
            ref.read(libraryRepositoryProvider).replacementRevision) {
      selecting = false;
      selected.clear();
      selectionRevision = null;
      selectionAnchor = null;
    }
    selected.retainAll(visible.map(entryKey));
    return Scaffold(
      appBar: AppBar(
        title: Text(selecting ? '${selected.length} đã chọn' : 'Cập nhật'),
        leading: selecting
            ? IconButton(
                tooltip: 'Hủy chọn chương cập nhật',
                icon: const Icon(CupertinoIcons.xmark),
                onPressed: selectionBusy ? null : finishSelection,
              )
            : IconButton(
                tooltip: 'Sao lưu và dữ liệu',
                icon: const Icon(Icons.cloud_done_outlined),
                onPressed: () => context.go('/more'),
              ),
        actions: [
          if (selecting)
            PopupMenuButton<String>(
              tooltip: 'Chọn nhiều chương cập nhật',
              enabled: !selectionBusy,
              onSelected: (action) => selectionAction(action, visible),
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'all', child: Text('Chọn tất cả')),
                PopupMenuItem(value: 'invert', child: Text('Đảo lựa chọn')),
              ],
            )
          else ...[
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
                  } else if (action == 'unread-only') {
                    setState(() => unreadOnly = !unreadOnly);
                  } else if (action == 'existing-unread') {
                    setState(
                      () => includeExistingUnread = !includeExistingUnread,
                    );
                  } else if (action.startsWith('category:')) {
                    setState(
                      () => category = action.substring('category:'.length),
                    );
                  } else if (action == 'select') {
                    setState(() {
                      selecting = true;
                      selectionRevision = ref
                          .read(libraryRepositoryProvider)
                          .replacementRevision;
                    });
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
                    child: Text('Tải các chương đang hiển thị'),
                  ),
                  const PopupMenuItem(
                    value: 'select',
                    child: Text('Chọn nhiều chương'),
                  ),
                  CheckedPopupMenuItem(
                    value: 'unread-only',
                    checked: unreadOnly,
                    child: const Text('Chỉ chương chưa đọc'),
                  ),
                  CheckedPopupMenuItem(
                    value: 'existing-unread',
                    checked: includeExistingUnread,
                    child: const Text('Xem cả chương chưa đọc đã có'),
                  ),
                  const PopupMenuDivider(),
                  CheckedPopupMenuItem(
                    value: 'all-categories',
                    checked: category == null,
                    child: const Text('Tất cả kệ'),
                  ),
                  for (final name
                      in ((library.value ?? [])
                          .expand((book) => book.categories)
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
        ],
      ),
      body: Column(
        children: [
          if (selecting)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              child: Wrap(
                alignment: WrapAlignment.center,
                spacing: 8,
                children: [
                  TextButton.icon(
                    onPressed: selected.isEmpty || selectionBusy
                        ? null
                        : () => selectionAction('download', visible),
                    icon: const Icon(
                      CupertinoIcons.arrow_down_circle,
                      size: 18,
                    ),
                    label: const Text('Tải đã chọn'),
                  ),
                  TextButton.icon(
                    onPressed: selected.isEmpty || selectionBusy
                        ? null
                        : () => selectionAction('read', visible),
                    icon: const Icon(CupertinoIcons.checkmark_circle, size: 18),
                    label: const Text('Đánh dấu đã đọc'),
                  ),
                  TextButton(
                    onPressed: selected.isEmpty || selectionBusy
                        ? null
                        : () => selectionAction('unread', visible),
                    child: const Text('Đánh dấu chưa đọc'),
                  ),
                ],
              ),
            ),
          LibraryUpdateReportPanel(
            report: report,
            progress: currentProgress ?? progress,
            busy: updating || currentProgress != null,
            onRetry: retryFailed,
          ),
          Expanded(
            child: library.when(
              loading: () => const Center(child: CupertinoActivityIndicator()),
              error: (error, _) => _ActivityEmpty(
                title: 'Không mở được cập nhật',
                description: userFacingError(error),
                action: TextButton(
                  onPressed: () => ref.invalidate(libraryProvider),
                  child: const Text('Thử lại'),
                ),
              ),
              data: (books) {
                final unread = entries(books);
                if (unread.isEmpty) {
                  return RefreshIndicator(
                    onRefresh: update,
                    child: CustomScrollView(
                      physics: const AlwaysScrollableScrollPhysics(),
                      slivers: [
                        SliverFillRemaining(
                          hasScrollBody: false,
                          child: _ActivityEmpty(
                            title: includeExistingUnread
                                ? 'Chưa có chương chờ đọc'
                                : 'Chưa phát hiện chương mới',
                            description: 'Kéo xuống hoặc kiểm tra chương mới của truyện trong kệ đã chọn. Chương có sẵn từ bản sao lưu không được gán ngày phát hiện giả.',
                            action: TextButton(
                              onPressed: updating ? null : update,
                              child: const Text('Kiểm tra cập nhật'),
                            ),
                          ),
                        ),
                      ],
                    ),
                  );
                }
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
                            '${includeExistingUnread ? 'Chương chưa đọc' : 'Chương mới'}${category == null ? '' : ' · $category'}',
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
                            if (selecting)
                              SizedBox(
                                width: 32,
                                child: Checkbox(
                                  value: selected.contains(entryKey(entry)),
                                  semanticLabel:
                                      'Chọn ${entry.book.title} ${entry.chapter.title}',
                                  onChanged: selectionBusy
                                      ? null
                                      : (_) => select(entry),
                                ),
                              ),
                            ActivityBookCover(
                              entry.book,
                              coverImage: libraryCoverImage(ref, entry.book),
                            ),
                            const SizedBox(width: 16),
                            Expanded(
                              child: InkWell(
                                onTap: () => selecting
                                    ? select(entry)
                                    : context.push(
                                        libraryReaderLocation(
                                          entry.book,
                                          entry.index,
                                        ),
                                      ),
                                onLongPress: () => selecting
                                    ? selectRange(entry, unread)
                                    : select(entry),
                                onDoubleTap: selecting
                                    ? null
                                    : () => chapterActions(entry),
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 3,
                                  ),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        entry.book.title,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          fontSize: 15,
                                          fontWeight: FontWeight.w400,
                                        ),
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        entry.chapter.title,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(fontSize: 13),
                                      ),
                                      Text(
                                        chapterIsRead(entry.book, entry.index)
                                            ? 'Đã đọc'
                                            : 'Chưa đọc',
                                        style: TextStyle(
                                          fontSize: 11,
                                          color: Theme.of(context)
                                              .colorScheme
                                              .onSurfaceVariant,
                                        ),
                                      ),
                                      const SizedBox(height: 3),
                                      Text(
                                        '${discoveredDateLabel(entry.chapter.discoveredAt)} · ${resolvedLibrarySourceLabel(ref, entry.book)}',
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          fontSize: 11,
                                          color: Theme.of(context)
                                              .colorScheme
                                              .onSurface
                                              .withValues(alpha: .6),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 12),
                            if (!selecting)
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
                                            ? CupertinoIcons
                                                  .checkmark_circle_fill
                                            : CupertinoIcons.arrow_down_circle,
                                        size: 23,
                                        color: Theme.of(context)
                                            .colorScheme
                                            .onSurface,
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
          ),
        ],
      ),
    );
  }
}

class HistoryScreen extends ConsumerStatefulWidget {
  const HistoryScreen({super.key});
  @override
  ConsumerState<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends ConsumerState<HistoryScreen> {
  final search = TextEditingController();
  bool clearing = false, searching = false;
  bool selecting = false;
  final selected = <String>{};
  int? selectionRevision;

  void select(LibraryBook book) {
    if (clearing) return;
    setState(() {
      if (!selecting) {
        selecting = true;
        selectionRevision = ref
            .read(libraryRepositoryProvider)
            .replacementRevision;
      }
      if (!selected.add(book.id)) selected.remove(book.id);
    });
  }

  void finishSelection() => setState(() {
    selecting = false;
    selected.clear();
    selectionRevision = null;
  });

  List<LibraryBook> visibleHistory(List<LibraryBook> books) {
    final query = search.text.trim().toLowerCase();
    return books
        .where(
          (book) =>
              book.lastRead != null &&
              (query.isEmpty ||
                  book.title.toLowerCase().contains(query) ||
                  book.chapters.any(
                    (chapter) => chapter.title.toLowerCase().contains(query),
                  )),
        )
        .toList()
      ..sort((a, b) => b.lastRead!.compareTo(a.lastRead!));
  }

  @override
  void dispose() {
    search.dispose();
    super.dispose();
  }

  Future<void> clear(List<LibraryBook> books, {int? expectedRevision}) async {
    if (clearing || books.isEmpty) return;
    final revision =
        expectedRevision ??
        ref.read(libraryRepositoryProvider).replacementRevision;
    final confirmed = await showCupertinoDialog<bool>(
      context: context,
      builder: (ctx) => CupertinoAlertDialog(
        title: const Text('Xóa lịch sử đọc?'),
        content: Text(
          'Xóa lịch sử của ${books.length} truyện. '
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
    final done = await perform(context, () async {
      await ref
          .read(libraryProvider.notifier)
          .clearHistory(
            books.map((book) => book.id),
            expectedRevision: revision,
          );
      return true;
    });
    if (mounted) setState(() => clearing = false);
    if (mounted && done == true && selecting) finishSelection();
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
    if (selecting &&
        selectionRevision !=
            ref.read(libraryRepositoryProvider).replacementRevision) {
      selecting = false;
      selectionRevision = null;
      selected.clear();
    }
    final books = library.asData?.value ?? <LibraryBook>[];
    if (library.hasValue) {
      selected.retainWhere(
        (id) => books.any((book) => book.id == id && book.lastRead != null),
      );
    }
    final incognito = ref.watch(
      settingsProvider.select((settings) => settings.incognitoMode),
    );
    return Scaffold(
      appBar: AppBar(
        title: Text(selecting ? '${selected.length} đã chọn' : 'Lịch sử'),
        leadingWidth: selecting ? 48 : 96,
        leading: selecting
            ? IconButton(
                tooltip: 'Hủy chọn lịch sử',
                icon: const Icon(CupertinoIcons.xmark),
                onPressed: clearing ? null : finishSelection,
              )
            : Row(
                children: [
                  IconButton(
                    tooltip: 'Sao lưu và dữ liệu',
                    icon: const Icon(Icons.cloud_done_outlined),
                    onPressed: () => context.go('/more'),
                  ),
                  IconButton(
                    tooltip: incognito
                        ? 'Tắt chế độ ẩn danh'
                        : 'Bật chế độ ẩn danh',
                    icon: Icon(
                      CupertinoIcons.eyeglasses,
                      color: incognito
                          ? Theme.of(context).colorScheme.primary
                          : null,
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
          if (selecting) ...[
            IconButton(
              tooltip: 'Chọn tất cả lịch sử đang hiển thị',
              icon: const Icon(CupertinoIcons.checkmark_circle),
              onPressed: clearing
                  ? null
                  : () => setState(() {
                      selected.addAll(
                        visibleHistory(books).map((book) => book.id),
                      );
                    }),
            ),
            IconButton(
              tooltip: 'Xóa lịch sử đã chọn',
              icon: const Icon(CupertinoIcons.trash),
              onPressed: clearing || selected.isEmpty
                  ? null
                  : () => clear(
                      books
                          .where((book) => selected.contains(book.id))
                          .toList(),
                      expectedRevision: selectionRevision,
                    ),
            ),
          ] else ...[
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
        ],
      ),
      body: library.when(
        loading: () => const Center(child: CupertinoActivityIndicator()),
        error: (error, _) => _ActivityEmpty(
          title: 'Không mở được lịch sử',
          description: userFacingError(error),
          action: TextButton(
            onPressed: () => ref.invalidate(libraryProvider),
            child: const Text('Thử lại'),
          ),
        ),
        data: (books) {
          final query = search.text.trim().toLowerCase();
          final history = visibleHistory(books);
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
                        action: TextButton(
                          onPressed: () {
                            if (query.isEmpty) {
                              context.go('/');
                            } else {
                              setState(search.clear);
                            }
                          },
                          child: Text(
                            query.isEmpty ? 'Mở thư viện' : 'Xóa tìm kiếm',
                          ),
                        ),
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
                                  if (selecting)
                                    SizedBox(
                                      width: 32,
                                      child: Checkbox(
                                        value: selected.contains(book.id),
                                        semanticLabel:
                                            'Chọn lịch sử ${book.title}',
                                        onChanged: clearing
                                            ? null
                                            : (_) => select(book),
                                      ),
                                    ),
                                  InkWell(
                                    onLongPress: () => select(book),
                                    onTap: () => selecting
                                        ? select(book)
                                        : context.push(
                                            libraryBookLocation(book.id),
                                          ),
                                    child: ActivityBookCover(
                                      book,
                                      coverImage: libraryCoverImage(ref, book),
                                      width: 82,
                                      height: 120,
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: InkWell(
                                      onLongPress: () => select(book),
                                      onTap: () => selecting
                                          ? select(book)
                                          : context.push(
                                              chapterIndex == null
                                                  ? libraryBookLocation(book.id)
                                                  : libraryReaderLocation(
                                                      book,
                                                      chapterIndex,
                                                    ),
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
                                          if (!selecting)
                                            Align(
                                              alignment: Alignment.centerLeft,
                                              child: TextButton.icon(
                                                onPressed: chapterIndex == null
                                                    ? () => context.push(
                                                        libraryBookLocation(
                                                          book.id,
                                                        ),
                                                      )
                                                    : () => context.push(
                                                        libraryReaderLocation(
                                                          book,
                                                          chapterIndex,
                                                        ),
                                                      ),
                                                icon: const Icon(
                                                  CupertinoIcons.play_fill,
                                                  size: 14,
                                                ),
                                                label: Text(
                                                  chapterIndex == null
                                                      ? 'Mở truyện'
                                                      : 'Tiếp tục đọc',
                                                ),
                                              ),
                                            ),
                                        ],
                                      ),
                                    ),
                                  ),
                                  if (!selecting)
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
                                          : () => clear([book]),
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
