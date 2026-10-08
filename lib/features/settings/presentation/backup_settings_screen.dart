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

  Future<void> importBackup() => run(() async {
    final selected = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: ['json'],
      dialogTitle: 'Chọn bản sao lưu TachiBooks',
    );
    if (selected == null) return;
    final size = await selected.length();
    if (size != null && size > BackupService.maxBackupBytes) {
      throw const FormatException('Bản sao lưu vượt giới hạn 128 MB.');
    }
    final bytes = await selected.readAsBytes();
    final count = await BackupService(ref.read(libraryRepositoryProvider))
        .merge(bytes);
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
        subtitle: 'Lưu thư viện vào một file JSON',
        trailing: busy ? const CupertinoActivityIndicator() : null,
        onTap: busy ? null : exportBackup,
      ),
      SettingsRow(
        title: 'Khôi phục bản sao lưu',
        icon: CupertinoIcons.arrow_down_doc,
        onTap: busy ? null : importBackup,
      ),
      const SettingsNote(
        'Bản sao lưu TachiBooks chứa sách, tiến độ, dấu trang và nội dung đã lưu. Khôi phục thêm sách mới và giữ nguyên sách đã có. File được kiểm tra trước khi ghi vào thư viện.',
      ),
      const SettingsHeading('Định dạng'),
      const SettingsNote(
        'Chỉ hỗ trợ bản sao lưu JSON của TachiBooks, tối đa 128 MB. Thiết lập ứng dụng và mục tiêu đọc không nằm trong file sao lưu. File sao lưu chưa được mã hóa; hãy lưu ở nơi riêng tư.',
      ),
    ],
  );
}
