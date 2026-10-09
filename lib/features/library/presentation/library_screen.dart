import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/widgets/book_cover.dart';
import '../../../core/widgets/feedback.dart';
import '../../downloads/presentation/download_queue_controller.dart';
import '../domain/library_book.dart';
import '../domain/library_grouping.dart';
import '../domain/library_search.dart';
import '../../settings/settings_controller.dart';
import '../../settings/presentation/connection_dialog.dart';
import 'library_filter_sheet.dart';
import 'library_group_dialog.dart';
import 'library_group_tabs.dart';
import 'library_grouping_controller.dart';
import 'library_view_model.dart';

class LibraryScreen extends ConsumerStatefulWidget {
  const LibraryScreen({super.key});
  @override
  ConsumerState<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends ConsumerState<LibraryScreen> {
  String query = '';
  LibraryFilter filter = const LibraryFilter();
  bool searching = false, importing = false;
  LibraryGrouping get grouping => ref.read(libraryGroupingProvider);
  String? selectedGroup;
  bool selecting = false, groupingBusy = false;
  bool downloadingBusy = false;
  bool get selectionBusy => groupingBusy || downloadingBusy;
  final selectedIds = <String>{};

  Future<void> changeGrouping(LibraryGrouping mode) async {
    await ref.read(libraryGroupingProvider.notifier).setGrouping(mode);
    if (!mounted) return;
    setState(() {
      selectedGroup = null;
      filter = filter.copyWith(category: 'Tất cả');
    });
  }

  void toggleSelection(String id) => setState(() {
    selecting = true;
    if (!selectedIds.remove(id)) selectedIds.add(id);
  });

  List<LibraryBook> visibleBooks(
    List<LibraryBook> books,
    List<LibraryGroup> groups,
  ) {
    final groupedIds = selectedGroup == null
        ? null
        : groups
              .where((group) => group.key == selectedGroup)
              .expand((group) => group.bookIds)
              .toSet();
    final search = LibrarySearch(query);
    return books
        .where(
          (book) =>
              (groupedIds == null || groupedIds.contains(book.id)) &&
              (filter.kind == 'all' || book.kind == filter.kind) &&
              search.matches(book) &&
              switch (filter.category) {
                'Đang đọc' => book.lastRead != null && !book.completed,
                'Yêu thích' => book.favorite,
                'Hoàn thành' => book.completed,
                'Tất cả' => true,
                _ => book.collection == filter.category,
              },
        )
        .toList()
      ..sort((a, b) {
        final result = switch (filter.order) {
          LibraryOrder.recent => (b.lastRead ?? DateTime(1970)).compareTo(
            a.lastRead ?? DateTime(1970),
          ),
          LibraryOrder.title => a.title.toLowerCase().compareTo(
            b.title.toLowerCase(),
          ),
          LibraryOrder.unread =>
            (b.chapters.length - readChapterCount(b)).compareTo(
              a.chapters.length - readChapterCount(a),
            ),
        };
        return filter.reverse ? -result : result;
      });
  }

  Future<void> groupSelected(List<LibraryBook> books, Set<String> ids) async {
    final edit = await showLibraryGroupDialog(
      context,
      books: books,
      selectedIds: ids,
      grouping: grouping,
    );
    if (edit == null || !mounted) return;
    setState(() => groupingBusy = true);
    final count = await perform(
      context,
      () => ref
          .read(libraryProvider.notifier)
          .groupBooks(
            ids,
            collection: edit.grouping == LibraryGrouping.collection
                ? edit.value
                : null,
            author: edit.grouping == LibraryGrouping.author ? edit.value : null,
            series: edit.grouping == LibraryGrouping.series ? edit.value : null,
          ),
    );
    if (!mounted) return;
    if (count != null) {
      await perform(context, () => changeGrouping(edit.grouping));
      if (!mounted) return;
    }
    setState(() {
      groupingBusy = false;
      if (count != null) {
        selecting = false;
        selectedIds.clear();
        selectedGroup = null;
        filter = filter.copyWith(category: 'Tất cả');
      }
    });
    if (count != null) message(context, 'Đã cập nhật nhóm cho $count sách');
  }

  Future<void> downloadSelected(
    List<LibraryBook> books,
    Set<String> ids,
  ) async {
    final selected = books.where((book) => ids.contains(book.id)).toList();
    final revision = ref.read(libraryRepositoryProvider).replacementRevision;
    final unreadOnly = await showCupertinoModalPopup<bool>(
      context: context,
      builder: (ctx) => CupertinoActionSheet(
        title: Text('Tải ${selected.length} truyện'),
        actions: [
          CupertinoActionSheetAction(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Tất cả chương chưa tải'),
          ),
          CupertinoActionSheetAction(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Chương chưa đọc chưa tải'),
          ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('Hủy'),
        ),
      ),
    );
    if (unreadOnly == null || !mounted) return;
    setState(() => downloadingBusy = true);
    final count = await perform(context, () async {
      final queue = ref.read(downloadQueueProvider.notifier);
      final count = await queue.enqueueBooks(
        selected,
        unreadOnly: unreadOnly,
        expectedRevision: revision,
      );
      await queue.start();
      return count;
    });
    if (!mounted) return;
    setState(() => downloadingBusy = false);
    if (count != null) {
      message(
        context,
        count == 0
            ? 'Không có chương mới cần thêm vào hàng đợi'
            : 'Đã thêm $count chương vào hàng đợi tải',
      );
    }
  }

  Future<void> import() async {
    setState(() => importing = true);
    final count = await perform(
      context,
      () => ref.read(libraryProvider.notifier).importFiles(),
    );
    if (!mounted) return;
    setState(() => importing = false);
    if (count != null && count > 0) message(context, 'Đã nhập $count file');
  }

  void showFilters(List<LibraryBook> books) {
    final collections =
        books
            .map((b) => b.collection)
            .where((c) => c.isNotEmpty)
            .toSet()
            .toList()
          ..sort();
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      constraints: const BoxConstraints(maxWidth: 600),
      builder: (_) => LibraryFilterSheet(
        value: filter,
        collections: collections,
        onChanged: (value) {
          if (mounted) {
            setState(() {
              filter = value;
              selectedGroup = null;
            });
          }
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final library = ref.watch(libraryProvider);
    final settings = ref.watch(settingsProvider);
    final grouping = ref.watch(libraryGroupingProvider);
    final books = library.value ?? <LibraryBook>[];
    final groups = libraryGroups(books, grouping);
    final visible = visibleBooks(books, groups);
    final currentIds = selectedIds.intersection(
      books.map((book) => book.id).toSet(),
    );
    final allVisibleSelected =
        visible.isNotEmpty &&
        visible.every((book) => currentIds.contains(book.id));
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          tooltip: selecting ? 'Hủy chọn sách' : 'Kết nối nguồn',
          icon: Icon(
            selecting ? CupertinoIcons.xmark : Icons.cloud_done_outlined,
          ),
          onPressed: selectionBusy
              ? null
              : selecting
              ? () => setState(() {
                  selecting = false;
                  selectedIds.clear();
                })
              : () => showConnections(context, ref),
        ),
        title: selecting
            ? Text(
                'Đã chọn ${currentIds.length}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              )
            : searching
            ? TextField(
                autofocus: true,
                onChanged: (v) => setState(() => query = v),
                decoration: const InputDecoration(
                  hintText: 'Tìm trong thư viện',
                  isDense: true,
                  contentPadding: EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 8,
                  ),
                ),
              )
            : const Text('Thư viện'),
        actions: [
          if (selecting) ...[
            IconButton(
              tooltip: allVisibleSelected
                  ? 'Bỏ chọn sách hiển thị'
                  : 'Chọn tất cả sách hiển thị',
              icon: const Icon(CupertinoIcons.checkmark_square),
              onPressed: selectionBusy
                  ? null
                  : () => setState(() {
                      final ids = visible.map((book) => book.id);
                      if (allVisibleSelected) {
                        selectedIds.removeAll(ids);
                      } else {
                        selectedIds.addAll(ids);
                      }
                    }),
            ),
            IconButton(
              tooltip: 'Tải truyện đã chọn',
              onPressed: currentIds.isEmpty || selectionBusy
                  ? null
                  : () => downloadSelected(books, currentIds),
              icon: downloadingBusy
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(CupertinoIcons.arrow_down_circle),
            ),
            IconButton(
              tooltip: 'Gom nhóm sách đã chọn',
              onPressed: currentIds.isEmpty || selectionBusy
                  ? null
                  : () => groupSelected(books, currentIds),
              icon: groupingBusy
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(CupertinoIcons.folder_badge_plus),
            ),
          ] else ...[
            IconButton(
              tooltip: searching ? 'Đóng tìm kiếm' : 'Tìm trong thư viện',
              onPressed: () => setState(() {
                searching = !searching;
                if (!searching) query = '';
              }),
              icon: Icon(
                searching ? CupertinoIcons.xmark : CupertinoIcons.search,
              ),
            ),
            IconButton(
              tooltip: 'Lọc thư viện',
              onPressed: library.value == null
                  ? null
                  : () => showFilters(library.value!),
              color: filter.active
                  ? Theme.of(context).colorScheme.primary
                  : null,
              icon: const Icon(Icons.filter_list),
            ),
            PopupMenuButton<String>(
              tooltip: 'Thao tác thư viện',
              icon: importing
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.more_vert),
              onSelected: (v) {
                if (v == 'search-help') {
                  showCupertinoDialog<void>(
                    context: context,
                    builder: (ctx) => CupertinoAlertDialog(
                      title: const Text('Tìm nâng cao'),
                      content: const Text(
                        'Tìm theo tên, tác giả, họa sĩ, thể loại hoặc ghi chú.\n\nauthor:"Nguyễn Văn A"\ngenre:phiêu -notes:đãđọc\n(read>=10 || unread=0) && title:truyện\n\nDùng && để kết hợp, || để chọn một điều kiện, - để loại trừ. Có thể dùng title, author, artist, desc, genre, notes, series, collection, source và source_id.',
                      ),
                      actions: [
                        CupertinoDialogAction(
                          onPressed: () => Navigator.pop(ctx),
                          child: const Text('Đóng'),
                        ),
                      ],
                    ),
                  );
                }
                if (v == 'import') import();
                if (v == 'select') setState(() => selecting = true);
                for (final mode in LibraryGrouping.values) {
                  if (v == 'group-${mode.name}') {
                    perform(context, () => changeGrouping(mode));
                  }
                }
                if (v == 'refresh') {
                  perform(context, ref.read(libraryProvider.notifier).refresh);
                }
              },
              itemBuilder: (_) => [
                const PopupMenuItem(
                  value: 'search-help',
                  child: Text('Hướng dẫn tìm nâng cao'),
                ),
                PopupMenuItem(
                  value: 'select',
                  enabled: books.isNotEmpty,
                  child: const Text('Chọn nhiều sách'),
                ),
                const PopupMenuDivider(),
                for (final mode in LibraryGrouping.values)
                  CheckedPopupMenuItem(
                    key: ValueKey('library-group-mode-${mode.name}'),
                    value: 'group-${mode.name}',
                    checked: grouping == mode,
                    child: Text(
                      mode == LibraryGrouping.collection
                          ? 'Nhóm theo kệ'
                          : 'Tự nhóm theo ${mode.label.toLowerCase()}',
                    ),
                  ),
                const PopupMenuDivider(),
                PopupMenuItem(
                  value: 'import',
                  enabled: !importing,
                  child: const Text('Nhập EPUB, TXT, CBZ'),
                ),
                const PopupMenuItem(
                  value: 'refresh',
                  child: Text('Làm mới thư viện'),
                ),
              ],
            ),
          ],
        ],
      ),
      body: library.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => EmptyPanel(
          icon: Icons.error_outline,
          title: 'Không mở được thư viện',
          description: '$e',
          action: FilledButton(
            onPressed: () => ref.invalidate(libraryProvider),
            child: const Text('Thử lại'),
          ),
        ),
        data: (books) {
          return Column(
            children: [
              if (books.isNotEmpty)
                LibraryGroupTabs(
                  groups: groups,
                  selectedKey: selectedGroup,
                  total: books.length,
                  grouping: grouping,
                  onSelected: (key) => setState(() {
                    selectedGroup = key;
                    filter = filter.copyWith(category: 'Tất cả');
                  }),
                ),
              const Divider(height: 1),
              Expanded(
                child: visible.isEmpty
                    ? EmptyPanel(
                        icon: CupertinoIcons.book,
                        title: books.isEmpty
                            ? 'Tủ sách của bạn'
                            : 'Chưa có sách trong kệ này',
                        description: books.isEmpty
                            ? 'Thêm manga, truyện chữ hoặc EPUB. Tiến độ và nội dung đã tải được giữ trong máy.'
                            : 'Đổi bộ lọc hoặc thêm sách vào kệ.',
                        action: books.isEmpty
                            ? FilledButton.icon(
                                onPressed: importing ? null : import,
                                icon: const Icon(CupertinoIcons.plus),
                                label: const Text('Nhập EPUB, TXT, CBZ'),
                              )
                            : null,
                        secondary: books.isEmpty
                            ? TextButton(
                                onPressed: () => perform(
                                  context,
                                  () => ref
                                      .read(libraryProvider.notifier)
                                      .addExample(),
                                ),
                                child: const Text('Thử reader với sách mẫu'),
                              )
                            : null,
                      )
                    : LayoutBuilder(
                        builder: (context, size) {
                          final columns =
                              (settings.libraryColumns +
                                      (filter.compact ? 1 : 0))
                                  .clamp(2, 8);
                          return RefreshIndicator(
                            onRefresh: ref
                                .read(libraryProvider.notifier)
                                .refresh,
                            child: GridView.builder(
                              padding: EdgeInsets.fromLTRB(
                                10,
                                4,
                                10,
                                MediaQuery.viewPaddingOf(context).bottom + 16,
                              ),
                              itemCount: visible.length,
                              gridDelegate:
                                  SliverGridDelegateWithFixedCrossAxisCount(
                                    crossAxisCount: columns,
                                    crossAxisSpacing: 6,
                                    mainAxisSpacing: 6,
                                    childAspectRatio: .74,
                                  ),
                              itemBuilder: (_, i) {
                                final b = visible[i];
                                return Semantics(
                                  label: b.title,
                                  button: true,
                                  selected: selecting
                                      ? currentIds.contains(b.id)
                                      : null,
                                  child: InkWell(
                                    key: ValueKey('library-book-${b.id}'),
                                    onLongPress: selectionBusy
                                        ? null
                                        : () => toggleSelection(b.id),
                                    onTap: selectionBusy
                                        ? null
                                        : selecting
                                        ? () => toggleSelection(b.id)
                                        : () => context.push('/book/${b.id}'),
                                    child: ExcludeSemantics(
                                      child: Stack(
                                        fit: StackFit.expand,
                                        children: [
                                          BookCover(
                                            title: b.title,
                                            cover: b.cover,
                                            kind: b.kind,
                                            unread: b.completed
                                                ? 0
                                                : b.chapters.length -
                                                      b.currentChapter,
                                            downloaded: b.chapters
                                                .where((c) => c.downloaded)
                                                .length,
                                          ),
                                          if (selecting)
                                            DecoratedBox(
                                              decoration: BoxDecoration(
                                                color: currentIds.contains(b.id)
                                                    ? Theme.of(context)
                                                          .colorScheme
                                                          .primary
                                                          .withValues(
                                                            alpha: .18,
                                                          )
                                                    : Colors.transparent,
                                                border: Border.all(
                                                  color:
                                                      currentIds.contains(b.id)
                                                      ? Theme.of(context)
                                                            .colorScheme
                                                            .primary
                                                      : Colors.transparent,
                                                  width: 2,
                                                ),
                                                borderRadius:
                                                    BorderRadius.circular(4),
                                              ),
                                              child: Align(
                                                alignment:
                                                    Alignment.bottomRight,
                                                child: Padding(
                                                  padding: const EdgeInsets.all(
                                                    3,
                                                  ),
                                                  child: Icon(
                                                    currentIds.contains(b.id)
                                                        ? CupertinoIcons
                                                              .checkmark_circle_fill
                                                        : CupertinoIcons.circle,
                                                    color:
                                                        currentIds.contains(
                                                          b.id,
                                                        )
                                                        ? Theme.of(context)
                                                              .colorScheme
                                                              .primary
                                                        : Colors.white,
                                                    size: 22,
                                                  ),
                                                ),
                                              ),
                                            ),
                                        ],
                                      ),
                                    ),
                                  ),
                                );
                              },
                            ),
                          );
                        },
                      ),
              ),
            ],
          );
        },
      ),
    );
  }
}
