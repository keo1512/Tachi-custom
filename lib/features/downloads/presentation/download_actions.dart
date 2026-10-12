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
  await perform(context, () async {
    final deleted = await controller.deleteChapters(
      book,
      chapterIds,
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
