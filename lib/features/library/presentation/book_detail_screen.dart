import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/widgets/book_cover.dart';
import '../../../core/widgets/feedback.dart';
import '../../downloads/presentation/download_queue_controller.dart';
import '../domain/library_book.dart';
import '../domain/library_reading.dart';
import 'chapter_options_sheet.dart';
import 'library_view_model.dart';

class BookDetailScreen extends ConsumerStatefulWidget {
  const BookDetailScreen({super.key, required this.id});
  final String id;
  @override
  ConsumerState<BookDetailScreen> createState() => _BookDetailState();
}

class _BookDetailState extends ConsumerState<BookDetailScreen> {
  final search = TextEditingController();
  bool downloading = false, searching = false, newestFirst = false;
  String readingFilter = 'all', downloadFilter = 'all';

  @override
  void dispose() {
    search.dispose();
    super.dispose();
  }

  Future<void> bookActions(LibraryBook book) async {
    final action = await showCupertinoModalPopup<String>(
      context: context,
      builder: (ctx) => CupertinoActionSheet(
        actions: [
          CupertinoActionSheetAction(
            onPressed: () => Navigator.pop(ctx, 'collection'),
            child: const Text('Đổi bộ sưu tập'),
          ),
          CupertinoActionSheetAction(
            onPressed: () => Navigator.pop(ctx, 'completed'),
            child: Text(
              book.completed
                  ? 'Đánh dấu chưa hoàn thành'
                  : 'Đánh dấu hoàn thành',
            ),
          ),
          CupertinoActionSheetAction(
            onPressed: () => Navigator.pop(ctx, 'notes'),
            child: const Text('Ghi chú cá nhân'),
          ),
          CupertinoActionSheetAction(
            isDestructiveAction: true,
            onPressed: () => Navigator.pop(ctx, 'remove'),
            child: const Text('Xóa khỏi thư viện'),
          ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('Hủy'),
        ),
      ),
    );
    if (action == null || !mounted) return;
    final vm = ref.read(libraryProvider.notifier);
    if (action == 'collection') {
      var collection = book.collection;
      final name = await showCupertinoDialog<String>(
        context: context,
        builder: (ctx) => CupertinoAlertDialog(
          title: const Text('Bộ sưu tập'),
          content: Padding(
            padding: const EdgeInsets.only(top: 12),
            child: CupertinoTextFormFieldRow(
              initialValue: collection,
              padding: EdgeInsets.zero,
              placeholder: 'Tên bộ sưu tập',
              onChanged: (value) => collection = value,
            ),
          ),
          actions: [
            CupertinoDialogAction(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Hủy'),
            ),
            CupertinoDialogAction(
              isDefaultAction: true,
              onPressed: () => Navigator.pop(ctx, collection.trim()),
              child: const Text('Lưu'),
            ),
          ],
        ),
      );
      if (name != null && mounted) {
        await perform(
          context,
          () => vm.updateMetadata(book.id, collection: name),
        );
      }
    } else if (action == 'completed') {
      await perform(
        context,
        () => vm.updateMetadata(book.id, completed: !book.completed),
      );
    } else if (action == 'notes') {
      await editNotes(book);
    } else {
      final yes = await showCupertinoDialog<bool>(
        context: context,
        builder: (ctx) => CupertinoAlertDialog(
          title: const Text('Xóa khỏi thư viện?'),
          content: const Text('Nội dung đã tải của sách này cũng sẽ được xóa.'),
          actions: [
            CupertinoDialogAction(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Hủy'),
            ),
            CupertinoDialogAction(
              isDestructiveAction: true,
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Xóa'),
            ),
          ],
        ),
      );
      if (yes == true && mounted) {
        await perform(context, () async {
          await vm.remove(book.id);
          if (mounted) context.pop();
        });
      }
    }
  }

  Future<void> editNotes(LibraryBook book) async {
    final controller = TextEditingController(text: book.notes);
    try {
      final notes = await showCupertinoDialog<String>(
        context: context,
        builder: (ctx) => CupertinoAlertDialog(
          title: const Text('Ghi chú cá nhân'),
          content: Padding(
            padding: const EdgeInsets.only(top: 12),
            child: CupertinoTextField(
              controller: controller,
              placeholder: 'Ghi chú về truyện này',
              minLines: 4,
              maxLines: 8,
              maxLength: 20000,
              textAlignVertical: TextAlignVertical.top,
            ),
          ),
          actions: [
            CupertinoDialogAction(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Hủy'),
            ),
            CupertinoDialogAction(
              isDefaultAction: true,
              onPressed: () => Navigator.pop(ctx, controller.text),
              child: const Text('Lưu'),
            ),
          ],
        ),
      );
      if (notes != null && mounted) {
        await perform(
          context,
          () => ref
              .read(libraryProvider.notifier)
              .updateMetadata(book.id, notes: notes),
        );
      }
    } finally {
      controller.dispose();
    }
  }

  Future<void> downloadChapters(LibraryBook book) async {
    final count = await showCupertinoModalPopup<int>(
      context: context,
      builder: (ctx) => CupertinoActionSheet(
        title: const Text('Tải chương'),
        actions: [
          CupertinoActionSheetAction(
            onPressed: () => Navigator.pop(ctx, 10),
            child: const Text('10 chương tiếp theo'),
          ),
          CupertinoActionSheetAction(
            onPressed: () => Navigator.pop(ctx, -1),
            child: const Text('Tất cả chương chưa tải'),
          ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('Hủy'),
        ),
      ),
    );
    if (count == null || !mounted) return;
    setState(() => downloading = true);
    await perform(context, () async {
      final start = count == 10
          ? book.currentChapter.clamp(0, book.chapters.length)
          : 0;
      final end = count == 10
          ? (start + count).clamp(0, book.chapters.length)
          : book.chapters.length;
      final queue = ref.read(downloadQueueProvider.notifier);
      await queue.enqueue(book.id, [
        for (var i = start; i < end; i++)
          if (!book.chapters[i].downloaded) book.chapters[i].id,
      ]);
      await queue.start();
    }, success: 'Đã thêm vào hàng đợi tải');
    if (mounted) setState(() => downloading = false);
  }

  Future<void> chapterOptions() => showChapterOptions(
    context,
    readingFilter: readingFilter,
    downloadFilter: downloadFilter,
    newestFirst: newestFirst,
    onReadFilter: (value) => setState(() => readingFilter = value),
    onDownloadFilter: (value) => setState(() => downloadFilter = value),
    onSort: (value) => setState(() => newestFirst = value),
  );

  Future<void> chapterActions(LibraryBook book, int index) async {
    final chapter = book.chapters[index];
    final read = chapterIsRead(book, index);
    final revision = ref.read(libraryRepositoryProvider).replacementRevision;
    final selected = await showCupertinoModalPopup<bool>(
      context: context,
      builder: (ctx) => CupertinoActionSheet(
        title: Text(chapter.title),
        actions: [
          CupertinoActionSheetAction(
            onPressed: () => Navigator.pop(ctx, !read),
            child: Text(read ? 'Đánh dấu chưa đọc' : 'Đánh dấu đã đọc'),
          ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('Hủy'),
        ),
      ),
    );
    if (selected == null || !mounted) return;
    await perform(
      context,
      () => ref
          .read(libraryProvider.notifier)
          .markChapterRead(
            book.id,
            chapter.id,
            selected,
            expectedRevision: revision,
          ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(libraryProvider);
    return state.when(
      loading: () =>
          const Scaffold(body: Center(child: CupertinoActivityIndicator())),
      error: (e, _) => Scaffold(
        appBar: AppBar(title: const Text('Chi tiết')),
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
        final primary = Theme.of(context).colorScheme.primary;
        final secondary = CupertinoDynamicColor.resolve(
          CupertinoColors.secondaryLabel,
          context,
        );
        final separator = CupertinoDynamicColor.resolve(
          CupertinoColors.separator,
          context,
        );
        final query = search.text.trim().toLowerCase();
        final indices = [
          for (var i = 0; i < book.chapters.length; i++)
            if ((query.isEmpty ||
                    book.chapters[i].title.toLowerCase().contains(query)) &&
                (readingFilter == 'all' ||
                    (readingFilter == 'read') == chapterIsRead(book, i)) &&
                (downloadFilter == 'all' ||
                    (downloadFilter == 'downloaded') ==
                        book.chapters[i].downloaded))
              i,
        ];
        if (newestFirst) indices.sort((a, b) => b.compareTo(a));
        final headerCount = searching ? 3 : 2;
        return Scaffold(
          appBar: AppBar(
            title: const Text('Chi tiết'),
            actions: [
              IconButton(
                tooltip: 'Tùy chọn',
                icon: const Icon(CupertinoIcons.ellipsis),
                onPressed: () => bookActions(book),
              ),
            ],
          ),
          body: SafeArea(
            top: false,
            bottom: false,
            child: ListView.builder(
              itemCount: headerCount + (indices.isEmpty ? 1 : indices.length),
              itemBuilder: (context, row) {
                if (row == 0) {
                  return Padding(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            SizedBox(
                              width: 106,
                              height: 156,
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
                                      fontSize: 22,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  if (book.author.isNotEmpty) ...[
                                    const SizedBox(height: 7),
                                    Text(
                                      book.author,
                                      style: TextStyle(
                                        fontSize: 15,
                                        color: secondary,
                                      ),
                                    ),
                                  ],
                                  const SizedBox(height: 12),
                                  Text(
                                    book.kind == 'manga'
                                        ? 'Truyện tranh'
                                        : 'Truyện chữ / Ebook',
                                    style: const TextStyle(fontSize: 13),
                                  ),
                                  const SizedBox(height: 5),
                                  Text(
                                    book.engine == 'local'
                                        ? 'Trong thiết bị'
                                        : book.engine == 'vbook'
                                        ? 'vBook'
                                        : 'Tachimanga',
                                    style: TextStyle(
                                      fontSize: 13,
                                      color: secondary,
                                    ),
                                  ),
                                  const SizedBox(height: 5),
                                  Text(
                                    '${(book.progress * 100).round()}% đã đọc',
                                    style: TextStyle(
                                      fontSize: 13,
                                      color: secondary,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 16),
                        Row(
                          children: [
                            Expanded(
                              child: CupertinoButton.filled(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 10,
                                ),
                                borderRadius: BorderRadius.circular(8),
                                onPressed: book.chapters.isEmpty
                                    ? null
                                    : () => context.push(
                                        '/read/${book.id}?chapter=${book.currentChapter}',
                                      ),
                                child: Text(
                                  book.lastRead == null
                                      ? 'Bắt đầu đọc'
                                      : 'Đọc tiếp',
                                  style: const TextStyle(
                                    fontSize: 15,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            IconButton(
                              tooltip: 'Yêu thích',
                              color: primary,
                              icon: Icon(
                                book.favorite
                                    ? CupertinoIcons.heart_fill
                                    : CupertinoIcons.heart,
                              ),
                              onPressed: () => perform(
                                context,
                                () => ref
                                    .read(libraryProvider.notifier)
                                    .updateMetadata(
                                      book.id,
                                      favorite: !book.favorite,
                                    ),
                              ),
                            ),
                          ],
                        ),
                        if (book.artist.isNotEmpty) ...[
                          const SizedBox(height: 12),
                          Text(
                            'Họa sĩ: ${book.artist}',
                            style: TextStyle(color: secondary, fontSize: 14),
                          ),
                        ],
                        if (book.genres.isNotEmpty) ...[
                          const SizedBox(height: 8),
                          Text(
                            book.genres.join(' · '),
                            style: TextStyle(color: secondary, fontSize: 14),
                          ),
                        ],
                        if (book.description.isNotEmpty) ...[
                          const SizedBox(height: 16),
                          Text(
                            book.description,
                            style: const TextStyle(fontSize: 15, height: 1.4),
                          ),
                        ],
                        if (book.notes.isNotEmpty) ...[
                          const SizedBox(height: 12),
                          GestureDetector(
                            onTap: () => editNotes(book),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Ghi chú cá nhân',
                                  style: TextStyle(
                                    color: primary,
                                    fontSize: 14,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  book.notes,
                                  maxLines: 4,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontSize: 14,
                                    height: 1.4,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ],
                    ),
                  );
                }
                if (row == 1) {
                  return Container(
                    decoration: BoxDecoration(
                      border: Border(
                        top: BorderSide(color: separator, width: .5),
                        bottom: BorderSide(color: separator, width: .5),
                      ),
                    ),
                    padding: const EdgeInsets.only(left: 16, right: 4),
                    child: SizedBox(
                      height: 44,
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              '${book.chapters.length} chương',
                              style: const TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          IconButton(
                            tooltip: 'Tìm chương',
                            icon: const Icon(CupertinoIcons.search, size: 20),
                            color: primary,
                            onPressed: () => setState(() {
                              searching = !searching;
                              if (!searching) search.clear();
                            }),
                          ),
                          IconButton(
                            tooltip: 'Tải chương',
                            color: primary,
                            onPressed:
                                book.engine == 'local' ||
                                    downloading ||
                                    book.chapters.isEmpty
                                ? null
                                : () => downloadChapters(book),
                            icon: downloading
                                ? const CupertinoActivityIndicator(radius: 9)
                                : const Icon(
                                    CupertinoIcons.arrow_down,
                                    size: 22,
                                  ),
                          ),
                          IconButton(
                            tooltip: 'Lọc và sắp xếp chương',
                            color: primary,
                            onPressed: chapterOptions,
                            icon: const Icon(
                              CupertinoIcons.line_horizontal_3_decrease,
                              size: 22,
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                }
                if (searching && row == 2) {
                  return Padding(
                    padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
                    child: CupertinoSearchTextField(
                      controller: search,
                      placeholder: 'Tìm chương',
                      onChanged: (_) => setState(() {}),
                    ),
                  );
                }
                if (indices.isEmpty) {
                  return Padding(
                    padding: const EdgeInsets.all(24),
                    child: Center(
                      child: Text(
                        'Không có chương phù hợp',
                        style: TextStyle(color: secondary, fontSize: 15),
                      ),
                    ),
                  );
                }
                final index = indices[row - headerCount];
                final chapter = book.chapters[index];
                final read = chapterIsRead(book, index);
                return Column(
                  children: [
                    ListTile(
                      minTileHeight: 54,
                      contentPadding: const EdgeInsets.only(left: 16, right: 8),
                      title: Text(
                        chapter.title,
                        style: TextStyle(
                          fontSize: 15,
                          color: read ? secondary : null,
                        ),
                      ),
                      subtitle:
                          book.lastRead != null &&
                              index == book.currentChapter &&
                              !read
                          ? Text(
                              'Đang đọc',
                              style: TextStyle(fontSize: 12, color: secondary),
                            )
                          : null,
                      trailing: chapter.downloaded
                          ? Padding(
                              padding: const EdgeInsets.all(12),
                              child: Icon(
                                CupertinoIcons.checkmark_circle_fill,
                                size: 20,
                                color: secondary,
                              ),
                            )
                          : book.engine == 'local'
                          ? null
                          : IconButton(
                              tooltip: 'Tải ${chapter.title}',
                              icon: const Icon(
                                CupertinoIcons.arrow_down_circle,
                                size: 22,
                              ),
                              color: primary,
                              onPressed: downloading
                                  ? null
                                  : () async {
                                      setState(() => downloading = true);
                                      await perform(context, () async {
                                        final queue = ref.read(
                                          downloadQueueProvider.notifier,
                                        );
                                        await queue.enqueue(book.id, [
                                          chapter.id,
                                        ]);
                                        await queue.start();
                                      });
                                      if (mounted) {
                                        setState(() => downloading = false);
                                      }
                                    },
                            ),
                      onTap: () =>
                          context.push('/read/${book.id}?chapter=$index'),
                      onLongPress: () => chapterActions(book, index),
                    ),
                    Padding(
                      padding: const EdgeInsets.only(left: 16),
                      child: Divider(
                        height: .5,
                        thickness: .5,
                        color: separator,
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        );
      },
    );
  }
}
