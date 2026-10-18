import 'package:file_picker/file_picker.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/widgets/feedback.dart';
import '../../../core/format/task_intervals.dart';
import '../../../core/format/vietnamese_format.dart';
import '../../library/application/automatic_backup_controller.dart';
import '../../library/application/backup_activity.dart';
import '../../library/application/automatic_backup_status.dart';
import '../../library/data/automatic_backup_store.dart';
import '../../library/data/backup_directory_platform.dart';
import '../../library/data/external_automatic_backup_store.dart';
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
  bool loading = true;
  int loadGeneration = 0;
  List<StoredBackup> backups = [];
  AutomaticBackupStore? listedStore;
  String? error;
  ({int count, bool configuration})? completedRestore;
  @override
  void initState() {
    super.initState();
    refresh();
  }

  Future<void> refresh() async {
    final generation = ++loadGeneration;
    if (mounted) setState(() => loading = true);
    try {
      final store = await ref.read(automaticBackupStoreProvider.future);
      final list = await store.list();
      if (mounted && generation == loadGeneration) {
        setState(() {
          backups = list;
          listedStore = store;
          error = null;
          loading = false;
        });
      }
    } catch (e) {
      if (mounted && generation == loadGeneration) {
        setState(() {
          error = userFacingError(e);
          loading = false;
        });
      }
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
    final store = listedStore;
    if (busy || loading || store == null) return;
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
    if (action == 'delete') {
      final accepted = await showCupertinoDialog<bool>(
        context: context,
        builder: (context) => CupertinoAlertDialog(
          title: const Text('Xóa bản sao lưu?'),
          content: Text(
            '${item.name}\nBản sao lưu này sẽ bị xóa. Thư viện đang dùng được giữ nguyên.',
          ),
          actions: [
            CupertinoDialogAction(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Hủy'),
            ),
            CupertinoDialogAction(
              isDestructiveAction: true,
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Xóa'),
            ),
          ],
        ),
      );
      if (accepted != true || !mounted) return;
    }
    await run(() async {
      final current = await ref.read(automaticBackupStoreProvider.future);
      if (!mounted) return;
      if (!identical(current, store)) {
        throw StateError(
          'Vị trí sao lưu đã thay đổi. Hãy mở lại bản sao lưu từ danh sách mới.',
        );
      }
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
      if (mounted) {
        setState(() {
          completedRestore = (
            count: count,
            configuration: choice.restoreConfiguration,
          );
        });
      }
      await activity.restored();
      if (!mounted) return;
      await ref.read(libraryProvider.notifier).refresh();
      if (mounted) {
        showBackupRestoreCompleted(
          context,
          books: count,
          restoredConfiguration: choice.restoreConfiguration,
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
    final backupLocation = switch (listedStore) {
      ExternalAutomaticBackupStore(:final location) =>
        '${location.label} / TachiBooks-Backups',
      _ => 'Trong dữ liệu ứng dụng',
    };
    return SettingsPage(
      title: 'Sao lưu tự động',
      children: [
        const SettingsNote(
          'Tự sao lưu theo lịch kể cả khi không mở giao diện. iOS chọn thời điểm chạy thực tế nên có thể trễ hơn chu kỳ. Nếu vuốt tắt hẳn app trong đa nhiệm, cần mở lại để tiếp tục lịch nền.',
        ),
        if (completedRestore case final completed?)
          BackupRestoreCompleted(
            books: completed.count,
            restoredConfiguration: completed.configuration,
            enabled: !busy,
          ),
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
        for (final hours in AutomaticBackupPolicy.intervals)
          SettingsRow(
            title: hours == 0 ? 'Tắt' : 'Mỗi ${taskIntervalLabel(hours)}',
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
        if (loading)
          const SettingsRow(
            title: 'Đang đọc danh sách sao lưu…',
            trailing: CupertinoActivityIndicator(),
          ),
        if (error != null) ...[
          SettingsNote(error!),
          SettingsRow(
            title: 'Thử lại danh sách sao lưu',
            icon: CupertinoIcons.refresh,
            onTap: busy || loading ? null : refresh,
          ),
        ],
        if (!loading && backups.isEmpty && error == null)
          const SettingsNote('Chưa có bản sao lưu tự động.'),
        for (final item in backups)
          SettingsRow(
            title: item.name,
            subtitle:
                '${vietnameseDateTime(item.createdAt)} · ${vietnameseNumber(item.size / (1024 * 1024), decimals: 2)} MB\n'
                '$backupLocation',
            icon: CupertinoIcons.doc,
            onTap: busy || loading ? null : () => actions(item),
          ),
      ],
    );
  }
}
