import 'dart:async';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart'
    show ScaffoldMessenger, SnackBar, SnackBarAction;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/widgets/feedback.dart';
import '../../../core/format/vietnamese_format.dart';
import '../../library/application/backup_service_provider.dart';
import '../../library/application/backup_activity.dart';
import '../../library/application/backup_source_availability.dart';
import '../../library/application/extension_recovery_controller.dart';
import '../../library/data/backup_service.dart';
import '../../library/data/backup_compatibility/mihon_backup_exporter.dart';
import '../../library/presentation/library_view_model.dart';
import 'settings_widgets.dart';
import 'automatic_backup_screen.dart';
import 'backup_restore_progress_screen.dart';

typedef MihonBackupFileWriter = Future<Uri?> Function(String, Uint8List);
final mihonBackupFileWriterProvider = Provider<MihonBackupFileWriter>(
  (_) =>
      (name, bytes) => FilePicker.saveFile(
        fileName: name,
        bytes: bytes,
        mimeType: 'application/gzip',
        dialogTitle: 'Lưu bản trao đổi Mihon/Tachiyomi',
      ),
);

class BackupSettingsScreen extends ConsumerStatefulWidget {
  const BackupSettingsScreen({super.key});

  @override
  ConsumerState<BackupSettingsScreen> createState() => _BackupSettingsState();
}

class _BackupSettingsState extends ConsumerState<BackupSettingsScreen> {
  bool busy = false;
  ({int count, bool configuration})? completedRestore;

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
    final saved = await ref
        .read(backupActivityProvider.notifier)
        .exportBackup();
    if (mounted && saved) {
      message(context, 'Đã xuất thư viện và nội dung đã lưu');
    }
  });

  Future<void> exportMihon() => run(() async {
    final writer = ref.read(mihonBackupFileWriterProvider);
    final snapshot = await ref.read(libraryRepositoryProvider).snapshot();
    final exported = await exportMihonBackup(snapshot);
    if (!mounted) return;
    final confirmed = await Navigator.of(context).push<bool>(
      CupertinoPageRoute(
        builder: (_) => MihonExportPreviewScreen(exported: exported),
      ),
    );
    if (confirmed != true || !mounted) return;
    final date = DateTime.now().toIso8601String().substring(0, 10);
    final saved = await writer(
      'tachibooks-mihon-$date.tachibk',
      exported.bytes,
    );
    if (mounted && saved != null) {
      // This metadata exchange does not satisfy a full offline backup.
      message(context, 'Đã xuất ${exported.books} truyện cho Mihon/Tachiyomi');
    }
  });

  Future<void> exportRecovery() => run(() async {
    final bytes = await ref.read(backupServiceProvider).exportRecovery();
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
    final service = ref.read(backupServiceProvider);
    final activity = ref.read(backupActivityProvider.notifier);
    final preview = await service.preview(bytes);
    if (!mounted) return;
    final choice = await Navigator.of(context).push<BackupRestoreChoice>(
      CupertinoPageRoute(builder: (_) => BackupPreviewScreen(preview: preview)),
    );
    if (choice == null) return;
    if (!mounted) return;
    final count = await showBackupRestoreProgress(
      context,
      service,
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

  @override
  Widget build(BuildContext context) {
    final activity = ref.watch(backupActivityProvider);
    final recovery = ref.watch(extensionRecoveryProvider);
    String date(DateTime? value) =>
        value == null ? 'Chưa có trên thiết bị này' : vietnameseDateTime(value);
    return SettingsPage(
      title: 'Sao lưu & Khôi phục',
      children: [
        if (completedRestore case final completed?)
          BackupRestoreCompleted(
            books: completed.count,
            restoredConfiguration: completed.configuration,
            enabled: !busy,
          ),
        if (recovery.isLoading)
          const SettingsRow(
            title: 'Đang kiểm tra gói nguồn cần phục hồi…',
            trailing: CupertinoActivityIndicator(),
          ),
        if (extensionRecoveryMessage(recovery) case final String error) ...[
          SettingsNote(error),
          SettingsRow(
            title: 'Thử lại phục hồi extension đã lưu',
            subtitle: 'Dùng gói trong dữ liệu ứng dụng; giữ thư viện offline',
            onTap: busy
                ? null
                : () => run(
                    () => ref.read(extensionRecoveryProvider.notifier).retry(),
                  ),
          ),
        ],
        SettingsNote(
          'Xuất thủ công gần nhất: ${date(activity.exportedAt)}\nKhôi phục gần nhất: ${date(activity.restoredAt)}',
        ),
        SettingsRow(
          title: 'Sao lưu tự động',
          icon: CupertinoIcons.clock,
          subtitle: 'Lịch, số bản giữ lại và quản lý bản sao lưu',
          onTap: () => openSettingsPage(context, const AutomaticBackupScreen()),
        ),
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
          subtitle:
              'Thư viện trước lần khôi phục hoặc lấy bản đồng bộ gần nhất',
          onTap: busy ? null : exportRecovery,
        ),
        const SettingsNote(
          'Bản sao lưu TachiBooks chứa sách, tiến độ, dấu trang, nội dung đã lưu và cấu hình ứng dụng. Khôi phục thêm sách mới và giữ nguyên sách đã có. Bạn chọn có khôi phục cấu hình ở màn xem trước.',
        ),
        const SettingsHeading('Định dạng'),
        SettingsRow(
          title: 'Xuất cho Mihon / Tachiyomi',
          icon: CupertinoIcons.arrow_up_doc,
          subtitle: 'Thư viện nguồn Tachi, chương và tiến độ; không kèm nội dung offline',
          onTap: busy ? null : exportMihon,
        ),
        const SettingsNote(
          'Nhập TachiBooks JSON v1, Tachimanga .tmb build511/type0 và Mihon/Tachiyomi protobuf gzip; tối đa 128 MB. Bản sao lưu của app khác chỉ chứa những dữ liệu thực sự có trong file. Xem trước sẽ báo nội dung hoặc thiết lập không thể nhập. Chưa hỗ trợ sao lưu vBook khi chưa có mẫu định dạng thực tế.',
        ),
        const SettingsNote(
          'EPUB/TXT/CBZ và chương đã tải được mang theo để máy khác đọc offline. Danh mục, thứ tự, bộ lọc, thiết lập đọc, mục tiêu đọc và các kho extension công khai cũng được lưu. Đăng nhập, mã khóa và kết nối riêng được giữ trên từng máy. File chưa được mã hóa; hãy lưu ở nơi riêng tư.',
        ),
      ],
    );
  }
}

void showBackupRestoreCompleted(
  BuildContext context, {
  required int books,
  required bool restoredConfiguration,
}) {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(_restoreSummary(books, restoredConfiguration)),
      showCloseIcon: false,
      action: SnackBarAction(
        label: 'Về thư viện',
        onPressed: () {
          if (context.mounted) context.go('/');
        },
      ),
    ),
  );
}

