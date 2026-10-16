import 'package:file_picker/file_picker.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/widgets/feedback.dart';
import '../../library/domain/library_book.dart';
import '../../library/presentation/library_view_model.dart';
import '../data/cbz_export_service.dart';
import 'download_queue_controller.dart';
import 'download_deletion_controller.dart';

final cbzSaveFileProvider = Provider<Future<bool> Function(CbzExport)>((ref) {
  return (export) async =>
      await FilePicker.saveFile(
        fileName: export.fileName,
        bytes: export.bytes,
        mimeType: 'application/vnd.comicbook+zip',
        dialogTitle: 'Lưu truyện tranh CBZ',
      ) !=
      null;
});

Future<void> deleteDownloadedChapters(
  BuildContext context,
  WidgetRef ref,
  LibraryBook book,
  Iterable<String> chapterIds, {
  int? expectedRevision,
}) async {
  final controller = ref.read(downloadDeletionProvider.notifier);
  final revision =
      expectedRevision ??
      ref.read(libraryRepositoryProvider).replacementRevision;
  final ids = chapterIds.toList(growable: false);
  if (ids.isEmpty) return;
  final confirmed = await showCupertinoDialog<bool>(
    context: context,
    builder: (ctx) => CupertinoAlertDialog(
      title: const Text('Xóa nội dung đã tải?'),
      content: Text(
        'Xóa nội dung tải của ${ids.length} chương trong “${book.title}”. '
        'Giữ truyện trong thư viện, tiến độ và dấu trang. '
        'Chương có dấu trang được giữ khi bật bảo vệ.',
      ),
      actions: [
        CupertinoDialogAction(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('Hủy'),
        ),
        CupertinoDialogAction(
          isDestructiveAction: true,
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('Xóa nội dung'),
        ),
      ],
    ),
  );
  if (confirmed != true || !context.mounted) return;
  await perform(context, () async {
    final deleted = await controller.deleteChapters(
      book,
      ids,
      expectedRevision: revision,
    );
    if (context.mounted) {
      message(
        context,
        deleted > 0
            ? 'Đã xóa nội dung tải của $deleted chương'
            : 'Không có chương để xóa. Chương có dấu trang được bảo vệ.',
      );
    }
  });
}

Future<void> saveDownloadedCbz(
  BuildContext context,
  WidgetRef ref,
  LibraryBook book, {
  int? expectedRevision,
  Iterable<String>? chapterIds,
}) async {
  final repository = ref.read(libraryRepositoryProvider);
  final revision = expectedRevision ?? repository.replacementRevision;
  final save = ref.read(cbzSaveFileProvider);
  await perform(context, () async {
    final export = await CbzExportService(repository)
        .exportBook(book, expectedRevision: revision, chapterIds: chapterIds);
    if (!context.mounted) return;
    if (await save(export) && context.mounted) {
      message(
        context,
        'Đã xuất ${export.chapters} chương, ${export.pages} trang CBZ',
      );
    }
  });
}

Future<void> enqueueNextDownloads(
  BuildContext context,
  WidgetRef ref,
  LibraryBook book, {
  int? expectedRevision,
}) async {
  final revision =
      expectedRevision ??
      ref.read(libraryRepositoryProvider).replacementRevision;
  final controller = ref.read(downloadQueueProvider.notifier);
  final count = await showCupertinoModalPopup<int>(
    context: context,
    builder: (ctx) => CupertinoActionSheet(
      title: const Text('Tải chương tiếp theo'),
      message: const Text('Các chương chưa đọc, chưa tải từ vị trí đang đọc.'),
      actions: [
        for (final count in [5, 10, 25, 50])
          CupertinoActionSheetAction(
            onPressed: () => Navigator.pop(ctx, count),
            child: Text('$count chương'),
          ),
      ],
      cancelButton: CupertinoActionSheetAction(
        onPressed: () => Navigator.pop(ctx),
        child: const Text('Hủy'),
      ),
    ),
  );
  if (count == null || !context.mounted) return;
  await perform(context, () async {
    final added = await controller.enqueueNext(
      book,
      count,
      expectedRevision: revision,
    );
    if (context.mounted) message(context, 'Đã thêm $added chương vào hàng đợi');
  });
}
