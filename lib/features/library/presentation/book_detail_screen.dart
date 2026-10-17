import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/widgets/feedback.dart';
import '../../../core/platform/book_cover_platform.dart';
import '../data/library_mutation.dart';
import '../application/book_cover_import.dart';
import '../../downloads/presentation/download_queue_controller.dart';
import '../../downloads/presentation/download_actions.dart';
import '../../reader/presentation/reader_advanced_settings.dart';
import '../../sources/domain/catalogue.dart';
import '../../sources/presentation/global_search_screen.dart';
import '../../sources/presentation/source_cover_image.dart';
import '../../sources/presentation/source_migration_view.dart';
import '../../deep_links/domain/app_deep_link.dart';
import 'library_group_dialog.dart';
import 'library_category_controller.dart';
import '../domain/library_grouping.dart';
import '../domain/library_book.dart';
import '../domain/library_reading.dart';
import '../domain/chapter_list_options.dart';
import 'book_detail_header.dart';
import 'book_metadata_editor.dart';
import 'chapter_options_sheet.dart';
import 'chapter_range_dialog.dart';
import 'library_view_model.dart';
import 'library_locations.dart';
import 'library_source_label.dart';
import '../../../core/diagnostics/diagnostic_log.dart';

class BookDetailScreen extends ConsumerStatefulWidget {
  const BookDetailScreen({super.key, required this.id, this.expectedRevision});
  final String id;
  final int? expectedRevision;
  @override
  ConsumerState<BookDetailScreen> createState() => _BookDetailState();
}

class _BookDetailState extends ConsumerState<BookDetailScreen> {
  final search = TextEditingController();
  bool downloading = false, searching = false, selecting = false;
  bool descriptionExpanded = false;
  ChapterListOptions options = const ChapterListOptions();
  String? optionsBook;
  int? optionsRevision;
  final selectedIds = <String>{};
  int? selectionRevision;
  String? metadataRequest;

  @override
  void dispose() {
    search.dispose();
    super.dispose();
  }

  Future<void> copySource(LibraryBook book) => perform(
    context,
    () => Clipboard.setData(ClipboardData(text: book.sourceRef)),
    success: 'Đã sao chép địa chỉ nguồn',
  );

  Future<List<CatalogueSource>> availableSources() async {
    final repository = ref.read(sourceRepositoryProvider);
    final values = await Future.wait([
      for (final engine in SourceEngine.values)
        repository
            .listSources(engine)
            .catchError((Object error) => <CatalogueSource>[]),
    ]);
    final result = values.expand((items) => items).toList();
    if (result.isEmpty) {
      throw StateError(
        'Chưa tải được danh sách nguồn. Hãy kiểm tra extension đã cài trong Duyệt.',
      );
    }
    return result;
  }

  Future<void> searchMetadata(String query) => perform(context, () async {
    final sources = await availableSources();
    if (!mounted) return;
    await Navigator.of(context).push(
      CupertinoPageRoute(
        builder: (_) =>
            GlobalSearchScreen(sources: sources, initialQuery: query),
      ),
    );
  });

