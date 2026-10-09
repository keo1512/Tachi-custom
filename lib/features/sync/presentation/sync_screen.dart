import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../settings/presentation/settings_widgets.dart';
import '../../settings/presentation/backup_settings_screen.dart';
import '../application/sync_controller.dart';

class AccountScreen extends ConsumerWidget {
  const AccountScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(syncProvider);
    final controller = ref.read(syncProvider.notifier);
    final user = state.user;
    return SettingsPage(
      title: 'Tài khoản',
      children: [
        if (user == null) ...[
          const SettingsNote(
            'Đăng nhập Google để đồng bộ thư viện giữa các thiết bị. Bạn có thể đọc và sao lưu file khi chưa đăng nhập.',
          ),
          SettingsRow(
            title: 'Đăng nhập bằng Google',
            icon: CupertinoIcons.person_crop_circle,
            trailing: state.busy ? const CupertinoActivityIndicator() : null,
            onTap: state.busy ? null : controller.signIn,
          ),
        ] else ...[
          SettingsRow(
            title: user.name ?? 'Tài khoản Google',
            subtitle: user.email,
            icon: CupertinoIcons.person_crop_circle,
            showChevron: false,
          ),
          SettingsRow(
            title: 'Đồng bộ thư viện',
            icon: CupertinoIcons.cloud,
            subtitle: state.enabled ? 'Đang bật' : 'Đang tắt',
            onTap: () => openSettingsPage(context, const SyncScreen()),
          ),
          SettingsRow(
            title: 'Đăng xuất',
            icon: CupertinoIcons.square_arrow_right,
            onTap: state.busy ? null : controller.signOut,
            trailing: state.busy ? const CupertinoActivityIndicator() : null,
          ),
        ],
        if (state.message?.isNotEmpty == true) SettingsNote(state.message!),
      ],
    );
  }
}

class SyncScreen extends ConsumerWidget {
  const SyncScreen({super.key});

  Future<void> _resolve(
    BuildContext context,
    WidgetRef ref,
    bool keepLocal,
  ) async {
    final pending = ref.read(syncProvider.notifier).pendingConflict;
    if (pending == null) return;
    final accepted = await showCupertinoDialog<bool>(
      context: context,
      builder: (context) => CupertinoAlertDialog(
        title: Text(keepLocal ? 'Giữ bản trên máy?' : 'Dùng bản cloud?'),
        content: Text(
          keepLocal
              ? 'Bản trên máy sẽ trở thành bản cloud hiện tại. Các bản cloud gần nhất vẫn được giữ để phục hồi.'
              : 'Thư viện trên máy sẽ được thay bằng bản cloud. Bản trên máy hiện tại được lưu làm bản phục hồi trước khi thay.',
        ),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Hủy'),
          ),
          CupertinoDialogAction(
            isDefaultAction: true,
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Xác nhận'),
          ),
        ],
      ),
    );
    if (accepted == true && context.mounted) {
      await ref.read(syncProvider.notifier).resolve(keepLocal: keepLocal);
    }
  }

  String _summary(Uint8List source) {
    final json = jsonDecode(utf8.decode(source)) as Map<String, dynamic>;
    final entries = json['entries'] as List;
    final chapters = entries.fold<int>(
      0,
      (sum, item) =>
          sum + (((item as Map)['book'] as Map)['chapters'] as List).length,
    );
    final saved = entries.fold<int>(
      0,
      (sum, item) => sum + ((item as Map)['contents'] as Map).length,
    );
    return '${entries.length} sách · $chapters chương · $saved nội dung đã lưu';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(syncProvider);
    final controller = ref.read(syncProvider.notifier);
    final conflict = controller.pendingConflict;
    return SettingsPage(
      title: 'Đồng bộ',
      children: [
        if (state.user == null) ...[
          const SettingsNote('Đăng nhập Google trước khi bật đồng bộ.'),
          SettingsRow(
            title: 'Tài khoản',
            icon: CupertinoIcons.person_crop_circle,
            onTap: () => openSettingsPage(context, const AccountScreen()),
          ),
        ] else ...[
          SettingsRow(
            title: 'Đồng bộ thư viện',
            subtitle: state.user!.email,
            icon: CupertinoIcons.cloud,
            trailing: state.busy
                ? const CupertinoActivityIndicator()
                : CupertinoSwitch(
                    value: state.enabled,
                    onChanged: (value) => value
                        ? controller.sync(enable: true)
                        : controller.pause(),
                  ),
            showChevron: false,
          ),
          SettingsRow(
            title: 'Đồng bộ ngay',
            icon: CupertinoIcons.arrow_2_circlepath,
            onTap: state.busy || !state.enabled
                ? null
                : () => controller.sync(),
            showChevron: false,
          ),
          if (state.lastSyncedAt != null)
            SettingsNote(
              'Lần đồng bộ thành công: ${state.lastSyncedAt!.toLocal().toString().split('.').first}',
            ),
        ],
        if (state.message?.isNotEmpty == true) SettingsNote(state.message!),
        if (state.conflict && conflict != null) ...[
          const SettingsHeading('Hai bản thư viện khác nhau'),
          SettingsNote(
            'Trên máy: ${_summary(conflict.local)}\nCloud: ${_summary(conflict.remote)}',
          ),
          SettingsRow(
            title: 'Giữ bản trên máy',
            icon: CupertinoIcons.device_phone_portrait,
            onTap: state.busy ? null : () => _resolve(context, ref, true),
          ),
          SettingsRow(
            title: 'Dùng bản cloud',
            icon: CupertinoIcons.cloud_download,
            onTap: state.busy ? null : () => _resolve(context, ref, false),
          ),
        ],
        const SettingsHeading('Sao lưu đầy đủ'),
        SettingsRow(
          title: 'Sao lưu & Khôi phục',
          icon: CupertinoIcons.arrow_counterclockwise,
          onTap: () => openSettingsPage(context, const BackupSettingsScreen()),
        ),
        const SettingsNote(
          'Đồng bộ sách, tiến độ, dấu trang và toàn bộ nội dung chương đã lưu trong file sao lưu TachiBooks. Thiết lập ứng dụng và hàng đợi tải nằm riêng trên từng máy. Không tự cắt bỏ nội dung để giảm kích thước.',
        ),
        const SettingsNote(
          'Mỗi bản cloud chứa toàn bộ nội dung đã lưu, tối đa 128 MiB giống giới hạn file sao lưu. Ba bản cloud gần nhất được giữ; quá trình dọn bản cũ chỉ chạy khi xác minh được chúng không còn thuộc ba bản này. Firebase miễn phí có hạn mức tổng dung lượng và số thao tác. Bản tải lên dở dang có thể còn trên cloud; khi hết hạn mức, thư viện trên máy vẫn được giữ nguyên.',
        ),
        const SettingsNote(
          'Khi bật đồng bộ, thay đổi được gửi sau một khoảng chờ và khi mở lại ứng dụng. Đồng bộ tự động chạy khi ứng dụng ở phía trước; iOS không được yêu cầu chạy tác vụ nền. Không thể cập nhật cloud khi mất mạng.',
        ),
      ],
    );
  }
}
