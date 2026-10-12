import 'package:file_picker/file_picker.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/diagnostics/diagnostic_log.dart';
import '../../../core/platform/device_tools.dart';
import '../../../core/widgets/feedback.dart';
import '../../downloads/presentation/download_queue_controller.dart';
import '../../library/application/automatic_backup_status.dart';
import '../../library/application/library_update_report.dart';
import '../../library/presentation/library_view_model.dart';
import '../../privacy/application/app_lock_controller.dart';
import '../../settings/settings_controller.dart';
import '../../sources/domain/catalogue.dart';
import '../../sync/application/sync_controller.dart';
import '../../sync/presentation/sync_screen.dart';
import 'automatic_backup_screen.dart';
import 'library_diagnostics_screen.dart';
import 'settings_widgets.dart';

class LogDiagnosticsScreen extends ConsumerStatefulWidget {
  const LogDiagnosticsScreen({super.key});
  @override
  ConsumerState<LogDiagnosticsScreen> createState() => _LogDiagnosticsState();
}

class _LogDiagnosticsState extends ConsumerState<LogDiagnosticsScreen> {
  bool busy = false, checkingEngines = false;
  String category = 'all';
  final engines = <SourceEngine, String>{};
  final packages = <SourceEngine, List<CatalogueExtension>>{};
  Map<String, int>? backgroundStatus;
  bool permitted() {
    final lock = ref.read(appLockProvider);
    return lock.initialized &&
        lock.configurationValid &&
        !lock.locked &&
        !ref.read(settingsProvider).incognitoMode;
  }

  Future<void> run(Future<void> Function() action) async {
    if (busy) return;
    setState(() => busy = true);
    await perform(context, action);
    if (mounted) setState(() => busy = false);
  }

