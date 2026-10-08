import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/widgets/book_cover.dart';
import '../../../core/widgets/feedback.dart';
import 'library_view_model.dart';

class LibraryScreen extends ConsumerStatefulWidget {
  const LibraryScreen({super.key});
  @override
  ConsumerState<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends ConsumerState<LibraryScreen> {
  String query = '', category = 'Tất cả', kind = 'all';
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

  @override
  Widget build(BuildContext context) {
    final library = ref.watch(libraryProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Thư viện'),
        actions: [
          if (importing)
            const Padding(
              padding: EdgeInsets.all(16),
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          else
            IconButton(
              tooltip: 'Nhập sách',
              onPressed: import,
              icon: const Icon(CupertinoIcons.plus),
            ),
          IconButton(
            tooltip: 'Tìm trong thư viện',
            onPressed: () => setState(() => searching = !searching),
            icon: const Icon(CupertinoIcons.search),
          ),
          PopupMenuButton<String>(
            tooltip: 'Lọc nội dung',
            icon: const Icon(CupertinoIcons.line_horizontal_3_decrease),
            onSelected: (v) => setState(() => kind = v),
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'all', child: Text('Tất cả nội dung')),
              PopupMenuItem(value: 'manga', child: Text('Truyện tranh')),
              PopupMenuItem(value: 'novel', child: Text('Truyện chữ & ebook')),
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
              .where((c) => c.isNotEmpty)
              .toSet();
          final categories = [
            'Tất cả',
            'Đang đọc',
            'Yêu thích',
            'Hoàn thành',
            ...collections,
          ];
          final visible =
              books
                  .where(
                    (b) =>
                        (kind == 'all' || b.kind == kind) &&
                        b.title.toLowerCase().contains(query.toLowerCase()) &&
                        switch (category) {
                          'Đang đọc' => b.lastRead != null && !b.completed,
                          'Yêu thích' => b.favorite,
                          'Hoàn thành' => b.completed,
                          'Tất cả' => true,
                          _ => b.collection == category,
                        },
                  )
                  .toList()
                ..sort(
                  (a, b) => (b.lastRead ?? DateTime(1970)).compareTo(
                    a.lastRead ?? DateTime(1970),
                  ),
                );
          return Column(
            children: [
              if (searching)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                  child: TextField(
                    autofocus: true,
                    onChanged: (v) => setState(() => query = v),
                    decoration: const InputDecoration(
                      hintText: 'Tên truyện, tên sách',
                      prefixIcon: Icon(CupertinoIcons.search),
                    ),
                  ),
                ),
              SizedBox(
                height: 45,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  children: categories
                      .map(
                        (c) => Padding(
                          padding: const EdgeInsets.only(right: 6),
                          child: ChoiceChip(
                            label: Text(c),
                            selected: category == c,
                            showCheckmark: false,
                            onSelected: (_) => setState(() => category = c),
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
                          final columns = size.maxWidth > 1000
                              ? 6
                              : size.maxWidth > 650
                              ? 4
                              : 2;
                          return RefreshIndicator(
                            onRefresh: ref
                                .read(libraryProvider.notifier)
                                .refresh,
                            child: GridView.builder(
                              padding: const EdgeInsets.all(12),
                              itemCount: visible.length,
                              gridDelegate:
                                  SliverGridDelegateWithFixedCrossAxisCount(
                                    crossAxisCount: columns,
                                    crossAxisSpacing: 8,
                                    mainAxisSpacing: 8,
                                    childAspectRatio: .68,
                                  ),
                              itemBuilder: (_, i) {
                                final b = visible[i];
                                return Semantics(
                                  label: b.title,
                                  button: true,
                                  child: InkWell(
                                    onTap: () => context.push('/book/${b.id}'),
                                    child: BookCover(
                                      title: b.title,
                                      cover: b.cover,
                                      kind: b.kind,
                                      unread: b.completed
                                          ? 0
                                          : b.chapters.length -
                                                b.currentChapter,
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