  Future<void> bookActions(LibraryBook book) async {
    final revision = ref.read(libraryRepositoryProvider).replacementRevision;
    final action = await showCupertinoModalPopup<String>(
      context: context,
      builder: (ctx) => CupertinoActionSheet(
        actions: [
          for (final pair in const {
            'copy-link': 'Sao chép liên kết TachiBooks',
            'metadata': 'Sửa thông tin và tên khác',
            'cover': 'Chỉnh sửa ảnh bìa',
            'categories': 'Gán nhiều danh mục',
            'reader': 'Thiết lập đọc riêng',
            'reset-reader': 'Đặt lại thiết lập đọc riêng',
            'next-downloads': 'Tải các chương tiếp theo',
            'cbz': 'Xuất chương đã tải thành CBZ',
            'select': 'Chọn nhiều chương',
            'refresh': 'Làm mới thông tin và chương',
            'reset': 'Đặt lại trạng thái đọc',
            'first': 'Đọc chương đầu tiên',
          }.entries)
            CupertinoActionSheetAction(
              onPressed: () => Navigator.pop(ctx, pair.key),
              child: Text(pair.value),
            ),
          if (book.sourceRef.startsWith('https://') ||
              book.sourceRef.startsWith('http://')) ...[
            CupertinoActionSheetAction(
              onPressed: () => Navigator.pop(ctx, 'copy-source'),
              child: const Text('Sao chép liên kết gốc'),
            ),
            CupertinoActionSheetAction(
              onPressed: () => Navigator.pop(ctx, 'share-source'),
              child: const Text('Chia sẻ liên kết gốc'),
            ),
          ],
          if (book.engine != 'local') ...[
            CupertinoActionSheetAction(
              onPressed: () => Navigator.pop(ctx, 'refresh-info'),
              child: const Text('Làm mới thông tin truyện'),
            ),
            CupertinoActionSheetAction(
              onPressed: () => Navigator.pop(ctx, 'refresh-chapters'),
              child: const Text('Làm mới danh sách chương'),
            ),
          ],
          if (book.chapters.isNotEmpty)
            CupertinoActionSheetAction(
              onPressed: () => Navigator.pop(ctx, 'copy-reading-link'),
              child: const Text('Sao chép liên kết chương đang đọc'),
            ),
          if (book.engine != 'local')
            CupertinoActionSheetAction(
              onPressed: () => Navigator.pop(ctx, 'migrate'),
              child: const Text('Chuyển nguồn truyện'),
            ),
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
    if (action == 'metadata') {
      final edit = await showBookMetadataEditor(context, book);
      if (edit != null && mounted) {
        await perform(
          context,
          () => vm.updateMetadata(
            book.id,
            title: edit.title,
            alternativeTitles: edit.alternativeTitles,
            author: edit.author,
            artist: edit.artist,
            series: edit.series,
            description: edit.description,
            notes: edit.notes,
            expectedRevision: revision,
          ),
          success: 'Đã lưu thông tin truyện',
        );
      }
    } else if (action == 'cover') {
      await editCover(book, revision);
    } else if (action == 'copy-source') {
      await copySource(book);
    } else if (action == 'share-source') {
      await perform(context, () => BookCoverPlatform.shareLink(book.sourceRef));
    } else if (action == 'refresh-info') {
      await perform(
        context,
        () => vm.refreshBookDetail(
          book.id,
          expectedRevision: revision,
          refreshChapters: false,
        ),
        success: 'Đã cập nhật thông tin truyện',
      );
    } else if (action == 'refresh-chapters') {
      await perform(context, () async {
        final result = await vm.updateBooks([
          book.id,
        ], expectedRevision: revision);
        if (result.hasErrors) throw StateError(result.failures.first.message);
      }, success: 'Đã cập nhật danh sách chương');
    } else if (action == 'reset-reader') {
      await perform(
        context,
        () => vm.updateReaderPreferences(
          book.id,
          const {},
          expectedRevision: revision,
        ),
        success: 'Truyện dùng thiết lập đọc chung',
      );
    } else if (action == 'copy-link' || action == 'copy-reading-link') {
      await perform(
        context,
        () async {
          final repository = ref.read(libraryRepositoryProvider);
          final current = await repository.find(book.id);
          if (current == null || repository.replacementRevision != revision) {
            throw StateError(
              'Thư viện đã thay đổi. Hãy mở lại truyện để sao chép liên kết.',
            );
          }
          final reading = action == 'copy-reading-link';
          if (reading && current.chapters.isEmpty) {
            throw StateError('Truyện chưa có chương để tạo liên kết đọc.');
          }
          final link = LibraryDeepLink(
            current.id,
            reader: reading,
            chapterId: reading
                ? current
                      .chapters[current.currentChapter.clamp(
                        0,
                        current.chapters.length - 1,
                      )]
                      .id
                : null,
          );
          await Clipboard.setData(ClipboardData(text: link.identity));
        },
        success: 'Đã sao chép liên kết. Máy mở liên kết cần có truyện này trong thư viện.',
      );
    } else if (action == 'categories') {
      final books = ref.read(libraryProvider).value ?? [];
      final edit = await showLibraryGroupDialog(
        context,
        books: books,
        selectedIds: {book.id},
        grouping: LibraryGrouping.collection,
        availableCategories: ref
            .read(libraryCategoriesProvider)
            .all(books)
            .map((category) => category.name)
            .toList(),
        initialMultipleCategories: true,
      );
      if (edit != null && mounted) {
        await perform(
          context,
          () => vm.groupBooks(
            [book.id],
            collection: edit.categories == null ? edit.value : null,
            categories: edit.categories,
            expectedRevision: revision,
          ),
        );
      }
    } else if (action == 'reader') {
      await showAdvancedReaderSettings(
        context,
        book: book,
        expectedRevision: revision,
      );
    } else if (action == 'next-downloads') {
      await enqueueNextDownloads(
        context,
        ref,
        book,
        expectedRevision: revision,
      );
    } else if (action == 'cbz') {
      await saveDownloadedCbz(context, ref, book, expectedRevision: revision);
    } else if (action == 'select') {
      beginSelection();
    } else if (action == 'refresh') {
      await perform(
        context,
        () => vm.refreshBookDetail(book.id, expectedRevision: revision),
        success: 'Đã cập nhật truyện',
      );
    } else if (action == 'reset') {
      await resetReading(book, revision);
    } else if (action == 'first') {
      if (book.chapters.isNotEmpty) {
        context.push(libraryReaderLocation(book, 0));
      }
    } else if (action == 'migrate') {
      await perform(context, () async {
        final sources = await availableSources();
        if (!mounted) return;
        await SourceMigrationView(
          sources: sources,
          onOpenSource: (_) async {},
          query: '',
        ).chooseSource(context, book);
      });
    } else if (action == 'collection') {
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
          () => vm.updateMetadata(
            book.id,
            collection: name,
            expectedRevision: revision,
          ),
        );
      }
    } else if (action == 'completed') {
      await perform(
        context,
        () => vm.updateMetadata(
          book.id,
          completed: !book.completed,
          expectedRevision: revision,
        ),
      );
    } else if (action == 'notes') {
      await editNotes(book, expectedRevision: revision);
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
          await vm.remove(book.id, expectedRevision: revision);
          if (mounted) context.pop();
        });
      }
    }
  }

  Future<void> editCover(LibraryBook book, int revision) async {
    final action = await showCupertinoModalPopup<String>(
      context: context,
      builder: (ctx) => CupertinoActionSheet(
        title: const Text('Ảnh bìa'),
        actions: [
          CupertinoActionSheetAction(
            onPressed: () => Navigator.pop(ctx, 'photos'),
            child: const Text('Chọn từ Ảnh'),
          ),
          CupertinoActionSheetAction(
            onPressed: () => Navigator.pop(ctx, 'files'),
            child: const Text('Chọn từ Tệp'),
          ),
          if (book.chapters.isNotEmpty)
            CupertinoActionSheetAction(
              onPressed: () => Navigator.pop(ctx, 'page'),
              child: const Text('Sử dụng trang truyện làm bìa'),
            ),
          if (book.customCover)
            CupertinoActionSheetAction(
              onPressed: () => Navigator.pop(ctx, 'restore'),
              child: const Text('Khôi phục bìa gốc'),
            ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('Hủy'),
        ),
      ),
    );
    if (action == null || !mounted) return;
    if (action == 'page') {
      if (ref.read(libraryRepositoryProvider).replacementRevision != revision) {
        message(context, 'Thư viện đã thay đổi. Hãy mở lại truyện.');
        return;
      }
      message(context, 'Nhấn giữ trang truyện, chọn Đặt làm ảnh bìa.');
      context.push(
        libraryReaderLocation(
          book,
          book.currentChapter.clamp(0, book.chapters.length - 1),
        ),
      );
      return;
    }
    await perform(context, () async {
      final cover = action == 'restore'
          ? null
          : await chooseBookCover(fromPhotos: action == 'photos');
      if (action != 'restore' && cover == null) return;
      await ref
          .read(libraryProvider.notifier)
          .updateMetadata(
            book.id,
            cover: cover,
            restoreOriginalCover: action == 'restore',
            expectedRevision: revision,
          );
      if (mounted) message(context, 'Đã cập nhật ảnh bìa');
    });
  }

  Future<void> editNotes(LibraryBook book, {int? expectedRevision}) async {
    final revision =
        expectedRevision ??
        ref.read(libraryRepositoryProvider).replacementRevision;
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
            if (book.notes.isNotEmpty)
              CupertinoDialogAction(
                isDestructiveAction: true,
                onPressed: () => Navigator.pop(ctx, ''),
                child: const Text('Xóa ghi chú'),
              ),
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
              .updateMetadata(
                book.id,
                notes: notes,
                expectedRevision: revision,
              ),
        );
      }
    } finally {
      controller.dispose();
    }
  }

  Future<void> downloadChapters(LibraryBook book) async {
    final revision = ref.read(libraryRepositoryProvider).replacementRevision;
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
      ], expectedRevision: revision);
      await queue.start();
    }, success: 'Đã thêm vào hàng đợi tải');
    if (mounted) setState(() => downloading = false);
  }

  Future<void> chapterOptions(LibraryBook book) {
    final revision = ref.read(libraryRepositoryProvider).replacementRevision;
    return showChapterOptions(
      context,
      options: options,
      scanlators:
          book.chapters
              .map((chapter) => chapter.scanlator)
              .where((name) => name.isNotEmpty)
              .toSet()
              .toList()
            ..sort(),
      onChanged: (value) {
        perform(context, () async {
          await ref
              .read(libraryProvider.notifier)
              .updateChapterListPreferences(
                book.id,
                value.toJson(),
                expectedRevision: revision,
              );
          if (mounted &&
              ref.read(libraryRepositoryProvider).replacementRevision ==
                  revision) {
            setState(() => options = value);
          }
        });
      },
    );
  }

  void beginSelection([String? chapterId]) => setState(() {
    if (!selecting) {
      selectionRevision = ref
          .read(libraryRepositoryProvider)
          .replacementRevision;
    }
    selecting = true;
    if (chapterId != null) selectedIds.add(chapterId);
  });
  void endSelection() => setState(() {
    selecting = false;
    selectedIds.clear();
    selectionRevision = null;
  });

  Future<void> selectChapterRange(LibraryBook book, List<int> indices) async {
    final revision = selectionRevision;
    if (revision == null) return;
    final ids = await showChapterRangeDialog(context, [
      for (final index in indices) book.chapters[index],
    ]);
    if (ids == null || !mounted) return;
    await perform(context, () async {
      checkLibraryRevision(
        ref.read(libraryRepositoryProvider).replacementRevision,
        revision,
      );
      setState(() => selectedIds.addAll(ids));
    });
  }

  Future<void> resetReading(LibraryBook book, int revision) async {
    final yes = await showCupertinoDialog<bool>(
      context: context,
      builder: (ctx) => CupertinoAlertDialog(
        title: const Text('Đặt lại trạng thái đọc?'),
        content: const Text(
          'Các chương sẽ thành chưa đọc và vị trí đọc về đầu. Dấu trang và nội dung tải được giữ.',
        ),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Hủy'),
          ),
          CupertinoDialogAction(
            isDestructiveAction: true,
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Đặt lại'),
          ),
        ],
      ),
    );
    if (yes == true && mounted) {
      await perform(
        context,
        () => ref
            .read(libraryProvider.notifier)
            .resetBookReading(book.id, expectedRevision: revision),
      );
    }
  }

  Future<void> batchAction(LibraryBook book, String action) async {
    final ids = selectedIds.toSet(), revision = selectionRevision;
    if (ids.isEmpty || revision == null) return;
    if (action == 'delete') {
      await deleteDownloadedChapters(
        context,
        ref,
        book,
        ids,
        expectedRevision: revision,
      );
      return;
    } else {
      await perform(context, () async {
        final vm = ref.read(libraryProvider.notifier);
        if (action == 'read' || action == 'unread') {
          await vm.markChaptersRead(
            book.id,
            ids,
            action == 'read',
            expectedRevision: revision,
          );
        } else if (action == 'bookmark' || action == 'unbookmark') {
          await vm.setChapterBookmarks(
            book.id,
            ids,
            action == 'bookmark',
            expectedRevision: revision,
          );
        } else if (action == 'download') {
          final queue = ref.read(downloadQueueProvider.notifier);
          await queue.enqueue(
            book.id,
            ids.toList(),
            expectedRevision: revision,
          );
          await queue.start();
        } else if (action == 'cbz') {
          await saveDownloadedCbz(
            context,
            ref,
            book,
            expectedRevision: revision,
            chapterIds: ids,
          );
        }
      });
    }
    if (mounted) endSelection();
  }

  Future<void> chapterActions(LibraryBook book, int index) async {
    final chapter = book.chapters[index];
    final read = chapterIsRead(book, index);
    final revision = ref.read(libraryRepositoryProvider).replacementRevision;
    final selected = await showCupertinoModalPopup<String>(
      context: context,
      builder: (ctx) => CupertinoActionSheet(
        title: Text(chapter.title),
        actions: [
          CupertinoActionSheetAction(
            onPressed: () => Navigator.pop(ctx, read ? 'unread' : 'read'),
            child: Text(read ? 'Đánh dấu chưa đọc' : 'Đánh dấu đã đọc'),
          ),
          CupertinoActionSheetAction(
            onPressed: () => Navigator.pop(ctx, 'previous'),
            child: const Text('Đánh dấu các chương trước đã đọc'),
          ),
          CupertinoActionSheetAction(
            onPressed: () => Navigator.pop(ctx, 'bookmark'),
            child: Text(
              chapterHasBookmark(book, index)
                  ? 'Bỏ dấu trang chương'
                  : 'Đánh dấu chương',
            ),
          ),
          CupertinoActionSheetAction(
            onPressed: () => Navigator.pop(ctx, 'select'),
            child: const Text('Chọn nhiều chương'),
          ),
          if (chapter.downloaded && book.engine != 'local')
            CupertinoActionSheetAction(
              onPressed: () => Navigator.pop(ctx, 'delete'),
              isDestructiveAction: true,
              child: const Text('Xóa chương đã tải'),
            ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('Hủy'),
        ),
      ),
    );
    if (selected == null || !mounted) return;
    if (selected == 'select') {
      beginSelection(chapter.id);
      return;
    }
    if (selected == 'delete') {
      await deleteDownloadedChapters(context, ref, book, [
        chapter.id,
      ], expectedRevision: revision);
      return;
    }
    if (selected == 'bookmark') {
      await perform(
        context,
        () => ref
            .read(libraryProvider.notifier)
            .setChapterBookmarks(
              book.id,
              [chapter.id],
              !chapterHasBookmark(book, index),
              expectedRevision: revision,
            ),
      );
      return;
    }
    await perform(
      context,
      () => ref
          .read(libraryProvider.notifier)
          .markChaptersRead(
            book.id,
            selected == 'previous'
                ? book.chapters.take(index).map((c) => c.id)
                : [chapter.id],
            selected != 'unread',
            expectedRevision: revision,
          ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(libraryProvider);
    if (widget.expectedRevision != null &&
        widget.expectedRevision !=
            ref.read(libraryRepositoryProvider).replacementRevision) {
      return Scaffold(
        appBar: AppBar(title: const Text('Chi tiết')),
        body: const Center(
          child: Text('Thư viện đã đổi. Hãy mở lại liên kết.'),
        ),
      );
    }
    return state.when(
      loading: () =>
          const Scaffold(body: Center(child: CupertinoActivityIndicator())),
      error: (e, _) => Scaffold(
        appBar: AppBar(title: const Text('Chi tiết')),
        body: Center(child: Text(userFacingError(e))),
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
        final revision = ref
            .read(libraryRepositoryProvider)
            .replacementRevision;
        if (optionsBook != book.id || optionsRevision != revision) {
          optionsBook = book.id;
          optionsRevision = revision;
          options = ChapterListOptions.fromJson(book.chapterListPreferences);
          selectedIds.clear();
          selecting = false;
          selectionRevision = null;
        }
        final catalogueBook = ref
            .read(libraryProvider.notifier)
            .catalogue(book);
        final sources = ref.read(sourceRepositoryProvider);
        final metadataKey =
            '$revision:${book.id}:${book.sourceId}:${book.sourceRef}';
        if (book.engine != 'local' &&
            !sources.requiresExternalConnection(catalogueBook.engine) &&
            (book.status == 0 ||
                book.description.isEmpty ||
                book.author.isEmpty) &&
            metadataRequest != metadataKey) {
          metadataRequest = metadataKey;
          WidgetsBinding.instance.addPostFrameCallback((_) async {
            if (!mounted) return;
            try {
              await ref
                  .read(libraryProvider.notifier)
                  .refreshBookDetail(
                    book.id,
                    expectedRevision: revision,
                    refreshChapters: false,
                    preserveTitle: true,
                  );
            } catch (error) {
              DiagnosticLogs.error('source', error);
            }
          });
        }
        final sourceUri = Uri.tryParse(book.sourceRef);
        final sourceUrl =
            sourceUri != null &&
            ['http', 'https'].contains(sourceUri.scheme) &&
            sourceUri.hasAuthority;
        final colors = Theme.of(context).colorScheme;
        final primary = colors.primary;
        final secondary = CupertinoDynamicColor.resolve(
          CupertinoColors.secondaryLabel,
          context,
        );
        final separator = CupertinoDynamicColor.resolve(
          CupertinoColors.separator,
          context,
        );
        final query = search.text.trim().toLowerCase();
        final indices = options.indices(book, query: query);
        final duplicates = duplicateChapterIndices(book);
        final headerCount = searching ? 3 : 2;
        return Scaffold(
          bottomNavigationBar: !selecting
              ? null
              : SafeArea(
                  child: SizedBox(
                    height: 52,
                    child: Row(
                      children: [
                        IconButton(
                          tooltip: 'Đóng lựa chọn',
                          onPressed: endSelection,
                          icon: const Icon(CupertinoIcons.xmark),
                        ),
                        Expanded(
                          child: Text(
                            '${selectedIds.length} đã chọn',
                            style: const TextStyle(fontSize: 12),
                          ),
                        ),
                        IconButton(
                          tooltip: 'Chọn tất cả chương hiển thị',
                          onPressed: () => setState(
                            () => selectedIds.addAll(
                              indices.map((i) => book.chapters[i].id),
                            ),
                          ),
                          icon: const Icon(CupertinoIcons.checkmark_circle),
                        ),
                        IconButton(
                          tooltip: 'Bỏ chọn tất cả',
                          onPressed: () => setState(selectedIds.clear),
                          icon: const Icon(CupertinoIcons.circle),
                        ),
                        PopupMenuButton<String>(
                          tooltip: 'Thao tác các chương đã chọn',
                          onSelected: (action) {
                            if (action == 'range') {
                              selectChapterRange(book, indices);
                            } else if (action == 'invert') {
                              setState(() {
                                for (final index in indices) {
                                  final id = book.chapters[index].id;
                                  if (!selectedIds.remove(id)) {
                                    selectedIds.add(id);
                                  }
                                }
                              });
                            } else {
                              batchAction(book, action);
                            }
                          },
                          itemBuilder: (_) => [
                            PopupMenuItem(
                              value: 'invert',
                              enabled: indices.isNotEmpty,
                              child: const Text('Đảo chọn chương hiển thị'),
                            ),
                            PopupMenuItem(
                              value: 'range',
                              enabled: indices.isNotEmpty,
                              child: const Text('Chọn phạm vi chương'),
                            ),
                            const PopupMenuDivider(),
                            for (final entry in const {
                              'read': 'Đánh dấu đã đọc',
                              'unread': 'Đánh dấu chưa đọc',
                              'bookmark': 'Đánh dấu chương',
                              'unbookmark': 'Bỏ dấu trang chương',
                            }.entries)
                              PopupMenuItem(
                                value: entry.key,
                                enabled: selectedIds.isNotEmpty,
                                child: Text(entry.value),
                              ),
                            if (book.engine != 'local')
                              PopupMenuItem(
                                value: 'download',
                                enabled: selectedIds.isNotEmpty,
                                child: const Text('Tải chương đã chọn'),
                              ),
                            if (book.engine != 'local')
                              PopupMenuItem(
                                value: 'delete',
                                enabled: selectedIds.isNotEmpty,
                                child: const Text('Xóa nội dung tải'),
                              ),
                            if (book.kind == 'manga')
                              PopupMenuItem(
                                value: 'cbz',
                                enabled: selectedIds.isNotEmpty,
                                child: const Text('Xuất CBZ chương đã chọn'),
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
          extendBodyBehindAppBar: true,
          appBar: AppBar(
            backgroundColor: Colors.transparent,
            actions: [
              if (sourceUrl)
                IconButton(
                  tooltip: 'Sao chép địa chỉ nguồn',
                  icon: const Icon(CupertinoIcons.square_arrow_up),
                  onPressed: () => copySource(book),
                ),
              IconButton(
                tooltip: 'Tải chương',
                icon: downloading
                    ? const CupertinoActivityIndicator(radius: 9)
                    : const Icon(CupertinoIcons.arrow_down_to_line),
                onPressed:
                    book.engine == 'local' ||
                        downloading ||
                        book.chapters.isEmpty
                    ? null
                    : () => downloadChapters(book),
              ),
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
              padding: EdgeInsets.zero,
              itemCount: headerCount + (indices.isEmpty ? 1 : indices.length),
              itemBuilder: (context, row) {
                if (row == 0) {
                  return BookDetailHeader(
                    book: book,
                    sourceLabel: resolvedLibrarySourceLabel(ref, book),
                    coverImage: libraryCoverImage(ref, book),
                    descriptionExpanded: descriptionExpanded,
                    onToggleDescription: () => setState(
                      () => descriptionExpanded = !descriptionExpanded,
                    ),
                    onFavorite: () => perform(
                      context,
                      () => ref
                          .read(libraryProvider.notifier)
                          .updateMetadata(book.id, favorite: !book.favorite),
                    ),
                    onEditNotes: () => editNotes(book),
                    onSearchTitle: () => searchMetadata(book.title),
                    onSearchAuthor: book.author.isEmpty
                        ? null
                        : () => searchMetadata(book.author),
                    onSearchGenre: (genre) => searchMetadata(genre),
                    onCopySource: sourceUrl ? () => copySource(book) : null,
                    onOpenWebsite:
                        book.engine != 'local' &&
                            sources.canOpenNativeWebsite(catalogueBook)
                        ? () => perform(
                            context,
                            () => sources.openWebsite(catalogueBook),
                          )
                        : null,
                    onResume: book.chapters.isEmpty
                        ? null
                        : () => context.push(
                            libraryReaderLocation(
                              book,
                              book.currentChapter.clamp(
                                0,
                                book.chapters.length - 1,
                              ),
                            ),
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
                                fontWeight: FontWeight.w400,
                              ),
                            ),
                          ),
                          IconButton(
                            tooltip: 'Tìm chương',
                            icon: const Icon(CupertinoIcons.search, size: 20),
                            color: searching ? primary : secondary,
                            onPressed: () => setState(() {
                              searching = !searching;
                              if (!searching) search.clear();
                            }),
                          ),
                          IconButton(
                            tooltip: options.descending
                                ? 'Chương cũ trước'
                                : 'Chương mới trước',
                            color: secondary,
                            onPressed: () {
                              final revision = ref
                                  .read(libraryRepositoryProvider)
                                  .replacementRevision;
                              setState(
                                () => options = options.patch({
                                  'descending': !options.descending,
                                }),
                              );
                              perform(
                                context,
                                () => ref
                                    .read(libraryProvider.notifier)
                                    .updateChapterListPreferences(
                                      book.id,
                                      options.toJson(),
                                      expectedRevision: revision,
                                    ),
                              );
                            },
                            icon: Icon(
                              options.descending
                                  ? CupertinoIcons.arrow_up
                                  : CupertinoIcons.arrow_down,
                              size: 22,
                            ),
                          ),
                          IconButton(
                            tooltip: 'Lọc và sắp xếp chương',
                            color:
                                options.read != 'all' ||
                                    options.download != 'all' ||
                                    options.bookmarked != 'all' ||
                                    options.hideDuplicates ||
                                    options.scanlator.isNotEmpty ||
                                    options.excludedScanlators.isNotEmpty
                                ? primary
                                : secondary,
                            onPressed: () => chapterOptions(book),
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
                    child: Column(
                      children: [
                        Text(
                          book.chapters.isEmpty
                              ? 'Chưa có chương'
                              : 'Không có chương phù hợp',
                          style: TextStyle(color: secondary, fontSize: 15),
                        ),
                        const SizedBox(height: 8),
                        if (book.chapters.isEmpty && book.engine != 'local')
                          TextButton.icon(
                            icon: const Icon(CupertinoIcons.refresh),
                            label: const Text('Làm mới chương'),
                            onPressed: () {
                              final revision = ref
                                  .read(libraryRepositoryProvider)
                                  .replacementRevision;
                              perform(context, () async {
                                final result = await ref
                                    .read(libraryProvider.notifier)
                                    .updateBooks([
                                      book.id,
                                    ], expectedRevision: revision);
                                if (result.hasErrors) {
                                  throw StateError(
                                    result.failures.first.message,
                                  );
                                }
                              });
                            },
                          )
                        else if (book.chapters.isNotEmpty)
                          TextButton(
                            onPressed: () {
                              final revision = ref
                                  .read(libraryRepositoryProvider)
                                  .replacementRevision;
                              setState(() {
                                search.clear();
                                options = options.patch({
                                  'read': 'all',
                                  'download': 'all',
                                  'bookmarked': 'all',
                                  'scanlator': '',
                                  'excludedScanlators': <String>[],
                                  'hideDuplicates': false,
                                });
                              });
                              perform(
                                context,
                                () => ref
                                    .read(libraryProvider.notifier)
                                    .updateChapterListPreferences(
                                      book.id,
                                      options.toJson(),
                                      expectedRevision: revision,
                                    ),
                              );
                            },
                            child: const Text('Xóa tìm kiếm và bộ lọc'),
                          ),
                      ],
                    ),
                  );
                }
                final index = indices[row - headerCount];
                final chapter = book.chapters[index];
                final read = chapterIsRead(book, index);
                return Column(
                  children: [
                    ListTile(
                      selected: selecting && selectedIds.contains(chapter.id),
                      leading: selecting
                          ? Checkbox(
                              value: selectedIds.contains(chapter.id),
                              onChanged: (value) => setState(() {
                                if (value == true) {
                                  selectedIds.add(chapter.id);
                                } else {
                                  selectedIds.remove(chapter.id);
                                }
                              }),
                            )
                          : chapterHasBookmark(book, index)
                          ? const Icon(CupertinoIcons.bookmark_fill, size: 16)
                          : null,
                      minTileHeight: 66,
                      contentPadding: const EdgeInsets.only(left: 16, right: 8),
                      title: Text(
                        chapter.title,
                        style: TextStyle(
                          fontSize: 15,
                          color: read ? secondary : colors.onSurface,
                        ),
                      ),
                      subtitle:
                          chapter.uploadedAt != null ||
                              chapter.scanlator.isNotEmpty ||
                              chapter.number != null ||
                              duplicates.contains(index)
                          ? Text(
                              [
                                if (validChapterNumber(chapter) != null)
                                  'Số ${chapter.number}',
                                if (duplicates.contains(index))
                                  'Trùng số chương',
                                if (chapter.uploadedAt != null)
                                  '${chapter.uploadedAt!.day}/${chapter.uploadedAt!.month}/${chapter.uploadedAt!.year}',
                                if (chapter.scanlator.isNotEmpty)
                                  chapter.scanlator,
                              ].join(' · '),
                              style: TextStyle(fontSize: 12, color: secondary),
                            )
                          : book.lastRead != null &&
                                index == book.currentChapter &&
                                !read
                          ? Text(
                              'Đang đọc',
                              style: TextStyle(fontSize: 12, color: secondary),
                            )
                          : null,
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (chapter.downloaded)
                            Padding(
                              padding: const EdgeInsets.all(12),
                              child: Icon(
                                CupertinoIcons.checkmark_circle_fill,
                                size: 20,
                                color: secondary,
                              ),
                            )
                          else if (book.engine != 'local')
                            IconButton(
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
                          IconButton(
                            tooltip: 'Thao tác ${chapter.title}',
                            onPressed: () => chapterActions(book, index),
                            icon: const Icon(CupertinoIcons.ellipsis, size: 20),
                          ),
                        ],
                      ),
                      onTap: () {
                        if (selecting) {
                          setState(() {
                            if (!selectedIds.remove(chapter.id)) {
                              selectedIds.add(chapter.id);
                            }
                          });
                        } else {
                          context.push(libraryReaderLocation(book, index));
                        }
                      },
                      onLongPress: () => beginSelection(chapter.id),
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
