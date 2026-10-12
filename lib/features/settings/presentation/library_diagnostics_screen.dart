import 'package:file_picker/file_picker.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/widgets/feedback.dart';
import '../../../core/platform/application_recovery.dart';
import '../../library/application/library_diagnostics.dart';
import '../../library/presentation/library_view_model.dart';
import 'settings_widgets.dart';

class LibraryDiagnosticsScreen extends ConsumerStatefulWidget {
  const LibraryDiagnosticsScreen({super.key});
  @override
  ConsumerState<LibraryDiagnosticsScreen> createState() =>
      _LibraryDiagnosticsState();
}

class _LibraryDiagnosticsState extends ConsumerState<LibraryDiagnosticsScreen> {
  LibraryHealthReport? report;
  bool busy = false;
  int checkedBooks = 0, totalBooks = 0;
  String repairDescription(LibraryRepairSummary value) => [
    if (value.missingDownloads > 0)
      '${value.missingDownloads} cờ đã tải thiếu nội dung',
    if (value.incompleteDownloads > 0)
      '${value.incompleteDownloads} cờ đã tải có nội dung chưa đủ offline',
    if (value.chapterIndexes > 0)
      '${value.chapterIndexes} chỉ số chương chưa có nội dung/vị trí đọc liên quan',
    if (value.readingLocations > 0)
      '${value.readingLocations} vị trí đọc ngoài phạm vi được đặt lại',
    if (value.duplicateBookmarks > 0)
      '${value.duplicateBookmarks} dấu trang trùng được gộp',
    if (value.canonicalBookmarks > 0)
      '${value.canonicalBookmarks} dấu trang được chuẩn hóa cách ghi',
  ].join('\n');
  Future<void> inspect() async {
    if (busy) return;
    setState(() {
      busy = true;
      checkedBooks = 0;
      totalBooks = 0;
    });
    try {
      final result = await perform(
        context,
        () => LibraryDiagnostics(ref.read(libraryRepositoryProvider)).inspect(
          onProgress: (checked, total) {
            if (mounted) {
              setState(() {
                checkedBooks = checked;
                totalBooks = total;
              });
            }
          },
        ),
      );
      if (mounted) setState(() => report = result);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> repair() async {
    final preview = report;
    if (busy || preview == null || !preview.canRepair) return;
    final accepted = await showCupertinoDialog<bool>(
      context: context,
      builder: (ctx) => CupertinoAlertDialog(
        title: const Text('Sửa dữ liệu đã kiểm tra?'),
        content: Text(
          '${repairDescription(preview.repairSummary)}\n\n'
          'Bản dữ liệu trước khi sửa được lưu trước khi ghi. Không xóa truyện, chương hoặc nội dung. '
          'Chỉ áp dụng các thay đổi đã liệt kê và kiểm tra lại sau khi sửa.',
        ),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Hủy'),
          ),
          CupertinoDialogAction(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Sao lưu và sửa'),
          ),
        ],
      ),
    );
    if (accepted != true || !mounted) return;
    setState(() => busy = true);
    try {
      await perform(context, () async {
        final result = await LibraryDiagnostics(
          ref.read(libraryRepositoryProvider),
        ).repair(preview);
        if (!mounted) return;
        await ref.read(libraryProvider.notifier).refresh();
        if (mounted) {
          setState(() => report = result.reportAfterRepair);
          message(
            context,
            'Đã sửa và xác minh ${result.summary.total} mục dữ liệu. Bản phục hồi đã được giữ.',
          );
        }
      });
    } finally {
      if (mounted) setState(() => busy = false);
    }
    if (mounted) await inspect();
  }