  Future<void> export({bool share = false}) => run(() async {
    if (!permitted()) {
      throw StateError(
        'Mở khóa ứng dụng và tắt chế độ riêng tư để xuất nhật ký.',
      );
    }
    final bytes = ref.read(diagnosticLogProvider).export();
    if (share) {
      await ref.read(deviceToolsProvider).shareLog(bytes);
    } else {
      final saved = await FilePicker.saveFile(
        fileName: 'tachibooks-diagnostic-log.json',
        bytes: bytes,
      );
      if (saved != null && mounted) message(context, 'Đã xuất nhật ký lỗi');
    }
  });
  Future<void> clear() async {
    final yes = await showCupertinoDialog<bool>(
      context: context,
      builder: (ctx) => CupertinoAlertDialog(
        title: const Text('Xóa nhật ký lỗi?'),
        content: const Text(
          'Chỉ xóa nhật ký trên thiết bị này. Thư viện và bản sao lưu được giữ.',
        ),
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
    if (yes != true || !mounted) return;
    await run(() async {
      if (!permitted()) {
        throw StateError('Mở khóa ứng dụng trước khi xóa nhật ký.');
      }
      await ref.read(diagnosticLogProvider).clear();
      if (mounted) message(context, 'Đã xóa nhật ký trên máy');
    });
  }

  Future<void> checkEngines() async {
    if (checkingEngines || !permitted()) return;
    setState(() => checkingEngines = true);
    try {
      final repository = ref.read(sourceRepositoryProvider);
      for (final engine in SourceEngine.values) {
        try {
          await repository.health(engine).timeout(const Duration(seconds: 20));
          final values = await repository
              .extensions(engine)
              .timeout(const Duration(seconds: 20));
          if (!mounted || !permitted()) return;
          engines[engine] = 'Đã phản hồi';
          packages[engine] = values
              .where((package) => package.installed)
              .toList();
        } catch (error) {
          if (!mounted || !permitted()) return;
          final event = DiagnosticEvent.error('source', error);
          engines[engine] = event.message;
          packages.remove(engine);
          await ref.read(diagnosticLogProvider).record(event);
        }
        if (mounted) setState(() {});
      }
    } finally {
      if (mounted) setState(() => checkingEngines = false);
    }
  }

  Future<void> checkBackground() => run(() async {
    if (!permitted()) {
      throw StateError('Mở khóa ứng dụng trước khi kiểm tra tác vụ nền.');
    }
    final value = await ref.read(deviceToolsProvider).usage();
    if (mounted && permitted()) setState(() => backgroundStatus = value);
  });

  void openCategory(String value) {
    switch (value) {
      case 'source':
        context.go('/browse');
      case 'download':
        context.go('/downloads');
      case 'backup':
        openSettingsPage(context, const AutomaticBackupScreen());
      case 'sync':
        openSettingsPage(context, const SyncScreen());
      case 'database':
        openSettingsPage(context, const LibraryDiagnosticsScreen());
      case 'background':
        context.go('/downloads');
      default:
        openSettingsPage(context, const LibraryDiagnosticsScreen());
    }
  }

  String label(String value) => switch (value) {
    'app' => 'Ứng dụng',
    'source' => 'Nguồn',
    'download' => 'Tải xuống',
    'backup' => 'Sao lưu',
    'sync' => 'Đồng bộ',
    'background' => 'Tác vụ nền',
    'database' => 'Thư viện',
    'files' => 'Tệp',
    'network' => 'Kết nối',
    _ => 'Tất cả',
  };
  @override
  Widget build(BuildContext context) {
    ref.watch(diagnosticLogChangesProvider);
    final queue = ref.watch(downloadQueueProvider);
    final update = ref.watch(libraryUpdateProgressProvider);
    final updateResult = ref.watch(libraryUpdateReportProvider);
    final backup = ref.watch(automaticBackupStatusProvider);
    final sync = ref.watch(syncProvider);
    final private = ref.watch(settingsProvider.select((s) => s.incognitoMode));
    final device = ref.watch(deviceToolsProvider);
    final canShare = device is! NativeDeviceTools || device.supported;
    List<DiagnosticEvent> events;
    String? storageError;
    try {
      events = ref.read(diagnosticLogProvider).read().reversed.toList();
    } catch (_) {
      events = [];
      storageError = 'Không đọc được nhật ký trên máy. Dữ liệu gốc được giữ; bạn có thể xóa sau khi xác nhận.';
    }
    final visible = events
        .where((event) => category == 'all' || category == event.category)
        .toList();
    final failedDownloads = queue.tasks
        .where((job) => job.status == DownloadJobStatus.failed)
        .length;
    final pending = queue.tasks
        .where(
          (job) =>
              job.status == DownloadJobStatus.pending ||
              job.status == DownloadJobStatus.paused,
        )
        .length;
    return SettingsPage(
      title: 'Nhật ký & Chẩn đoán',
      children: [
        const SettingsRow(
          title: 'TachiBooks',
          subtitle: 'Phiên bản 1.0.0 · bản 8',
          showChevron: false,
        ),
        const SettingsNote(
          'Nhật ký chỉ lưu loại lỗi, mã lỗi và thời gian trên thiết bị này. Nội dung truyện, liên kết, tài khoản và cookie không được ghi vào nhật ký.',
        ),
        if (private)
          const SettingsNote(
            'Chế độ riêng tư đang bật. Nhật ký mới không được lưu và không thể xuất.',
          ),
        SettingsRow(
          title: 'Xuất nhật ký lỗi',
          icon: CupertinoIcons.doc,
          onTap: busy || private ? null : () => export(),
        ),
        SettingsRow(
          title: 'Chia sẻ file nhật ký',
          icon: CupertinoIcons.share,
          onTap: busy || private || !canShare
              ? null
              : () => export(share: true),
        ),
        SettingsRow(
          title: 'Xóa nhật ký trên máy',
          icon: CupertinoIcons.trash,
          onTap: busy ? null : clear,
        ),
        const Divider(),
        SettingsRow(
          title: 'Nguồn truyện',
          subtitle: update == null
              ? 'Không có lượt cập nhật đang chạy · ${updateResult?.failures.length ?? 0} lỗi ở lượt gần nhất'
              : 'Đã kiểm tra ${update.processedBooks}/${update.requestedBooks} truyện · ${update.failedBooks} lỗi',
          onTap: () => openCategory('source'),
        ),
        SettingsRow(
          title: 'Tải xuống',
          subtitle:
              '${queue.running ? 'Đang chạy' : 'Đang dừng'} · $pending chương chờ · $failedDownloads chương lỗi${queue.storageError == null ? '' : ' · lỗi dữ liệu hàng đợi'}',
          onTap: () => openCategory('download'),
        ),
        SettingsRow(
          title: 'Sao lưu',
          subtitle: switch (backup.stage) {
            AutomaticBackupRunStage.idle => 'Chưa có lượt sao lưu tự động',
            AutomaticBackupRunStage.running => 'Đang sao lưu',
            AutomaticBackupRunStage.succeeded => 'Lượt gần nhất hoàn tất',
            AutomaticBackupRunStage.failed => 'Lượt gần nhất chưa hoàn tất',
            AutomaticBackupRunStage.interrupted => 'Lượt trước bị gián đoạn',
          },
          onTap: () => openCategory('backup'),
        ),
        SettingsRow(
          title: 'Đồng bộ',
          subtitle: sync.busy
              ? 'Đang đồng bộ'
              : sync.conflict
              ? 'Có xung đột cần xử lý'
              : sync.error
              ? 'Lượt gần nhất chưa hoàn tất'
              : sync.lastSyncedAt != null
              ? 'Lượt gần nhất hoàn tất'
              : 'Chưa có lượt đồng bộ hoàn tất',
          onTap: () => openCategory('sync'),
        ),
        SettingsRow(
          title: 'Tác vụ nền',
          subtitle:
              'Cập nhật ${update == null ? 'đang nghỉ' : 'đang chạy'} · tải xuống ${queue.running ? 'đang chạy' : 'đang nghỉ'}. iOS quyết định thời gian chạy nền.',
          onTap: () => openCategory('background'),
        ),
        SettingsRow(
          title: 'Kiểm tra trạng thái nền của iOS',
          subtitle: backgroundStatus == null
              ? 'Chưa đọc trạng thái đăng ký và thời gian chạy được iOS cấp'
              : !backgroundStatus!.containsKey('backgroundRunning')
              ? 'Thiết bị chưa cung cấp trạng thái nền'
              : 'Đã yêu cầu: ${backgroundStatus!['backgroundRequested'] == 1 ? 'có' : 'chưa'} · đang được cấp thời gian: ${backgroundStatus!['backgroundRunning'] == 1 ? 'có' : 'không'}',
          onTap: busy || private ? null : checkBackground,
        ),
        const Divider(),
        SettingsRow(
          title: 'Kiểm tra engine và extension',
          subtitle: 'Đọc trạng thái engine và các gói đã cài',
          trailing: checkingEngines ? const CupertinoActivityIndicator() : null,
          onTap: checkingEngines || private ? null : checkEngines,
        ),
        for (final engine in SourceEngine.values) ...[
          if (engines.containsKey(engine))
            SettingsRow(
              title: engine == SourceEngine.tachimanga ? 'Tachimanga' : 'vBook',
              subtitle:
                  '${engines[engine]} · ${packages[engine]?.length ?? 0} gói đã cài',
              showChevron: false,
            ),
          for (final package in packages[engine] ?? <CatalogueExtension>[])
            SettingsRow(
              title: RegExp(r'^[a-zA-Z0-9_.-]{1,200}$').hasMatch(package.id)
                  ? package.id
                  : 'Extension',
              subtitle:
                  RegExp(r'^[a-zA-Z0-9.+_-]{1,64}$').hasMatch(package.version)
                  ? 'Phiên bản ${package.version}'
                  : 'Không có thông tin phiên bản',
              showChevron: false,
            ),
        ],
        const Divider(),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: DropdownButtonFormField<String>(
            initialValue: category,
            decoration: const InputDecoration(labelText: 'Loại lỗi'),
            items: [
              for (final value in ['all', ...DiagnosticEvent.categories])
                DropdownMenuItem(value: value, child: Text(label(value))),
            ],
            onChanged: (value) => setState(() => category = value ?? 'all'),
          ),
        ),
        if (storageError != null) SettingsNote(storageError),
        if (storageError == null && visible.isEmpty)
          const SettingsNote('Chưa có lỗi được ghi cho mục này.'),
        for (final event in visible)
          SettingsRow(
            title: '${label(event.category)} · ${event.code}',
            subtitle: '${event.message}\n${event.at.toLocal()}',
            onTap: () => openCategory(event.category),
          ),
        const SettingsNote(
          'Mở mục có lỗi để xem kết quả và dùng nút Thử lại của tác vụ đó. Nhật ký không tự chạy lại việc tải, sao lưu hoặc đồng bộ.',
        ),
      ],
    );
  }
}
