import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/widgets/book_cover.dart';
import '../../../core/widgets/feedback.dart';
import '../domain/library_book.dart';
import 'library_filter_sheet.dart';
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
          if (mounted) setState(() => filter = value);
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final library = ref.watch(libraryProvider);
    return Scaffold(
      appBar: AppBar(
        title: searching
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
            color: filter.active ? Theme.of(context).colorScheme.primary : null,
            icon: const Icon(CupertinoIcons.line_horizontal_3_decrease),
          ),
          PopupMenuButton<String>(
            tooltip: 'Thao tác thư viện',
            icon: importing
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(CupertinoIcons.ellipsis_vertical),
            onSelected: (v) {
              if (v == 'import') import();
              if (v == 'refresh') {
                perform(context, ref.read(libraryProvider.notifier).refresh);
              }
            },
            itemBuilder: (_) => [
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
          final collections = books
              .map((b) => b.collection)
              .where((c) => c.isNotEmpty && c != 'Mặc định')
              .toSet();
          final categories = ['Tất cả', ...collections];
          final visible =
              books
                  .where(
                    (b) =>
                        (filter.kind == 'all' || b.kind == filter.kind) &&
                        b.title.toLowerCase().contains(query.toLowerCase()) &&
                        switch (filter.category) {
                          'Đang đọc' => b.lastRead != null && !b.completed,
                          'Yêu thích' => b.favorite,
                          'Hoàn thành' => b.completed,
                          'Tất cả' => true,
                          _ => b.collection == filter.category,
                        },
                  )
                  .toList()
                ..sort((a, b) {
                  final result = switch (filter.order) {
                    LibraryOrder.recent =>
                      (b.lastRead ?? DateTime(1970)).compareTo(
                        a.lastRead ?? DateTime(1970),
                      ),
                    LibraryOrder.title => a.title.toLowerCase().compareTo(
                      b.title.toLowerCase(),
                    ),
                    LibraryOrder.unread =>
                      (b.chapters.length - b.currentChapter).compareTo(
                        a.chapters.length - a.currentChapter,
                      ),
                  };
                  return filter.reverse ? -result : result;
                });
          return Column(
            children: [
              if (collections.isNotEmpty)
                SizedBox(
                  height: 38,
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    children: categories
                        .map(
                          (c) => InkWell(
                            onTap: () => setState(
                              () => filter = filter.copyWith(category: c),
                            ),
                            child: Container(
                              alignment: Alignment.center,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16,
                              ),
                              decoration: BoxDecoration(
                                border: Border(
                                  bottom: BorderSide(
                                    width: 2,
                                    color: filter.category == c
                                        ? Theme.of(context).colorScheme.primary
                                        : Colors.transparent,
                                  ),
                                ),
                              ),
                              child: Text(
                                c,
                                style: TextStyle(
                                  color: filter.category == c
                                      ? Theme.of(context).colorScheme.primary
                                      : null,
                                ),
                              ),
                            ),
                          ),
                        )
                        .toList(),
                  ),
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
                              (size.maxWidth / (filter.compact ? 128 : 175))
                                  .floor()
                                  .clamp(2, 8);
                          return RefreshIndicator(
                            onRefresh: ref
                                .read(libraryProvider.notifier)
                                .refresh,
                            child: GridView.builder(
                              padding: const EdgeInsets.all(4),
                              itemCount: visible.length,
                              gridDelegate:
                                  SliverGridDelegateWithFixedCrossAxisCount(
                                    crossAxisCount: columns,
                                    crossAxisSpacing: 4,
                                    mainAxisSpacing: 4,
                                    childAspectRatio: .68,
                                  ),
                              itemBuilder: (_, i) {
                                final b = visible[i];
                                return Semantics(
                                  label: b.title,
                                  button: true,
                                  child: InkWell(
                                    onTap: () => context.push('/book/${b.id}'),
                                    child: ExcludeSemantics(
                                      child: BookCover(
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