String _restoreSummary(int books, bool configuration) =>
    'Đã khôi phục $books truyện mới'
    '${configuration ? ' và cấu hình ứng dụng' : ''}. '
    'Sách đã có được giữ nguyên.';

class BackupRestoreCompleted extends StatelessWidget {
  const BackupRestoreCompleted({
    super.key,
    required this.books,
    required this.restoredConfiguration,
    this.enabled = true,
  });
  final int books;
  final bool restoredConfiguration, enabled;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const SettingsHeading('Khôi phục hoàn tất'),
      SettingsNote(_restoreSummary(books, restoredConfiguration)),
      SettingsRow(
        title: 'Về thư viện',
        icon: CupertinoIcons.book,
        onTap: enabled ? () => context.go('/') : null,
      ),
    ],
  );
}

class MihonExportPreviewScreen extends StatelessWidget {
  const MihonExportPreviewScreen({super.key, required this.exported});
  final MihonBackupExport exported;

  @override
  Widget build(BuildContext context) => SettingsPage(
    title: 'Xem trước xuất Mihon',
    children: [
      const SettingsHeading('Mihon / Tachiyomi .tachibk'),
      SettingsNote(
        '${exported.books} truyện · ${exported.chapters} chương · '
        '${exported.categories} danh mục · ${exported.skippedBooks} truyện bỏ qua',
      ),
      for (final warning in exported.warnings) SettingsNote(warning),
      if (exported.books == 0)
        const SettingsNote(
          'Không có truyện nguồn Tachi phù hợp để xuất. Bản sao lưu đầy đủ TachiBooks vẫn giữ các truyện này.',
        ),
      if (exported.books > 0)
        SettingsRow(
          title: 'Tiếp tục lưu file .tachibk',
          icon: CupertinoIcons.arrow_up_doc,
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

class BackupRestoreChoice {
  const BackupRestoreChoice({required this.restoreConfiguration});
  final bool restoreConfiguration;
}

class BackupPreviewScreen extends StatefulWidget {
  const BackupPreviewScreen({
    super.key,
    required this.preview,
    this.sourceAvailabilityChecker,
  });
  final BackupPreview preview;
  final BackupSourceAvailabilityChecker? sourceAvailabilityChecker;

  @override
  State<BackupPreviewScreen> createState() => _BackupPreviewState();
}

class _BackupPreviewState extends State<BackupPreviewScreen> {
  bool restoreConfiguration = false;
  BackupPreview get preview => widget.preview;
  BackupSourceAvailability? sources;
  bool checkingSources = false;
  int sourceCheckGeneration = 0;
  bool initialized = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!initialized) {
      initialized = true;
      unawaited(checkSources());
    }
  }

  @override
  void didUpdateWidget(covariant BackupPreviewScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.preview, preview) ||
        oldWidget.sourceAvailabilityChecker !=
            widget.sourceAvailabilityChecker) {
      restoreConfiguration = false;
      unawaited(checkSources());
    }
  }

