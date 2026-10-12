import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/widgets/feedback.dart';
import '../../library/data/backup_compatibility/backup_reader.dart';
import '../../library/data/library_recovery_store.dart';
import '../../library/data/library_repository.dart';
import '../../library/data/library_snapshot.dart';
import '../../privacy/application/app_lock_controller.dart';
import '../../settings/settings_controller.dart';
import 'settings_widgets.dart';

class LibraryRecoveryScreen extends ConsumerStatefulWidget {
  const LibraryRecoveryScreen({
    super.key,
    required this.store,
    required this.retry,
    this.pickBackup,
    this.startupError,
  });
  final LibraryRecoveryStore store;
  final Future<void> Function() retry;
  final Future<Uint8List?> Function()? pickBackup;
  final String? startupError;

  @override
  ConsumerState<LibraryRecoveryScreen> createState() => _LibraryRecoveryState();
}

class _LibraryRecoveryState extends ConsumerState<LibraryRecoveryScreen> {
  bool busy = false;
  int privacyRevision = 0;
  String? result;

  void _guard(int expected) {
    final lock = ref.read(appLockProvider);
    if (!mounted ||
        expected != privacyRevision ||
        !lock.initialized ||
        !lock.configurationValid ||
        lock.locked ||
        lock.authenticating ||
        lock.obscured) {
      throw StateError(
        'Phiên phục hồi đã thay đổi. Mở khóa rồi chọn lại bản sao lưu.',
      );
    }
  }

  Future<void> _restore({required bool previous}) async {
    if (busy) return;
    final privacy = privacyRevision;
    setState(() {
      busy = true;
      result = null;
    });
    try {
      _guard(privacy);
      final selection = await widget.store.selection(forRecovery: true);
      _guard(privacy);
      final Uint8List? bytes;
      if (previous) {
        bytes = await widget.store.latestRecovery(selection);
      } else if (widget.pickBackup != null) {
        bytes = await widget.pickBackup!();
      } else {
        final selected = await FilePicker.pickFile(
          dialogTitle: 'Chọn bản sao lưu để phục hồi thư viện',
          type: FileType.custom,
          allowedExtensions: ['json', 'tmb', 'tachibk', 'gz', 'backup'],
        );
        _guard(privacy);
        if (selected == null) return;
        if ((await selected.length() ?? 0) > LibrarySnapshot.maxBytes) {
          throw const FormatException('Bản sao lưu vượt giới hạn 128 MB.');
        }
        bytes = await selected.readAsBytes();
      }
      _guard(privacy);
      if (!mounted) return;
      if (bytes == null) {
        if (previous) {
          message(
            context,
            'Không tìm thấy bản phục hồi hợp lệ trên máy. Hãy chọn file sao lưu.',
          );
        }
        return;
      }
      final converted = await readCompatibleBackup(
        bytes,
        MemoryLibraryRepository(),
      );
      _guard(privacy);
      if (!mounted) return;
      final image = converted.snapshot;
      final chapters = image.entries.fold<int>(
        0,
        (n, e) => n + e.contents.length,
      );
      final confirmed = await showCupertinoDialog<bool>(
        context: context,
        builder: (ctx) => CupertinoAlertDialog(
          title: const Text('Phục hồi thư viện từ bản sao lưu?'),
          content: SizedBox(
            height: 190,
            child: SingleChildScrollView(
              child: Text(
                '${converted.format}\n${image.entries.length} truyện, $chapters chương có nội dung lưu.\n\n'
                'Thư viện mới chỉ gồm dữ liệu có trong file. Dữ liệu gốc và file đã chọn được giữ riêng trước khi sửa. '
                'Ứng dụng mở lại cơ sở dữ liệu mới và kiểm tra nội dung trước khi sử dụng. '
                'Thiết lập, tài khoản và extension đang có trên máy được giữ. '
                '${image.configuration != null || image.extensions != null ? 'Cấu hình và gói nguồn trong file được giữ cùng bản gốc để có thể nhập riêng trong Sao lưu & Khôi phục sau đó. ' : ''}'
                'Các bản sao lưu chỉ có tên/chương sẽ không tạo ra trang truyện offline còn thiếu.',
              ),
            ),
          ),
          actions: [
            CupertinoDialogAction(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Hủy'),
            ),
            CupertinoDialogAction(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Giữ dữ liệu gốc và phục hồi'),
            ),
          ],
        ),
      );
      _guard(privacy);
      if (confirmed != true) return;
      setState(
        () => result = 'Đang giữ dữ liệu gốc, tạo và kiểm tra thư viện mới…',
      );
      final restored = await widget.store.restore(
        snapshot: image,
        sourceBytes: bytes,
        expectedSelectionToken: selection.token,
        guard: () => _guard(privacy),
      );
      _guard(privacy);
      setState(
        () => result =
            'Đã phục hồi và kiểm tra ${restored.snapshot.entries.length} truyện. '
            'Đã giữ ${restored.copiedFiles} tệp dữ liệu gốc. Chạm Mở lại ứng dụng để sử dụng thư viện mới.',
      );
    } catch (error) {
      if (mounted) {
        setState(
          () => result = 'Phục hồi chưa hoàn tất: ${userFacingError(error)}',
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(appLockProvider, (_, next) {
      if (next.locked ||
          next.authenticating ||
          next.obscured ||
          !next.configurationValid) {
        privacyRevision++;
      }
    });
    ref.listen(
      settingsProvider.select((s) => s.incognitoMode),
      (_, _) => privacyRevision++,
    );
    return SettingsPage(
      title: 'Phục hồi thư viện',
      children: [
        const SettingsNote(
          'Chế độ phục hồi đã đóng các tác vụ và cơ sở dữ liệu đang dùng. Dữ liệu gốc được giữ nguyên.',
        ),
        if (widget.startupError != null) SettingsNote(widget.startupError!),
        if (result != null) SettingsNote(result!),
        if (busy)
          const SettingsRow(
            title: 'Đang kiểm tra hoặc phục hồi…',
            trailing: CupertinoActivityIndicator(),
          ),
        SettingsRow(
          title: 'Chọn bản sao lưu hợp lệ',
          icon: CupertinoIcons.arrow_down_doc,
          onTap: busy ? null : () => _restore(previous: false),
        ),
        SettingsRow(
          title: 'Dùng bản phục hồi trước lần sửa gần nhất',
          icon: CupertinoIcons.arrow_counterclockwise,
          onTap: busy ? null : () => _restore(previous: true),
        ),
        SettingsRow(
          title: 'Mở lại ứng dụng',
          icon: CupertinoIcons.refresh,
          onTap: busy
              ? null
              : () async {
                  setState(() => busy = true);
                  try {
                    await widget.retry();
                  } finally {
                    if (mounted) setState(() => busy = false);
                  }
                },
        ),
        const SettingsNote(
          'Không xóa cơ sở dữ liệu cũ hoặc tự tạo nội dung bị mất. '
          'Nếu không có bản sao lưu hợp lệ, giữ dữ liệu để kiểm tra tiếp. '
          'Cần đủ dung lượng cho bản giữ dữ liệu gốc và thư viện mới. '
          'Mở lại ứng dụng ở đây khởi tạo lại giao diện và bộ nhớ; không buộc iOS thoát tiến trình.',
        ),
      ],
    );
  }
}
