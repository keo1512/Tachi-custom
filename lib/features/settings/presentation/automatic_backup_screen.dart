import 'package:file_picker/file_picker.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/widgets/feedback.dart';
import '../../../core/format/vietnamese_format.dart';
import '../../library/application/automatic_backup_controller.dart';
import '../../library/application/backup_activity.dart';
import '../../library/application/automatic_backup_status.dart';
import '../../library/data/automatic_backup_store.dart';
import '../../library/data/backup_directory_platform.dart';
import '../../library/presentation/library_view_model.dart';
import 'backup_settings_screen.dart';
import 'backup_restore_progress_screen.dart';
import 'settings_widgets.dart';

class AutomaticBackupScreen extends ConsumerStatefulWidget {
  const AutomaticBackupScreen({super.key});
  @override
  ConsumerState<AutomaticBackupScreen> createState() =>
      _AutomaticBackupScreenState();
}

class _AutomaticBackupScreenState extends ConsumerState<AutomaticBackupScreen> {
  bool busy = false;
  List<StoredBackup> backups = [];
  String? error;
  @override
  void initState() {
    super.initState();
    refresh();
  }

  Future<void> refresh() async {
    try {
      final store = await ref.read(automaticBackupStoreProvider.future);
      final list = await store.list();
      if (mounted) {
        setState(() {
          backups = list;
          error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => error = userFacingError(e));
    }
  }

  Future<void> run(Future<void> Function() action) async {
    if (busy) return;
    setState(() => busy = true);
    try {
      await perform(context, action);
      await refresh();
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> chooseDestination({bool internal = false}) => run(() async {
    final platform = ref.read(backupDirectoryPlatformProvider);
    if (internal) {
      await platform.forget();
    } else if (await platform.choose() == null) {
      return;
    }
    if (!mounted) return;
    ref.invalidate(backupDirectoryLocationProvider);
    ref.invalidate(automaticBackupStoreProvider);
  });

  Future<void> actions(StoredBackup item) async {
    final action = await showCupertinoModalPopup<String>(
      context: context,
      builder: (ctx) => CupertinoActionSheet(
        title: Text(item.name),
        actions: [
          CupertinoActionSheetAction(
            onPressed: () => Navigator.pop(ctx, 'export'),
            child: const Text('Xuất vào Tệp / iCloud Drive'),
          ),
          CupertinoActionSheetAction(
            onPressed: () => Navigator.pop(ctx, 'restore'),
            child: const Text('Xem trước và khôi phục'),
          ),
          CupertinoActionSheetAction(
            isDestructiveAction: true,
            onPressed: () => Navigator.pop(ctx, 'delete'),
            child: const Text('Xóa bản sao lưu này'),
          ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('Hủy'),
        ),
      ),
    );
    if (action == null || !mounted) return;
    await run(() async {
      final store = await ref.read(automaticBackupStoreProvider.future);
      if (action == 'delete') {
        await store.delete(item.name);
        return;
      }
      final bytes = await store.read(item.name);
      if (action == 'export') {
        await FilePicker.saveFile(
          fileName: item.name,
          bytes: bytes,
          mimeType: 'application/json',
        );
        return;
      }
      final activity = ref.read(backupActivityProvider.notifier);
      final preview = await store.backup.preview(bytes);
      if (!mounted) return;
      final choice = await Navigator.push<BackupRestoreChoice>(
        context,
        CupertinoPageRoute(
          builder: (_) => BackupPreviewScreen(preview: preview),
        ),
      );
      if (choice == null) return;
      if (!mounted) return;
      final count = await showBackupRestoreProgress(
        context,
        store.backup,
        preview,
        restoreConfiguration: choice.restoreConfiguration,
      );
      if (count == null) return;
      await activity.restored();
      if (!mounted) return;
      await ref.read(libraryProvider.notifier).refresh();
      if (mounted) {
        message(
          context,
          'Đã khôi phục $count truyện mới'
          '${choice.restoreConfiguration ? ' và cấu hình ứng dụng' : ''}.',
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final policy = ref.watch(automaticBackupPolicyProvider);
    final controller = ref.read(automaticBackupPolicyProvider.notifier);
    final status = ref.watch(automaticBackupStatusProvider);
    final destination = ref.watch(backupDirectoryLocationProvider);
    String date(DateTime? value) =>
        value == null ? 'Chưa có' : vietnameseDateTime(value);
    return SettingsPage(
      title: 'Sao lưu tự động',
      children: [
        const SettingsHeading('Vị trí sao lưu tự động'),
        destination.when(
          loading: () => const SettingsRow(title: 'Đang kiểm tra vị trí…'),
          error: (error, _) => SettingsNote(userFacingError(error)),
          data: (location) => SettingsRow(
            title: location == null ? 'Trong dữ liệu ứng dụng' : location.label,
            subtitle: location == null
                ? 'Các bản đang có được giữ khi chọn vị trí khác.'
                : 'Thư mục con TachiBooks-Backups trong Tệp',
            icon: CupertinoIcons.folder,
            showChevron: false,
          ),
        ),
        SettingsRow(
          title: 'Chọn thư mục trong Tệp / iCloud Drive',
          icon: CupertinoIcons.folder_open,
          onTap: busy ? null : () => chooseDestination(),
        ),
        if (destination.value != null)
          SettingsRow(
            title: 'Dùng lại dữ liệu ứng dụng',
            onTap: busy ? null : () => chooseDestination(internal: true),
          ),
        const SettingsNote(
          'Lưu quyền truy cập trên thiết bị này. Chỉ ghi và giữ số bản trong thư mục con TachiBooks-Backups; không chuyển hoặc xóa file ở vị trí cũ. Nếu nhà cung cấp Tệp mất quyền hoặc không kết nối, chọn lại thư mục và thử lại.',
        ),
        const SettingsHeading('Lần chạy gần nhất'),
        SettingsRow(
          title: switch (status.stage) {
            AutomaticBackupRunStage.idle => 'Chưa chạy trên thiết bị này',
            AutomaticBackupRunStage.running => 'Đang tạo bản sao lưu…',
            AutomaticBackupRunStage.succeeded => 'Sao lưu thành công',
            AutomaticBackupRunStage.failed => 'Sao lưu chưa hoàn tất',
            AutomaticBackupRunStage.interrupted =>
              'Lần chạy trước đã bị gián đoạn',
          },
          subtitle: status.startedAt == null
              ? null
              : 'Bắt đầu: ${date(status.startedAt)}\nKết thúc: ${date(status.finishedAt)}',
          trailing: status.stage == AutomaticBackupRunStage.running
              ? const CupertinoActivityIndicator()
              : null,
        ),
        if (status.failure != null) SettingsNote(status.failure!),
        if (status.stage == AutomaticBackupRunStage.interrupted)
          const SettingsNote(
            'Chưa xác nhận lần chạy trước hoàn tất. Kiểm tra danh sách bản đã lưu và chọn Sao lưu ngay để thử lại.',
          ),
        if (status.fileName != null)
          SettingsNote(
            '${status.fileName} · ${vietnameseNumber((status.bytes ?? 0) / (1024 * 1024), decimals: 2)} MB',
          ),
        const SettingsHeading('Lịch sao lưu'),
        for (final hours in [0, 6, 12, 24, 48, 72])
          SettingsRow(
            title: hours == 0 ? 'Tắt' : 'Mỗi $hours giờ',
            trailing: policy.hours == hours
                ? const Icon(CupertinoIcons.checkmark)
                : null,
            onTap: busy
                ? null
                : () => run(() => controller.update(hours: hours)),
          ),
        const SettingsHeading('Số bản giữ lại'),
        for (final count in [1, 3, 5, 10])
          SettingsRow(
            title: '$count bản gần nhất',
            trailing: policy.keep == count
                ? const Icon(CupertinoIcons.checkmark)
                : null,
            onTap: busy
                ? null
                : () => run(() => controller.update(keep: count)),
          ),
        const SettingsNote(
          'Sao lưu đầy đủ vào vị trí đã chọn khi app hoạt động hoặc trở lại màn hình. Chỉ xóa bản cũ sau khi bản mới đã được ghi và kiểm tra thành công. Tệp trong iCloud Drive còn phụ thuộc nhà cung cấp hoàn tất tải lên.',
        ),
        SettingsRow(
          title: 'Sao lưu ngay',
          icon: CupertinoIcons.arrow_up_doc,
          trailing: busy ? const CupertinoActivityIndicator() : null,
          onTap: busy
              ? null
              : () => run(() async {
                  await ref
                      .read(automaticBackupSchedulerProvider)
                      .check(DateTime.now(), force: true);
                }),
        ),
        const SettingsHeading('Các bản đã lưu'),
        if (error != null) SettingsNote(error!),
        if (backups.isEmpty && error == null)
          const SettingsNote('Chưa có bản sao lưu tự động.'),
        for (final item in backups)
          SettingsRow(
            title: vietnameseDateTime(item.createdAt),
            subtitle:
                '${vietnameseNumber(item.size / (1024 * 1024), decimals: 2)} MB',
            icon: CupertinoIcons.doc,
            onTap: busy ? null : () => actions(item),
          ),
      ],
    );
  }
}
