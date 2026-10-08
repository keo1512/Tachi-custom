import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/widgets/book_cover.dart';
import '../../../core/widgets/feedback.dart';
import 'library_view_model.dart';

class BookDetailScreen extends ConsumerStatefulWidget {
  const BookDetailScreen({super.key, required this.id});
  final String id;
  @override
  ConsumerState<BookDetailScreen> createState() => _BookDetailState();
}

class _BookDetailState extends ConsumerState<BookDetailScreen> {
  bool downloading = false;
  @override
  Widget build(BuildContext context) {
    final state = ref.watch(libraryProvider);
    return state.when(
      loading: () =>
          const Scaffold(body: Center(child: CircularProgressIndicator())),
      error: (e, _) => Scaffold(
        appBar: AppBar(),
        body: Center(child: Text('$e')),
      ),
      data: (books) {
        final matches = books.where((b) => b.id == widget.id);
        if (matches.isEmpty) {
          return Scaffold(
            appBar: AppBar(),
            body: const Center(child: Text('Sách không còn trong thư viện')),
          );
        }
        final book = matches.first;
        final vm = ref.read(libraryProvider.notifier);
        return Scaffold(
          appBar: AppBar(
            title: const Text('Chi tiết'),
            actions: [
              PopupMenuButton<String>(
                onSelected: (v) async {
                  if (v == 'collection') {
                    var collection = book.collection;
                    final name = await showDialog<String>(
                      context: context,
                      builder: (ctx) => AlertDialog(
                        title: const Text('Bộ sưu tập'),
                        content: TextFormField(
                          initialValue: collection,
                          onChanged: (value) => collection = value,
                          decoration: const InputDecoration(
                            hintText: 'Tên kệ sách',
                          ),
                        ),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(ctx),
                            child: const Text('Hủy'),
                          ),
                          TextButton(
                            onPressed: () =>
                                Navigator.pop(ctx, collection.trim()),
                            child: const Text('Lưu'),
                          ),
                        ],
                      ),
                    );
                    if (name != null) {
                      await vm.updateMetadata(book.id, collection: name);
                    }
                  } else if (v == 'completed') {
                    await vm.updateMetadata(
                      book.id,
                      completed: !book.completed,
                    );
                  } else {
                    if (!context.mounted) return;
                    final yes = await showDialog<bool>(
                      context: context,
                      builder: (ctx) => AlertDialog(
                        title: const Text('Xóa khỏi thư viện?'),
                        content: const Text(
                          'Nội dung đã tải của sách này cũng sẽ được xóa.',
                        ),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(ctx, false),
                            child: const Text('Hủy'),
                          ),
                          TextButton(
                            onPressed: () => Navigator.pop(ctx, true),
                            child: const Text('Xóa'),
                          ),
                        ],
                      ),
                    );
                    if (yes == true && context.mounted) {
                      await vm.remove(book.id);
                      if (context.mounted) context.pop();
                    }
                  }
                },
                itemBuilder: (_) => [
                  const PopupMenuItem(
                    value: 'collection',
                    child: Text('Đổi bộ sưu tập'),
                  ),
                  PopupMenuItem(
                    value: 'completed',
                    child: Text(
                      book.completed
                          ? 'Đánh dấu chưa hoàn thành'
                          : 'Đánh dấu hoàn thành',
                    ),
                  ),
                  const PopupMenuItem(
                    value: 'remove',
                    child: Text('Xóa khỏi thư viện'),
                  ),
                ],
              ),
            ],
          ),
          body: ListView(
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 112,
                      height: 165,
                      child: BookCover(
                        title: book.title,
                        cover: book.cover,
                        kind: book.kind,
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            book.title,
                            style: const TextStyle(
                              fontSize: 23,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 8),
                          if (book.author.isNotEmpty)
                            Text(
                              book.author,
                              style: const TextStyle(color: Colors.grey),
                            ),
                          const SizedBox(height: 12),
                          Text(
                            '${book.kind == 'manga' ? 'Truyện tranh' : 'Truyện chữ / Ebook'} · ${book.chapters.length} chương',
                          ),
                          const SizedBox(height: 8),
                          Text(
                            book.engine == 'local'
                                ? 'Trong thiết bị'
                                : book.engine == 'vbook'
                                ? 'vBook'
                                : 'Tachimanga',
                          ),
                          const SizedBox(height: 10),
                          Text(
                            '${(book.progress * 100).round()}% đã đọc',
                            style: const TextStyle(color: Colors.grey),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  children: [
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: book.chapters.isEmpty
                            ? null
                            : () => context.push(
                                '/read/${book.id}?chapter=${book.currentChapter}',
                              ),
                        icon: const Icon(CupertinoIcons.book),
                        label: Text(
                          book.lastRead == null ? 'Bắt đầu đọc' : 'Đọc tiếp',
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Yêu thích',
                      onPressed: () =>
                          vm.updateMetadata(book.id, favorite: !book.favorite),
                      icon: Icon(
                        book.favorite
                            ? CupertinoIcons.heart_fill
                            : CupertinoIcons.heart,
                        color: book.favorite ? Colors.red : null,
                      ),
                    ),
                    if (book.engine != 'local')
                      IconButton(
                        tooltip: 'Tải 10 chương tiếp theo',
                        onPressed: downloading
                            ? null
                            : () async {
                                setState(() => downloading = true);
                                await perform(context, () async {
                                  for (
                                    var i = book.currentChapter;
                                    i < book.chapters.length &&
                                        i < book.currentChapter + 10;
                                    i++
                                  ) {
                                    await vm.getContent(
                                      book,
                                      i,
                                      download: true,
                                    );
                                  }
                                }, success: 'Đã tải các chương tiếp theo');
                                if (mounted) {
                                  setState(() => downloading = false);
                                }
                              },
                        icon: downloading
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(CupertinoIcons.arrow_down_circle),
                      ),
                  ],
                ),
              ),
              if (book.description.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    book.description,
                    style: const TextStyle(height: 1.5),
                  ),
                ),
              const Divider(),
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                child: Text(
                  'Chương (${book.chapters.length})',
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              ...List.generate(
                book.chapters.length,
                (i) => ListTile(
                  dense: true,
                  title: Text(book.chapters[i].title),
                  leading: Icon(
                    i < book.currentChapter || book.completed
                        ? CupertinoIcons.checkmark_circle_fill
                        : CupertinoIcons.circle,
                    size: 20,
                    color: i < book.currentChapter || book.completed
                        ? Colors.grey
                        : Theme.of(context).colorScheme.primary,
                  ),
                  trailing: Icon(
                    book.chapters[i].downloaded
                        ? CupertinoIcons.arrow_down_circle_fill
                        : CupertinoIcons.chevron_right,
                    size: 18,
                    color: book.chapters[i].downloaded
                        ? Colors.green
                        : Colors.grey,
                  ),
                  onTap: () => context.push('/read/${book.id}?chapter=$i'),
                ),
              ),
              const SizedBox(height: 30),
            ],
          ),
        );
      },
    );
  }
}