  Future<void> enterRecovery() async {
    final recover = ref.read(applicationRecoveryProvider);
    if (busy || recover == null) return;
    final confirmed = await showCupertinoDialog<bool>(
      context: context,
      builder: (ctx) => CupertinoAlertDialog(
        title: const Text('Mở chế độ phục hồi?'),
        content: const Text(
          'Ứng dụng đóng các tác vụ và cơ sở dữ liệu đang dùng. '
          'Bạn chọn bản sao lưu để tạo thư viện mới; dữ liệu gốc được giữ riêng. '
          'Sau khi kiểm tra thành công, chạm Mở lại ứng dụng.',
        ),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Hủy'),
          ),
          CupertinoDialogAction(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Mở phục hồi'),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) await perform(context, recover);
  }

  @override
  Widget build(BuildContext context) => SettingsPage(
    title: 'Chẩn đoán thư viện',
    children: [
      SettingsRow(
        title: 'Kiểm tra dữ liệu và nội dung offline',
        subtitle: busy && totalBooks > 0
            ? 'Đã kiểm tra $checkedBooks / $totalBooks truyện'
            : null,
        icon: CupertinoIcons.checkmark_shield,
        trailing: busy ? const CupertinoActivityIndicator() : null,
        onTap: busy ? null : inspect,
      ),
      if (report case final value?) ...[
        if (value.storageUnreadable)
          const SettingsNote(
            'Không thể đọc toàn bộ dữ liệu hiện tại. Cần bản sao lưu đã kiểm tra để phục hồi; không tự xóa tệp.',
          ),
        SettingsRow(
          title: 'Sách / chương',
          subtitle: '${value.books} / ${value.chapters}',
        ),
        SettingsRow(
          title: 'Chương có nội dung lưu',
          subtitle: '${value.cachedChapters}',
        ),
        SettingsRow(
          title: 'Cờ đã tải thiếu nội dung',
          subtitle: '${value.missingDownloads}',
        ),
        SettingsRow(
          title: 'Ảnh đã kiểm tra giải mã',
          subtitle: '${value.checkedImages}',
        ),
        SettingsRow(
          title: 'Bìa không đọc được trên thiết bị này',
          subtitle: '${value.damagedCovers}',
        ),
        SettingsRow(
          title: 'Chương có ảnh không đọc được',
          subtitle: '${value.unreadableChapters.length}',
        ),
        for (final chapter in value.unreadableChapters.take(30))
          SettingsRow(
            title: chapter.bookTitle,
            subtitle:
                '${chapter.chapterTitle} · Cần thử tải lại hoặc khôi phục nội dung',
            showChevron: false,
          ),
        if (value.unreadableChapters.length > 30)
          SettingsNote(
            'Còn ${value.unreadableChapters.length - 30} chương không đọc được. Báo cáo xuất có tổng số chương.',
          ),
        SettingsNote(
          value.validationError == null
              ? 'Dữ liệu đã qua kiểm tra định dạng sao lưu.'
              : 'Kiểm tra phát hiện lỗi: ${value.validationError}',
        ),
        if (value.repairSummary.hasChanges)
          SettingsNote(repairDescription(value.repairSummary)),
        if (value.repairBlockedReason != null)
          SettingsNote(value.repairBlockedReason!),
        if (value.canRepair)
          SettingsRow(
            title: 'Xem trước và sửa dữ liệu an toàn',
            icon: CupertinoIcons.wrench,
            onTap: busy ? null : repair,
          ),
        SettingsRow(
          title: 'Xuất báo cáo chẩn đoán',
          icon: CupertinoIcons.share,
          onTap: busy
              ? null
              : () => perform(
                  context,
                  () => FilePicker.saveFile(
                    fileName: 'TachiBooks-chan-doan.json',
                    bytes: value.exportSummary(),
                  ),
                ),
        ),
      ],
      if (ref.watch(applicationRecoveryProvider) != null)
        SettingsRow(
          title: 'Phục hồi thư viện từ bản sao lưu',
          icon: CupertinoIcons.arrow_counterclockwise,
          subtitle: 'Đóng bộ nhớ đang dùng, giữ dữ liệu gốc và mở lại sau khi xác minh',
          onTap: busy ? null : enterRecovery,
        ),
      const SettingsNote(
        'Báo cáo chỉ có số lượng và kết quả kiểm tra, không chứa tên truyện hay tài khoản. '
        'Ảnh không giải mã được có thể bị hỏng hoặc chưa được thiết bị hỗ trợ. Không tự xóa nội dung. '
        'Sửa tự động chỉ áp dụng khi ánh xạ dữ liệu rõ ràng và bản sửa qua kiểm tra định dạng. '
        'Dữ liệu mơ hồ hoặc cơ sở dữ liệu không đọc được cần bản sao lưu hợp lệ để phục hồi.',
      ),
    ],
  );
}
