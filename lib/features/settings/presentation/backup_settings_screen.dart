import 'package:file_picker/file_picker.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/widgets/feedback.dart';
import '../../library/data/backup_service.dart';
import '../../library/presentation/library_view_model.dart';
import 'settings_widgets.dart';

class BackupSettingsScreen extends ConsumerStatefulWidget {
  const BackupSettingsScreen({super.key});

  @override
  ConsumerState<BackupSettingsScreen> createState() => _BackupSettingsState();
}

class _BackupSettingsState extends ConsumerState<BackupSettingsScreen> {
  bool busy = false;

  Future<void> run(Future<void> Function() action) async {
    if (busy) return;
    setState(() => busy = true);
    try {
      await perform(context, action);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> exportBackup() => run(() async {
    final bytes = await BackupService(ref.read(libraryRepositoryProvider))
        .export();
    final date = DateTime.now().toIso8601String().substring(0, 10);
    final saved = await FilePicker.saveFile(
      fileName: 'tachibooks-$date.json',
      bytes: bytes,
      mimeType: 'application/json',
      dialogTitle: 'Lưu bản sao lưu TachiBooks',
    );
    if (mounted && saved != null) {
      message(context, 'Đã xuất thư viện và nội dung đã lưu');
    }
  });

  Future<void> exportRecovery() => run(() async {
    final bytes = await BackupService(ref.read(libraryRepositoryProvider))
        .exportRecovery();
    if (bytes == null) {
      if (mounted) {
        message(
          context,
          'Chưa có bản phục hồi trước khi khôi phục hoặc đồng bộ.',
        );
      }
      return;
    }
    final date = DateTime.now().toIso8601String().substring(0, 10);
    final saved = await FilePicker.saveFile(
      fileName: 'tachibooks-recovery-$date.json',
      bytes: bytes,
      mimeType: 'application/json',
      dialogTitle: 'Lưu thư viện trước khi khôi phục',
    );
    if (mounted && saved != null) {
      message(context, 'Đã xuất bản phục hồi đầy đủ');
    }
  });

  Future<void> importBackup() => run(() async {
    final selected = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: ['json', 'tmb', 'tachibk', 'gz', 'backup'],
      dialogTitle: 'Chọn bản sao lưu thư viện',
    );
    if (selected == null) return;
    final size = await selected.length();
    if (size != null && size > BackupService.maxBackupBytes) {
      throw const FormatException('Bản sao lưu vượt giới hạn 128 MB.');
    }
    final bytes = await selected.readAsBytes();
    final service = BackupService(ref.read(libraryRepositoryProvider));
    final preview = await service.preview(bytes);
    if (!mounted) return;
    final confirmed = await Navigator.of(context).push<bool>(
      CupertinoPageRoute(builder: (_) => BackupPreviewScreen(preview: preview)),
    );
    if (confirmed != true) return;
    final count = await service.mergePreview(preview);
    await ref.read(libraryProvider.notifier).refresh();
    if (mounted) {
      message(context, 'Đã khôi phục $count sách. Sách đã có được giữ nguyên.');
    }
  });

  @override
  Widget build(BuildContext context) => SettingsPage(
    title: 'Sao lưu & Khôi phục',
    children: [
      SettingsRow(
        title: 'Tạo bản sao lưu',
        icon: CupertinoIcons.arrow_up_doc,
        subtitle: 'Lưu thư viện và toàn bộ nội dung offline',
        trailing: busy ? const CupertinoActivityIndicator() : null,
        onTap: busy ? null : exportBackup,
      ),
      SettingsRow(
        title: 'Khôi phục bản sao lưu',
        icon: CupertinoIcons.arrow_down_doc,
        onTap: busy ? null : importBackup,
      ),
      SettingsRow(
        title: 'Xuất bản phục hồi trước đó',
        icon: CupertinoIcons.arrow_counterclockwise,
        subtitle: 'Thư viện trước lần khôi phục hoặc lấy bản đồng bộ gần nhất',
        onTap: busy ? null : exportRecovery,
      ),
      const SettingsNote(
        'Bản sao lưu TachiBooks chứa sách, tiến độ, dấu trang và nội dung đã lưu. Khôi phục thêm sách mới và giữ nguyên sách đã có. File được kiểm tra trước khi ghi vào thư viện.',
      ),
      const SettingsHeading('Định dạng'),
      const SettingsNote(
        'Nhập TachiBooks JSON v1, Tachimanga .tmb build511/type0 và Mihon/Tachiyomi protobuf gzip; tối đa 128 MB. Bản sao lưu của app khác chỉ chứa những dữ liệu thực sự có trong file. Xem trước sẽ báo nội dung hoặc thiết lập không thể nhập. Chưa hỗ trợ sao lưu vBook khi chưa có mẫu định dạng thực tế.',
      ),
      const SettingsNote(
        'Sao lưu TachiBooks mang theo nội dung EPUB/TXT/CBZ đã nhập và chương đã tải, để máy khác đọc offline sau khôi phục. Thiết lập ứng dụng và mục tiêu đọc không nằm trong file sao lưu. File chưa được mã hóa; hãy lưu ở nơi riêng tư.',
      ),
    ],
  );
}

class BackupPreviewScreen extends StatelessWidget {
  const BackupPreviewScreen({super.key, required this.preview});
  final BackupPreview preview;

  @override
  Widget build(BuildContext context) => SettingsPage(
    title: 'Xem trước khôi phục',
    children: [
      SettingsHeading(preview.format),
      SettingsNote(
        '${preview.books} sách trong file · ${preview.additions} sách mới',
      ),
      SettingsNote(
        '${preview.cachedChapters} chương có nội dung trong file. '
        'Sách đã có được giữ nguyên, gồm tiến độ và nội dung hiện tại.',
      ),
      const SettingsHeading('Dữ liệu được nhập'),
      for (final warning in preview.warnings) SettingsNote(warning),
      SettingsRow(
        title: 'Khôi phục ${preview.additions} sách mới',
        icon: CupertinoIcons.arrow_down_doc,
        onTap: () => Navigator.of(context).pop(true),
      ),
      SettingsRow(
        title: 'Hủy',
        icon: CupertinoIcons.xmark,
        onTap: () => Navigator.of(context).pop(false),
      ),
    ],
  );
}
