import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/format/vietnamese_format.dart';
import '../../../core/platform/device_tools.dart';
import '../../../core/widgets/feedback.dart';
import '../../downloads/presentation/download_queue_controller.dart';
import '../../library/application/library_diagnostics.dart';
import '../../library/application/library_update_report.dart';
import '../../library/application/storage_maintenance.dart';
import '../../library/data/library_cache_maintenance.dart';
import '../../library/data/library_mutation.dart';
import '../../library/presentation/library_view_model.dart';
import '../../privacy/application/app_lock_controller.dart';
import '../../sources/application/source_maintenance.dart';
import '../settings_controller.dart';
import 'settings_widgets.dart';

class StorageMaintenanceScreen extends ConsumerStatefulWidget {
  const StorageMaintenanceScreen({super.key});
  @override
  ConsumerState<StorageMaintenanceScreen> createState() =>
      _StorageMaintenanceState();
}

class _StorageMaintenanceState extends ConsumerState<StorageMaintenanceScreen> {
  bool busy = false;
  bool cancelled = false;
  LibraryStorageReport? report;
  Map<String, int> usage = const {};
  String? progress;
  int _privacyGeneration = 0;
  int? _operationPrivacyGeneration;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_inspect()));
  }

  void _guard([int? revision]) {
    final lock = ref.read(appLockProvider);
    if (!mounted ||
        cancelled ||
        !lock.initialized ||
        lock.authenticating ||
        lock.locked ||
        lock.obscured ||
        !lock.configurationValid ||
        (_operationPrivacyGeneration != null &&
            _operationPrivacyGeneration != _privacyGeneration)) {
      throw StateError(
        'Đã dừng thao tác. Hãy mở khóa ứng dụng và kiểm tra lại.',
      );
    }
    if (ref.read(downloadQueueProvider).running ||
        ref.read(libraryUpdateExecutionProvider).hasWork) {
      throw StateError(
        'Hãy tạm dừng tải và chờ cập nhật thư viện xong trước khi dọn dữ liệu.',
      );
    }
    checkLibraryRevision(
      ref.read(libraryRepositoryProvider).replacementRevision,
      revision,
    );
  }

  Future<void> _run(Future<void> Function() action) async {
    if (busy) return;
    setState(() {
      busy = true;
      cancelled = false;
    });
    _operationPrivacyGeneration = _privacyGeneration;
    try {
      await perform(context, action);
    } finally {
      _operationPrivacyGeneration = null;
      if (mounted) {
        setState(() {
          busy = false;
          progress = null;
        });
      }
    }
  }

  Future<void> _inspect() => _run(() async {
    await ref.read(appLockProvider.notifier).initialize();
    _guard();
    final inspected = await ref
        .read(libraryRepositoryProvider)
        .inspectStorage();
    final bytes = await ref.read(deviceToolsProvider).usage();
    _guard(inspected.revision);
    if (mounted) {
      setState(() {
        report = inspected;
        usage = bytes;
      });
    }
  });

  Future<bool> _confirm(String title, String description) async {
    await ref.read(appLockProvider.notifier).initialize();
    if (!mounted) return false;
    final generation = _privacyGeneration;
    final accepted =
        await showCupertinoDialog<bool>(
          context: context,
          builder: (dialogContext) => CupertinoAlertDialog(
            title: Text(title),
            content: Text(description),
            actions: [
              CupertinoDialogAction(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('Hủy'),
              ),
              CupertinoDialogAction(
                isDestructiveAction: true,
                onPressed: () => Navigator.pop(dialogContext, true),
                child: const Text('Tiếp tục'),
              ),
            ],
          ),
        ) ??
        false;
    return mounted && accepted && generation == _privacyGeneration;
  }

  Future<void> _clean(bool attachments) async {
    final preview = report;
    if (preview == null || busy) return;
    final count = attachments
        ? preview.unusedAttachmentFiles
        : preview.transientChapters;
    if (count == 0) {
      message(context, 'Không có dữ liệu phù hợp để dọn.');
      return;
    }
    if (!await _confirm(
      attachments ? 'Dọn tệp ảnh không còn dùng?' : 'Xóa cache chương?',
      attachments
          ? '$count tệp ảnh không còn được thư viện hoặc bản phục hồi tham chiếu sẽ được dọn. '
                'Trước khi dọn, app lưu bản phục hồi và kiểm tra lại toàn bộ dữ liệu.'
          : '$count nội dung chương tạm thời cần mạng sẽ được xóa. '
                'Truyện cục bộ, nội dung offline và mọi chương đang được đánh dấu đã tải được giữ. '
                'App lưu bản phục hồi đầy đủ trước khi sửa.',
    )) {
      return;
    }
    if (!mounted) return;
    await _run(() async {
      _guard(preview.revision);
      final repo = ref.read(libraryRepositoryProvider);
      final result = attachments
          ? await repo.collectUnusedAttachments(
              expectedFingerprint: preview.fingerprint,
              guard: () => _guard(preview.revision),
            )
          : await repo.clearTransientChapterCache(
              expectedFingerprint: preview.fingerprint,
              guard: () => _guard(preview.revision),
            );
      await ref.read(libraryProvider.notifier).refresh();
      final next = await repo.inspectStorage();
      final bytes = await ref.read(deviceToolsProvider).usage();
      if (!mounted) return;
      setState(() {
        report = next;
        usage = bytes;
      });
      message(
        context,
        attachments
            ? 'Đã dọn ${result.removedFiles} tệp · ${_formatBytes(result.reclaimedBytes)}.'
            : 'Đã dọn ${result.removedChapters} cache chương. Bản phục hồi trước khi dọn được giữ.',
      );
    });
  }

  Future<void> _deviceAction(
    String title,
    String detail,
    Future<void> Function() action,
  ) async {
    if (busy || !await _confirm(title, detail) || !mounted) return;
    await _run(() async {
      _guard();
      await action();
      if (mounted) message(context, 'Đã hoàn tất thao tác.');
    });
  }

  Future<void> _refresh(bool coversOnly) async {
    if (busy) return;
    final repository = ref.read(libraryRepositoryProvider);
    final previewRevision = repository.replacementRevision;
    final books = await repository.list();
    final online = books
        .where((book) => book.engine != 'local')
        .map((book) => book.id)
        .toList();
    if (!mounted ||
        busy ||
        !await _confirm(
          coversOnly ? 'Làm mới ảnh bìa?' : 'Làm mới thông tin truyện?',
          '${online.length} truyện từ nguồn sẽ được làm mới. Bìa tự chọn, tên khác, ghi chú, '
          'vị trí đọc và nội dung offline được giữ. Truyện cục bộ không gọi nguồn.',
        )) {
      return;
    }
    if (!mounted) return;
    await _run(() async {
      _guard(previewRevision);
      final repo = ref.read(libraryRepositoryProvider);
      final revision = previewRevision;
      final result =
          await StorageMaintenance(
            repo,
            ref.read(sourceRepositoryProvider),
          ).refreshBooks(
            online,
            coversOnly: coversOnly,
            expectedRevision: revision,
            guard: () => _guard(revision),
            onProgress: (completed, total) {
              if (mounted) {
                setState(() => progress = '$completed/$total truyện');
              }
            },
          );
      await ref.read(libraryProvider.notifier).refresh();
      if (mounted) {
        message(
          context,
          'Đã làm mới ${result.updated} truyện, ${result.failed} lỗi, ${result.skipped} bỏ qua.',
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(appLockProvider, (_, next) {
      if (next.locked ||
          next.obscured ||
          next.authenticating ||
          !next.configurationValid) {
        _privacyGeneration++;
      }
    });
    ref.listen(
      settingsProvider.select((value) => value.incognitoMode),
      (_, _) => _privacyGeneration++,
    );
    return SettingsPage(
      title: 'Bộ nhớ và cache',
      children: [
        SettingsRow(
          title: 'Kiểm tra lại dung lượng',
          icon: CupertinoIcons.refresh,
          trailing: busy ? const CupertinoActivityIndicator() : null,
          onTap: busy ? null : _inspect,
        ),
        if (progress != null)
          SettingsRow(
            title: progress!,
            trailing: TextButton(
              onPressed: () => setState(() => cancelled = true),
              child: const Text('Dừng'),
            ),
          ),
        const SettingsHeading('Dung lượng trên thiết bị'),
        for (final entry in {
          'documentsBytes': 'Tài liệu ứng dụng',
          'supportBytes': 'Dữ liệu hỗ trợ',
          'temporaryBytes': 'Dữ liệu tạm',
          'libraryBytes': 'Thư viện và nội dung',
          'backupBytes': 'Bản sao lưu trên máy',
          'httpCacheBytes': 'Cache HTTP',
        }.entries)
          SettingsRow(
            title: entry.value,
            trailing: Text(
              usage[entry.key] == null
                  ? 'Chưa đo'
                  : _formatBytes(usage[entry.key]!),
            ),
          ),
        SettingsRow(
          title: 'Nội dung offline đã lưu',
          trailing: Text(
            report?.downloadedBytes == null
                ? 'Chưa đo'
                : _formatBytes(report!.downloadedBytes!),
          ),
        ),
        const SettingsNote(
          'Nội dung offline tính byte nội dung chương và tệp ảnh được tham chiếu, '
          'không gồm bìa hoặc phần phân bổ của file cơ sở dữ liệu. Dung lượng các nhóm có thể giao nhau; '
          'không cộng chúng thành tổng. Bản sao lưu trong Files/iCloud nằm ngoài dung lượng đo trên máy.',
        ),
        const SettingsHeading('Dọn dữ liệu'),
        SettingsRow(
          title: 'Xóa cache ảnh',
          onTap: busy
              ? null
              : () => _deviceAction('Xóa cache ảnh?', 'Ảnh đã lưu offline và bìa tự chọn được giữ. Ảnh tạm có thể tải lại từ nguồn.', () async {
                  await ref.read(deviceToolsProvider).clearHttpCache();
                  PaintingBinding.instance.imageCache.clear();
                  PaintingBinding.instance.imageCache.clearLiveImages();
                }),
        ),
        SettingsRow(
          title: 'Xóa cache chương',
          subtitle:
              '${report?.transientChapters ?? 0} nội dung tạm thời cần mạng',
          onTap: busy || report == null ? null : () => _clean(false),
        ),
        SettingsRow(
          title: 'Dọn tệp ảnh không còn dùng',
          subtitle:
              '${report?.unusedAttachmentFiles ?? 0} tệp · ${_formatBytes(report?.unusedAttachmentBytes ?? 0)}',
          onTap: busy || report == null ? null : () => _clean(true),
        ),
        SettingsRow(
          title: 'Xóa cache nguồn',
          onTap: busy
              ? null
              : () => _deviceAction(
                  'Xóa cache nguồn?',
                  'Xóa cache có thể tải lại của engine và HTTP. Gói extension, tùy chọn nguồn và truyện offline được giữ.',
                  () => ref.read(sourceMaintenanceProvider).clearCaches(),
                ),
        ),
        SettingsRow(
          title: 'Xóa cookie',
          onTap: busy
              ? null
              : () => _deviceAction(
                  'Xóa cookie?',
                  'Cookie của engine nguồn và trình duyệt trong app sẽ bị xóa. Một số nguồn sẽ cần đăng nhập lại.',
                  () => ref.read(sourceMaintenanceProvider).clearCookies(),
                ),
        ),
        SettingsRow(
          title: 'Xóa dữ liệu WebView',
          onTap: busy
              ? null
              : () => _deviceAction(
                  'Xóa dữ liệu WebView?',
                  'Xóa cookie, lịch sử và dữ liệu website trong trình duyệt của app. Một số nguồn sẽ cần đăng nhập lại. Truyện offline được giữ.',
                  () => ref.read(sourceMaintenanceProvider).clearWebData(),
                ),
        ),
        const SettingsHeading('Thư viện'),
        SettingsRow(
          title: 'Quản lý truyện cục bộ',
          subtitle: '${report?.localBooks ?? 0} truyện đã nhập',
          onTap: busy ? null : _localBooks,
        ),
        SettingsRow(
          title: 'Làm mới ảnh bìa',
          onTap: busy ? null : () => _refresh(true),
        ),
        SettingsRow(
          title: 'Làm mới thông tin truyện',
          onTap: busy ? null : () => _refresh(false),
        ),
        SettingsRow(
          title: 'Quét lại chương đã tải',
          onTap: busy
              ? null
              : () => _run(() async {
                  _guard();
                  final health = await LibraryDiagnostics(
                    ref.read(libraryRepositoryProvider),
                  ).inspect();
                  if (!mounted) return;
                  message(
                    this.context,
                    'Đã kiểm tra ${health.cachedChapters} chương lưu trên máy; '
                    '${health.missingDownloads} cờ đã tải thiếu nội dung, ${health.unreadableChapters.length} chương có ảnh không đọc được. '
                    'Không tạo hoặc xóa nội dung.',
                  );
                }),
        ),
      ],
    );
  }

  Future<void> _localBooks() async {
    final books = (await ref.read(libraryRepositoryProvider).list())
        .where((book) => book.engine == 'local')
        .toList();
    if (!mounted) return;
    await Navigator.of(context).push<void>(
      CupertinoPageRoute(
        builder: (_) => Scaffold(
          appBar: AppBar(title: const Text('Truyện cục bộ')),
          body: books.isEmpty
              ? const Center(child: Text('Chưa có truyện cục bộ.'))
              : ListView.builder(
                  itemCount: books.length,
                  itemBuilder: (_, index) => SettingsRow(
                    title: books[index].title,
                    subtitle:
                        '${books[index].chapters.length} chương · Mở để đọc, xuất hoặc quản lý',
                    onTap: () => context.push(
                      '/book/${Uri.encodeComponent(books[index].id)}',
                    ),
                  ),
                ),
        ),
      ),
    );
  }
}

String _formatBytes(int bytes) {
  if (bytes < 1024) return '${vietnameseNumber(bytes)} B';
  if (bytes < 1024 * 1024) {
    return '${vietnameseNumber(bytes / 1024, decimals: 1)} KiB';
  }
  if (bytes < 1024 * 1024 * 1024) {
    return '${vietnameseNumber(bytes / (1024 * 1024), decimals: 1)} MiB';
  }
  return '${vietnameseNumber(bytes / (1024 * 1024 * 1024), decimals: 1)} GiB';
}
