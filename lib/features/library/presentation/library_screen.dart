import 'dart:math';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/widgets/book_cover.dart';
import '../../../core/widgets/feedback.dart';
import '../../downloads/presentation/download_queue_controller.dart';
import '../domain/library_book.dart';
import '../domain/library_authors.dart';
import '../domain/library_grouping.dart';
import '../domain/library_categories.dart';
import '../domain/library_search.dart';
import '../domain/library_reading.dart';
import '../application/library_bulk_actions.dart';
import '../application/library_update_report.dart';
import '../data/coordinated_preferences.dart';
import '../data/library_mutation.dart';
import '../../deep_links/application/deep_link_queue.dart';
import '../../settings/settings_controller.dart';
import '../../settings/presentation/settings_widgets.dart';
import '../../sync/presentation/sync_screen.dart';
import '../../sources/presentation/source_cover_image.dart';
import 'library_filter_sheet.dart';
import 'library_filter_controller.dart';
import 'library_category_controller.dart';
import 'library_categories_screen.dart';
import 'library_group_dialog.dart';
import 'library_group_tabs.dart';
import 'library_grouping_controller.dart';
import 'library_group_order_controller.dart';
import 'library_group_order_sheet.dart';
import 'library_view_model.dart';
import 'library_view_session.dart';
import 'library_duplicate_sheet.dart';
import 'library_filter_presets_bar.dart';
import 'library_book_metadata.dart';
import 'library_book_tile.dart';
import 'library_source_label.dart';
import 'library_locations.dart';
import 'library_folder_tile.dart';
import 'library_folders_controller.dart';
import 'library_folder_name_dialog.dart';
import 'library_folder_download_selection.dart';

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
  String? get folderCategory => selectedGroup?.startsWith('value:') == true
      ? selectedGroup!.substring(6)
      : null;
  String? selectedFolder;
  bool selecting = false, groupingBusy = false;
  int? selectionRevision;
  bool downloadingBusy = false, bulkBusy = false;
  bool get selectionBusy => groupingBusy || downloadingBusy || bulkBusy;
  final selectedIds = <String>{};
  late final LibraryViewSession viewSession;
  late final TextEditingController queryController;

  @override
  void initState() {
    super.initState();
    viewSession = ref.read(libraryViewSessionProvider);
    final revision = ref.read(libraryRepositoryProvider).replacementRevision;
    if (viewSession.revision != revision) viewSession.reset(revision);
    query = viewSession.query;
    searching = viewSession.searching;
    selectedGroup = viewSession.selectedGroup;
    selectedFolder = viewSession.selectedFolder;
    queryController = TextEditingController(text: query);
  }

  @override
  void dispose() {
    viewSession.query = query;
    viewSession.searching = searching;
    viewSession.selectedGroup = selectedGroup;
    viewSession.selectedFolder = selectedFolder;
    queryController.dispose();
    super.dispose();
  }

  Future<void> reorderGroups(List<LibraryGroup> groups) async {
    const mode = LibraryGrouping.collection;
    final keys = await showLibraryGroupOrderSheet(context, groups);
    if (keys == null || !mounted) return;
    await perform(
      context,
      () => ref.read(libraryGroupOrderProvider.notifier).setOrder(mode, keys),
    );
  }

  Future<void> resumeBook(LibraryBook book, int revision) async {
    await perform(context, () async {
      final repository = ref.read(libraryRepositoryProvider);
      checkLibraryRevision(repository.replacementRevision, revision);
      final latest = await repository.find(book.id);
      checkLibraryRevision(repository.replacementRevision, revision);
      if (latest == null || latest.chapters.isEmpty || !mounted) return;
      final chapter = latest.currentChapter.clamp(
        0,
        latest.chapters.length - 1,
      );
      context.push<void>(
        libraryReaderLocation(latest, chapter),
        extra: LibraryLinkHandoff(revision),
      );
    });
  }

  Future<void> refreshVisibleBooks(List<LibraryBook> visible) async {
    final ids = visible.map((book) => book.id).toList(growable: false);
    final revision = ref.read(libraryRepositoryProvider).replacementRevision;
    final result = await perform(
      context,
      () => ref
          .read(libraryProvider.notifier)
          .updateBooks(ids, expectedRevision: revision),
    );
    if (result == null || !mounted) return;
    final summary = result.checkedBooks == 0 && !result.hasErrors
        ? 'Không có truyện từ nguồn trực tuyến trong mục này.'
        : 'Đã kiểm tra ${result.checkedBooks} truyện, '
              'thêm ${result.addedChapters} chương mới.';
    if (!result.hasErrors) {
      message(context, summary);
      return;
    }
    await showCupertinoDialog<void>(
      context: context,
      builder: (ctx) => CupertinoAlertDialog(
        title: const Text('Kết quả cập nhật'),
        content: Text(
          '$summary\n${result.failures.length} truyện chưa cập nhật được.\n\n'
          '${result.failures.take(3).map((failure) => '${failure.title}: ${failure.message}').join('\n\n')}'
          '${result.failures.length > 3 ? '\n\nCòn ${result.failures.length - 3} truyện lỗi.' : ''}',
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

  Future<void> changeGrouping(LibraryGrouping mode) async {
    await ref.read(libraryGroupingProvider.notifier).setGrouping(mode);
    if (!mounted) return;
    setState(() {
      selectedFolder = null;
    });
  }

  void toggleSelection(String id) => setState(() {
    if (!selecting) {
      selectionRevision = ref
          .read(libraryRepositoryProvider)
          .replacementRevision;
    }
    selecting = true;
    if (!selectedIds.remove(id)) selectedIds.add(id);
  });

  void clearSearch() => setState(() {
    query = '';
    queryController.clear();
  });

  Future<void> resetFilters() => perform(context, () async {
    await ref
        .read(libraryFilterProvider.notifier)
        .save(
          filter.copyWith(
            kind: 'all',
            category: 'Tất cả',
            source: 'all',
            excludeSource: false,
            author: '',
            scanlator: '',
            unread: LibraryTriState.any,
            downloaded: LibraryTriState.any,
            bookmarked: LibraryTriState.any,
            favorite: LibraryTriState.any,
            completed: LibraryTriState.any,
          ),
          grouping: LibraryGrouping.collection,
          groupKey: selectedGroup,
        );
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
              filter.matches(book) &&
              search.matches(book),
        )
        .toList()
      ..sort(filter.compare);
  }

  Future<String?> folderName({String? initial}) => showDialog<String>(
    context: context,
    builder: (_) => LibraryFolderNameDialog(initial: initial),
  );

  Future<void> groupSelected(List<LibraryBook> books, Set<String> ids) async {
    final revision = ref.read(libraryRepositoryProvider).replacementRevision;
    final category = folderCategory;
    final name = await folderName();
    if (name == null || !mounted) return;
    setState(() => groupingBusy = true);
    final saved = await perform(context, () async {
      await ref
          .read(libraryFoldersProvider.notifier)
          .assign(ids, name, expectedRevision: revision, category: category);
      return true;
    });
    if (!mounted) return;
    setState(() {
      groupingBusy = false;
      if (saved == true) {
        selecting = false;
        selectedIds.clear();
        selectionRevision = null;
        selectedFolder = null;
      }
    });
  }

  Future<void> manageFolder(LibraryGroup folder) async {
    final revision = ref.read(libraryRepositoryProvider).replacementRevision;
    final category = folderCategory;
    final ids = folder.bookIds.toList();
    final action = await showModalBottomSheet<String>(
      context: context,
      useSafeArea: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text(folder.label),
              subtitle: Text(
                '${folder.bookIds.length} truyện trong danh mục này',
              ),
            ),
            ListTile(
              leading: const Icon(CupertinoIcons.pencil),
              title: const Text('Đổi tên thư mục'),
              onTap: () => Navigator.pop(ctx, 'rename'),
            ),
            ListTile(
              leading: const Icon(CupertinoIcons.folder_badge_minus),
              title: const Text('Bỏ thư mục, giữ các truyện'),
              onTap: () => Navigator.pop(ctx, 'remove'),
            ),
          ],
        ),
      ),
    );
    if (action == null || !mounted) return;
    final name = action == 'rename'
        ? await folderName(initial: folder.label)
        : null;
    if (!mounted || (action == 'rename' && name == null)) return;
    await perform(
      context,
      () => ref
          .read(libraryFoldersProvider.notifier)
          .assign(ids, name, expectedRevision: revision, category: category),
    );
    if (mounted) setState(() => selectedFolder = null);
  }

  Future<void> editSelectedMetadata(
    List<LibraryBook> books,
    Set<String> ids,
  ) async {
    final revision = ref.read(libraryRepositoryProvider).replacementRevision;
    final edit = await showLibraryGroupDialog(
      context,
      books: books,
      selectedIds: ids,
      grouping: grouping,
      availableCategories: ref
          .read(libraryCategoriesProvider)
          .all(books)
          .map((category) => category.name)
          .toList(),
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
            categories: edit.categories,
            expectedRevision: revision,
          ),
    );
    if (!mounted) return;
    setState(() {
      groupingBusy = false;
      if (count != null) {
        selecting = false;
        selectionRevision = null;
        selectedIds.clear();
        selectedFolder = null;
        filter = filter.copyWith(category: 'Tất cả');
      }
    });
    if (count != null) message(context, 'Đã cập nhật nhóm cho $count sách');
  }

  Future<void> downloadSelected(
    List<LibraryBook> books,
    Set<String> ids, {
    int? expectedRevision,
  }) async {
    final selected = books.where((book) => ids.contains(book.id)).toList();
    if (selected.isEmpty || selectionBusy) return;
    final revision =
        expectedRevision ??
        selectionRevision ??
        ref.read(libraryRepositoryProvider).replacementRevision;
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

  Future<void> downloadFolders(
    List<LibraryBook> books,
    List<LibraryGroup> folders,
  ) async {
    final revision = ref.read(libraryRepositoryProvider).replacementRevision;
    final preferences = ref.read(preferencesProvider);
    final generation = preferences is CoordinatedPreferences
        ? preferences.mutationGeneration
        : 0;
    final ids = await showLibraryFolderDownloadSelection(context, folders);
    if (ids == null || ids.isEmpty || !mounted) return;
    await perform(context, () async {
      checkLibraryRevision(
        ref.read(libraryRepositoryProvider).replacementRevision,
        revision,
      );
      if (preferences is CoordinatedPreferences &&
          preferences.mutationGeneration != generation) {
        throw StateError('Thiết lập đã được khôi phục. Chọn lại thư mục.');
      }
      await downloadSelected(books, ids, expectedRevision: revision);
    });
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

  Future<void> bulkAction(
    String action,
    List<LibraryBook> books,
    Set<String> ids,
  ) async {
    if (selectionBusy || ids.isEmpty) return;
    if (action == 'categories') {
      await editSelectedMetadata(books, ids);
      return;
    }
    if (action == 'unfolder') {
      final revision = ref.read(libraryRepositoryProvider).replacementRevision;
      await perform(
        context,
        () => ref
            .read(libraryFoldersProvider.notifier)
            .assign(
              ids,
              null,
              expectedRevision: revision,
              category: folderCategory,
            ),
      );
      return;
    }
    final repository = ref.read(libraryRepositoryProvider);
    final revision = repository.replacementRevision;
    final actions = LibraryBulkActions(repository);
    setState(() => bulkBusy = true);
    final count = await perform(context, () async {
      if (action == 'delete') {
        final preview = await actions.previewRemoval(ids, revision: revision);
        if (!mounted || preview.books.isEmpty) return null;
        final confirmed = await showCupertinoDialog<bool>(
          context: context,
          builder: (ctx) => CupertinoAlertDialog(
            title: Text('Xóa ${preview.books.length} truyện khỏi thư viện?'),
            content: Text(
              'Các truyện đã chọn và ${preview.cachedChapters} chương đã lưu trong app sẽ bị xóa. File gốc đã nhập từ ứng dụng Tệp được giữ nguyên. Một bản khôi phục được lưu trước khi xóa.',
            ),
            actions: [
              CupertinoDialogAction(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Hủy'),
              ),
              CupertinoDialogAction(
                isDestructiveAction: true,
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Xóa truyện'),
              ),
            ],
          ),
        );
        if (confirmed != true || !mounted) return null;
        final queue = ref.read(downloadQueueProvider.notifier);
        final removed = await actions.remove(preview);
        var pending = 0;
        for (final book in preview.books) {
          try {
            await queue.cancelBook(book.id);
          } catch (_) {
            pending++;
          }
        }
        if (mounted && pending > 0) {
          message(
            context,
            'Đã xóa truyện. Còn $pending mục cần xóa khỏi hàng đợi tải; các lượt tải cũ không thể ghi lại truyện đã xóa.',
          );
        }
        return removed;
      }
      if (action == 'read' || action == 'unread') {
        return actions.markRead(ids, action == 'read', revision: revision);
      }
      if (action == 'favorite' || action == 'unfavorite') {
        return actions.favorite(ids, action == 'favorite', revision: revision);
      }
      final result = await ref
          .read(libraryProvider.notifier)
          .updateBooks(ids, expectedRevision: revision);
      if (mounted) {
        message(
          context,
          'Đã kiểm tra ${result.checkedBooks} truyện, thêm ${result.addedChapters} chương. ${result.failures.length} truyện chưa cập nhật được.',
        );
      }
      return result.checkedBooks;
    });
    if (!mounted) return;
    await ref.read(libraryProvider.notifier).refresh();
    if (!mounted) return;
    setState(() {
      bulkBusy = false;
      if (count != null && action == 'delete') {
        selecting = false;
        selectionRevision = null;
        selectedIds.clear();
      }
    });
    if (count != null && action != 'refresh') {
      message(context, 'Đã cập nhật $count truyện');
    }
  }

  void showFilters(List<LibraryBook> books) {
    final preferences = ref.read(preferencesProvider);
    final generation = preferences is CoordinatedPreferences
        ? preferences.mutationGeneration
        : 0;
    const mode = LibraryGrouping.collection;
    var groupKey = selectedGroup;
    final collections =
        ref
            .read(libraryCategoriesProvider)
            .all(books)
            .map((category) => category.name)
            .toList()
          ..sort();
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: false,
      constraints: const BoxConstraints(maxWidth: 600),
      builder: (_) => Consumer(
        builder: (_, sheetRef, _) => LibraryFilterSheet(
          value: filter,
          libraryColumns: ref.read(settingsProvider).libraryColumns,
          onColumnsChanged: (columns) => perform(context, () async {
            if (preferences is CoordinatedPreferences &&
                preferences.mutationGeneration != generation) {
              throw StateError(
                'Thiết lập đã được khôi phục. Hãy mở lại bộ lọc.',
              );
            }
            await ref
                .read(settingsProvider.notifier)
                .update(libraryColumns: columns);
          }),
          presetsBuilder: (filter, onApply) =>
              LibraryFilterPresetsBar(filter: filter, onApply: onApply),
          collections: collections,
          authors: {
            for (final book in books) ...libraryAuthorNames(book.author),
          },
          sources: {
            for (final book in books)
              if (book.engine != 'local')
                '${book.engine}:${book.sourceId}': resolvedLibrarySourceLabel(
                  sheetRef,
                  book,
                ),
          },
          onChanged: (value) async {
            if (mounted) {
              var next = value;
              if (value.category != 'Tất cả' &&
                  collections.contains(value.category)) {
                groupKey = 'value:${value.category}';
                next = value.copyWith(category: 'Tất cả');
              }
              final targetGroup = groupKey;
              final saved = await perform(context, () async {
                await ref
                    .read(libraryFilterProvider.notifier)
                    .save(
                      next,
                      grouping: mode,
                      groupKey: targetGroup,
                      expectedGeneration: generation,
                    );
                return true;
              });
              if (mounted && saved == true) {
                setState(() {
                  if (selectedGroup != targetGroup) selectedFolder = null;
                  selectedGroup = targetGroup;
                });
              }
            }
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final library = ref.watch(libraryProvider);
    final settings = ref.watch(settingsProvider);
    final grouping = ref.watch(libraryGroupingProvider);
    final books = library.value ?? <LibraryBook>[];
    final updateProgress = ref.watch(libraryUpdateProgressProvider);
    final revision = ref.read(libraryRepositoryProvider).replacementRevision;
    if (selecting && selectionRevision != revision) {
      selecting = false;
      selectionRevision = null;
      selectedIds.clear();
    }
    final groupOrders = ref.watch(libraryGroupOrderProvider);
    final groups = orderLibraryGroups(
      libraryCategoryGroups(books, ref.watch(libraryCategoriesProvider)),
      groupOrders[LibraryGrouping.collection.name] ?? const [],
    );
    if (!groups.any((group) => group.key == selectedGroup)) {
      selectedGroup = groups.firstOrNull?.key;
      selectedFolder = null;
    }
    filter = ref
        .watch(libraryFilterProvider)
        .forGroup(LibraryGrouping.collection, selectedGroup);
    // Category tabs already scope the contents. Legacy category filters remain
    // stored for compatibility, but must not intersect two different categories.
    if (groups.any((group) => group.key == 'value:${filter.category}')) {
      filter = filter.copyWith(category: 'Tất cả');
    }
    final inCategory = visibleBooks(books, groups);
    final folders = ref
        .watch(libraryFoldersProvider)
        .groups(inCategory, grouping, category: folderCategory);
    final openFolder = folders
        .where((folder) => folder.key == selectedFolder)
        .firstOrNull;
    if (openFolder == null) selectedFolder = null;
    final visible = openFolder == null
        ? inCategory
        : inCategory
              .where((book) => openFolder.bookIds.contains(book.id))
              .toList();
    final foldedIds = folders.expand((folder) => folder.bookIds).toSet();
    final tiles = <Object>[
      if (openFolder == null && !selecting) ...folders,
      ...visible.where(
        (book) =>
            openFolder != null || selecting || !foldedIds.contains(book.id),
      ),
    ];
    final currentIds = selectedIds.intersection(
      books.map((book) => book.id).toSet(),
    );
    final allVisibleSelected =
        visible.isNotEmpty &&
        visible.every((book) => currentIds.contains(book.id));
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          tooltip: selecting ? 'Hủy chọn sách' : 'Đồng bộ',
          icon: Icon(
            selecting ? CupertinoIcons.xmark : Icons.cloud_done_outlined,
          ),
          onPressed: selectionBusy
              ? null
              : selecting
              ? () => setState(() {
                  selecting = false;
                  selectionRevision = null;
                  selectedIds.clear();
                })
              : () => openSettingsPage(context, const SyncScreen()),
        ),
        title: selecting
            ? Text(
                'Đã chọn ${currentIds.length}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              )
            : searching
            ? TextField(
                controller: queryController,
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
            PopupMenuButton<String>(
              tooltip: 'Thao tác với sách đã chọn',
              enabled: currentIds.isNotEmpty && !selectionBusy,
              onSelected: (action) => bulkAction(action, books, currentIds),
              itemBuilder: (_) => const [
                PopupMenuItem(
                  value: 'categories',
                  child: Text('Danh mục và thông tin truyện'),
                ),
                PopupMenuItem(
                  value: 'unfolder',
                  child: Text('Đưa truyện ra khỏi thư mục'),
                ),
                PopupMenuItem(value: 'read', child: Text('Đánh dấu đã đọc')),
                PopupMenuItem(
                  value: 'unread',
                  child: Text('Đánh dấu chưa đọc'),
                ),
                PopupMenuItem(
                  value: 'favorite',
                  child: Text('Thêm vào yêu thích'),
                ),
                PopupMenuItem(value: 'unfavorite', child: Text('Bỏ yêu thích')),
                PopupMenuItem(
                  value: 'refresh',
                  child: Text('Cập nhật truyện đã chọn'),
                ),
                PopupMenuDivider(),
                PopupMenuItem(
                  value: 'delete',
                  child: Text('Xóa truyện đã chọn'),
                ),
              ],
            ),
          ] else ...[
            IconButton(
              tooltip: searching ? 'Đóng tìm kiếm' : 'Tìm trong thư viện',
              onPressed: () => setState(() {
                searching = !searching;
                if (!searching) {
                  query = '';
                  queryController.clear();
                }
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
                if (v == 'download-folders') downloadFolders(books, folders);
                if (v == 'categories') {
                  openSettingsPage(context, const LibraryCategoriesScreen());
                }
                if (v == 'select') {
                  setState(() {
                    selecting = true;
                    selectionRevision = revision;
                  });
                }
                if (v == 'duplicates') showLibraryDuplicates(context, books);
                if (v == 'random' && visible.isNotEmpty) {
                  context.push(
                    libraryBookLocation(
                      visible[Random().nextInt(visible.length)].id,
                    ),
                  );
                }
                if (v == 'reorder-groups') reorderGroups(groups);
                for (final mode in LibraryGrouping.values) {
                  if (v == 'group-${mode.name}') {
                    perform(context, () => changeGrouping(mode));
                  }
                }
                if (v == 'refresh') {
                  refreshVisibleBooks(visible);
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
                if (folders.isNotEmpty)
                  PopupMenuItem(
                    value: 'download-folders',
                    enabled: !selectionBusy,
                    child: const Text('Tải nhiều thư mục'),
                  ),
                PopupMenuItem(
                  value: 'random',
                  enabled: visible.isNotEmpty,
                  child: const Text('Mở truyện ngẫu nhiên trong mục này'),
                ),
                PopupMenuItem(
                  value: 'duplicates',
                  enabled: books.isNotEmpty,
                  child: const Text('Kiểm tra truyện trùng tên'),
                ),
                const PopupMenuDivider(),
                const PopupMenuItem(
                  value: 'categories',
                  child: Text('Quản lý danh mục'),
                ),
                PopupMenuItem(
                  value: 'reorder-groups',
                  enabled: groups.length > 1,
                  child: const Text('Sắp xếp các mục'),
                ),
                for (final mode in LibraryGrouping.values)
                  CheckedPopupMenuItem(
                    key: ValueKey('library-group-mode-${mode.name}'),
                    value: 'group-${mode.name}',
                    checked: grouping == mode,
                    child: Text(
                      mode == LibraryGrouping.collection
                          ? 'Chỉ dùng thư mục tự tạo'
                          : 'Tự tạo thư mục theo ${mode.label.toLowerCase()}',
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
                  child: Text('Cập nhật chương mới'),
                ),
              ],
            ),
          ],
        ],
      ),
      body: PageStorage(
        bucket: ref.watch(mainPageStorageProvider),
        child: library.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => EmptyPanel(
            icon: Icons.error_outline,
            title: 'Không mở được thư viện',
            description: userFacingError(e),
            action: FilledButton(
              onPressed: () => ref.invalidate(libraryProvider),
              child: const Text('Thử lại'),
            ),
          ),
          data: (books) {
            return Column(
              children: [
                if (updateProgress != null)
                  LinearProgressIndicator(
                    value: updateProgress.fraction,
                    semanticsLabel:
                        'Đang kiểm tra chương mới: ${updateProgress.processedBooks}/${updateProgress.requestedBooks} truyện',
                  ),
                if (groups.isNotEmpty && filter.showCategoryTabs)
                  LibraryGroupTabs(
                    groups: groups,
                    selectedKey: selectedGroup,
                    total: books.length,
                    grouping: LibraryGrouping.collection,
                    onManage: () => openSettingsPage(
                      context,
                      const LibraryCategoriesScreen(),
                    ),
                    onReorder: groups.length > 1
                        ? () => reorderGroups(groups)
                        : null,
                    onSelected: (key) => setState(() {
                      selectedGroup = key;
                      selectedFolder = null;
                      filter = filter.copyWith(category: 'Tất cả');
                    }),
                  ),
                if (groups.isNotEmpty && !filter.showCategoryTabs)
                  Padding(
                    padding: const EdgeInsets.only(left: 16, right: 4),
                    child: Row(
                      children: [
                        Expanded(
                          child: DropdownButton<String>(
                            key: const ValueKey('library-category-selector'),
                            value: selectedGroup,
                            isExpanded: true,
                            items: [
                              for (final group in groups)
                                DropdownMenuItem(
                                  value: group.key,
                                  child: Text(
                                    '${group.label} (${group.bookIds.length})',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                            ],
                            onChanged: (key) => setState(() {
                              selectedGroup = key;
                              selectedFolder = null;
                            }),
                          ),
                        ),
                        IconButton(
                          tooltip: 'Quản lý danh mục',
                          onPressed: () => openSettingsPage(
                            context,
                            const LibraryCategoriesScreen(),
                          ),
                          icon: const Icon(CupertinoIcons.add),
                        ),
                      ],
                    ),
                  ),
                if (openFolder != null)
                  Row(
                    children: [
                      IconButton(
                        tooltip: 'Về danh mục',
                        onPressed: () => setState(() => selectedFolder = null),
                        icon: const Icon(CupertinoIcons.chevron_left),
                      ),
                      Expanded(
                        child: Text(
                          '${openFolder.label} · ${openFolder.bookIds.length} truyện',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (openFolder.key.startsWith('folder:'))
                        IconButton(
                          tooltip: 'Sửa thư mục',
                          onPressed: () => manageFolder(openFolder),
                          icon: const Icon(CupertinoIcons.ellipsis),
                        ),
                    ],
                  ),
                const Divider(height: 1),
                Expanded(
                  child: visible.isEmpty
                      ? RefreshIndicator(
                          onRefresh: () => refreshVisibleBooks(visible),
                          child: CustomScrollView(
                            key: const PageStorageKey('library-empty'),
                            physics: const AlwaysScrollableScrollPhysics(),
                            slivers: [
                              SliverFillRemaining(
                                hasScrollBody: false,
                                child: EmptyPanel(
                                  icon: CupertinoIcons.book,
                                  title: books.isEmpty
                                      ? 'Tủ sách của bạn'
                                      : query.trim().isNotEmpty
                                      ? 'Không có kết quả tìm kiếm'
                                      : filter.active
                                      ? 'Không có truyện phù hợp'
                                      : 'Chưa có sách trong kệ này',
                                  description: books.isEmpty
                                      ? 'Thêm manga, truyện chữ hoặc EPUB. Tiến độ và nội dung đã tải được giữ trong máy.'
                                      : query.trim().isNotEmpty
                                      ? 'Không tìm thấy truyện cho “${query.trim()}”.'
                                      : 'Đổi bộ lọc hoặc thêm sách vào kệ.',
                                  action: books.isEmpty
                                      ? FilledButton.icon(
                                          onPressed: () =>
                                              context.go('/browse'),
                                          icon: const Icon(
                                            CupertinoIcons.compass,
                                          ),
                                          label: const Text('Khám phá truyện'),
                                        )
                                      : query.trim().isNotEmpty
                                      ? FilledButton(
                                          onPressed: clearSearch,
                                          child: const Text('Xóa tìm kiếm'),
                                        )
                                      : filter.active
                                      ? FilledButton(
                                          onPressed: resetFilters,
                                          child: const Text('Đặt lại bộ lọc'),
                                        )
                                      : selectedGroup != null
                                      ? FilledButton(
                                          onPressed: () => setState(() {
                                            selectedGroup =
                                                groups.firstOrNull?.key;
                                            selectedFolder = null;
                                          }),
                                          child: const Text(
                                            'Về danh mục đầu tiên',
                                          ),
                                        )
                                      : null,
                                  secondary: books.isEmpty
                                      ? Wrap(
                                          alignment: WrapAlignment.center,
                                          children: [
                                            TextButton(
                                              onPressed: importing
                                                  ? null
                                                  : import,
                                              child: const Text(
                                                'Nhập EPUB, TXT, CBZ',
                                              ),
                                            ),
                                            TextButton(
                                              onPressed: () => perform(
                                                context,
                                                () => ref
                                                    .read(
                                                      libraryProvider.notifier,
                                                    )
                                                    .addExample(),
                                              ),
                                              child: const Text(
                                                'Thử reader với sách mẫu',
                                              ),
                                            ),
                                          ],
                                        )
                                      : null,
                                ),
                              ),
                            ],
                          ),
                        )
                      : LayoutBuilder(
                          builder: (context, size) {
                            if (filter.display == LibraryDisplay.list) {
                              return RefreshIndicator(
                                onRefresh: () => refreshVisibleBooks(visible),
                                child: ListView.builder(
                                  key: PageStorageKey(
                                    'library-list:${grouping.name}:$selectedGroup:$selectedFolder',
                                  ),
                                  physics:
                                      const AlwaysScrollableScrollPhysics(),
                                  itemCount: tiles.length,
                                  itemBuilder: (context, index) {
                                    final item = tiles[index];
                                    if (item is LibraryGroup) {
                                      return LibraryFolderTile(
                                        key: ValueKey(
                                          'library-folder-${item.key}',
                                        ),
                                        folder: item,
                                        list: true,
                                        onTap: () => setState(
                                          () => selectedFolder = item.key,
                                        ),
                                        onLongPress:
                                            item.key.startsWith('folder:')
                                            ? () => manageFolder(item)
                                            : null,
                                      );
                                    }
                                    final b = item as LibraryBook;
                                    return ListTile(
                                      key: ValueKey('library-book-${b.id}'),
                                      minTileHeight: 100,
                                      leading: SizedBox(
                                        width: 60,
                                        height: 90,
                                        child: BookCover(
                                          title: b.title,
                                          cover: b.cover,
                                          imageProvider: libraryCoverImage(
                                            ref,
                                            b,
                                          ),
                                          kind: b.kind,
                                          showTitle: false,
                                        ),
                                      ),
                                      title: Text(
                                        b.title,
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                      subtitle: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          if (b.author.isNotEmpty)
                                            Text(b.author),
                                          Text(b.categories.join(', ')),
                                          LibraryBookMetadata(
                                            book: b,
                                            sourceLabel: filter.showSource
                                                ? resolvedLibrarySourceLabel(
                                                    ref,
                                                    b,
                                                  )
                                                : null,
                                            filter: filter,
                                          ),
                                        ],
                                      ),
                                      trailing: selecting
                                          ? Icon(
                                              currentIds.contains(b.id)
                                                  ? CupertinoIcons
                                                        .checkmark_circle_fill
                                                  : CupertinoIcons.circle,
                                            )
                                          : filter.showResumeButton
                                          ? IconButton(
                                              key: ValueKey(
                                                'library-resume-${b.id}',
                                              ),
                                              tooltip:
                                                  !bookHasReadingProgress(b)
                                                  ? 'Đọc chương đầu tiên'
                                                  : 'Tiếp tục đọc',
                                              onPressed:
                                                  b.chapters.isEmpty ||
                                                      selectionBusy
                                                  ? null
                                                  : () =>
                                                        resumeBook(b, revision),
                                              icon: const Icon(
                                                CupertinoIcons.play_fill,
                                              ),
                                            )
                                          : null,
                                      onLongPress: selectionBusy
                                          ? null
                                          : () => toggleSelection(b.id),
                                      onTap: selectionBusy
                                          ? null
                                          : selecting
                                          ? () => toggleSelection(b.id)
                                          : () => context.push(
                                              libraryBookLocation(b.id),
                                            ),
                                    );
                                  },
                                ),
                              );
                            }
                            final columns =
                                (settings.libraryColumns +
                                        (filter.compact ? 1 : 0))
                                    .clamp(2, 8);
                            return RefreshIndicator(
                              onRefresh: () => refreshVisibleBooks(visible),
                              child: GridView.builder(
                                key: PageStorageKey(
                                  'library-grid:${grouping.name}:$selectedGroup:$selectedFolder',
                                ),
                                physics: const AlwaysScrollableScrollPhysics(),
                                padding: EdgeInsets.fromLTRB(
                                  10,
                                  4,
                                  10,
                                  MediaQuery.viewPaddingOf(context).bottom + 16,
                                ),
                                itemCount: tiles.length,
                                gridDelegate:
                                    SliverGridDelegateWithFixedCrossAxisCount(
                                      crossAxisCount: columns,
                                      crossAxisSpacing: 6,
                                      mainAxisSpacing: 6,
                                      mainAxisExtent: max(
                                        ((size.maxWidth -
                                                        20 -
                                                        (columns - 1) * 6) /
                                                    columns) /
                                                .74 +
                                            LibraryBookTile.extraHeight(
                                              context,
                                              filter,
                                            ),
                                        openFolder == null &&
                                                folders.isNotEmpty &&
                                                !selecting
                                            ? 40 +
                                                  MediaQuery.textScalerOf(
                                                    context,
                                                  ).scale(44)
                                            : 0,
                                      ),
                                    ),
                                itemBuilder: (_, i) {
                                  final item = tiles[i];
                                  if (item is LibraryGroup) {
                                    return LibraryFolderTile(
                                      key: ValueKey(
                                        'library-folder-${item.key}',
                                      ),
                                      folder: item,
                                      onTap: () => setState(
                                        () => selectedFolder = item.key,
                                      ),
                                      onLongPress:
                                          item.key.startsWith('folder:')
                                          ? () => manageFolder(item)
                                          : null,
                                    );
                                  }
                                  final b = item as LibraryBook;
                                  return LibraryBookTile(
                                    book: b,
                                    sourceLabel: filter.showSource
                                        ? resolvedLibrarySourceLabel(ref, b)
                                        : null,
                                    coverImage: libraryCoverImage(ref, b),
                                    filter: filter,
                                    selected: selecting
                                        ? currentIds.contains(b.id)
                                        : null,
                                    onLongPress: selectionBusy
                                        ? null
                                        : () => toggleSelection(b.id),
                                    onTap: selectionBusy
                                        ? null
                                        : selecting
                                        ? () => toggleSelection(b.id)
                                        : () => context.push(
                                            libraryBookLocation(b.id),
                                          ),
                                    onResume:
                                        b.chapters.isEmpty || selectionBusy
                                        ? null
                                        : () => resumeBook(b, revision),
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
      ),
    );
  }
}