  Future<void> checkSources() async {
    final generation = ++sourceCheckGeneration;
    final captured = preview;
    sources = null;
    checkingSources = captured.snapshot.entries.any(
      (entry) => entry.book.engine != 'local',
    );
    final checker = widget.sourceAvailabilityChecker;
    BackupSourceAvailability result;
    try {
      result = checker == null
          ? await checkBackupSourceAvailability(captured.snapshot, (engine) {
              final repository = ProviderScope.containerOf(
                context,
                listen: false,
              ).read(sourceRepositoryProvider);
              return repository.listSources(engine);
            })
          : await checker(captured.snapshot);
    } catch (_) {
      result = await checkBackupSourceAvailability(
        captured.snapshot,
        (_) => Future.error(StateError('Source inventory unavailable')),
      );
    }
    if (!mounted ||
        generation != sourceCheckGeneration ||
        !identical(captured, preview)) {
      return;
    }
    setState(() {
      sources = result;
      checkingSources = false;
    });
  }

  Iterable<Widget> sourceStatus() sync* {
    if (preview.snapshot.entries.every(
      (entry) => entry.book.engine == 'local',
    )) {
      return;
    }
    yield const SettingsHeading('Nguồn trên thiết bị này');
    if (checkingSources) {
      yield const SettingsRow(
        title: 'Đang kiểm tra danh sách nguồn…',
        trailing: CupertinoActivityIndicator(),
      );
    }
    final report = sources;
    if (report != null) {
      yield SettingsNote(
        '${report.availableCount} nguồn đã có · ${report.missing.length} nguồn thiếu · '
        '${report.unverified.length} nguồn chưa xác minh',
      );
      for (final source in [...report.missing, ...report.unverified]) {
        final titles = source.bookTitles.take(3).join(', ');
        final extra = source.bookTitles.length > 3
            ? ' và ${source.bookTitles.length - 3} truyện khác'
            : '';
        yield SettingsRow(
          key: ValueKey('backup-source-${source.identity}'),
          title:
              '${source.status == BackupSourceStatus.missing ? 'Thiếu nguồn' : 'Chưa xác minh'} · '
              '${source.engineLabel} · ${source.sourceId}',
          subtitle: '${source.bookTitles.length} truyện: $titles$extra',
          showChevron: false,
        );
      }
      if (report.unverified.isNotEmpty) {
        yield const SettingsNote(
          'Engine chưa trả được danh sách nguồn. Chưa thể kết luận nguồn đã có hay còn thiếu.',
        );
      }
    }
    yield const SettingsNote(
      'Việc kiểm tra nguồn không cản khôi phục. Nội dung có trong bản sao lưu vẫn đọc offline; '
      'để đọc chương online hoặc cập nhật, cài nguồn tương ứng trong Duyệt. '
      'Có tên nguồn trong engine chưa xác nhận nguồn đọc được mọi truyện.',
    );
  }

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
      ...sourceStatus(),
      if (preview.hasConfiguration)
        SettingsRow(
          title: preview.snapshot.extensions == null
              ? 'Khôi phục cấu hình ứng dụng'
              : 'Khôi phục cấu hình và extension',
          subtitle:
              '${preview.configurationCount} thiết lập trong file. '
              '${preview.snapshot.extensions == null ? '' : '${preview.snapshot.extensions!.packages.length} gói nguồn có checksum. '}'
              'Bật để phục hồi các thiết lập và gói nguồn; các gói khác trên máy được giữ.',
          trailing: CupertinoSwitch(
            key: const ValueKey('restore-backup-configuration'),
            value: restoreConfiguration,
            onChanged: (value) => setState(() => restoreConfiguration = value),
          ),
        ),
      SettingsRow(
        title: restoreConfiguration
            ? 'Khôi phục ${preview.additions} sách mới và cấu hình'
            : 'Khôi phục ${preview.additions} sách mới',
        icon: CupertinoIcons.arrow_down_doc,
        onTap: () => Navigator.of(
          context,
        ).pop(BackupRestoreChoice(restoreConfiguration: restoreConfiguration)),
      ),
      SettingsRow(
        title: 'Hủy',
        icon: CupertinoIcons.xmark,
        onTap: () => Navigator.of(context).pop(),
      ),
    ],
  );
}
