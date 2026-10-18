import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/platform/device_tools.dart';
import '../../../core/widgets/feedback.dart';
import '../../sources/application/source_maintenance.dart';
import 'settings_widgets.dart';

class NetworkToolsScreen extends ConsumerStatefulWidget {
  const NetworkToolsScreen({super.key});
  @override
  ConsumerState<NetworkToolsScreen> createState() => _NetworkToolsState();
}

class _NetworkToolsState extends ConsumerState<NetworkToolsScreen> {
  bool busy = false;
  Future<void> confirm(
    String title,
    String description,
    Future<void> Function() action,
  ) async {
    if (busy) return;
    final approved = await showCupertinoDialog<bool>(
      context: context,
      builder: (ctx) => CupertinoAlertDialog(
        title: Text(title),
        content: Text(description),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Hủy'),
          ),
          CupertinoDialogAction(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Thực hiện'),
          ),
        ],
      ),
    );
    if (approved != true || !mounted) return;
    setState(() => busy = true);
    try {
      await perform(
        context,
        action,
        success: 'Đã hoàn tất thao tác trên thiết bị.',
      );
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => SettingsPage(
    title: 'WebView & mạng',
    children: [
      const SettingsNote(
        'Mở trang web từ nguồn, chi tiết truyện hoặc trình đọc. Trình duyệt trong app có quay lại, tiến tới, tải lại, mở ngoài, chỉnh User-Agent và xóa cookie của nguồn. Bấm Xong để lưu phiên vào engine của nguồn.',
      ),
      SettingsRow(
        title: 'Xóa cookie nguồn trên máy',
        icon: CupertinoIcons.clear,
        trailing: busy ? const CupertinoActivityIndicator() : null,
        onTap: busy
            ? null
            : () => confirm(
                'Xóa cookie nguồn?',
                'Các website nguồn có thể yêu cầu đăng nhập hoặc xác minh lại. Tài khoản Google đồng bộ được giữ.',
                () => ref.read(sourceMaintenanceProvider).clearCookies(),
              ),
      ),
      SettingsRow(
        title: 'Xóa dữ liệu WebView',
        icon: CupertinoIcons.globe,
        onTap: busy
            ? null
            : () => confirm(
                'Xóa dữ liệu website?',
                'Xóa cookie, cache và dữ liệu trang của WebKit trên máy; giữ sách offline, gói nguồn và tùy chọn nguồn. Website có thể yêu cầu đăng nhập lại.',
                () => ref.read(sourceMaintenanceProvider).clearWebData(),
              ),
      ),
      SettingsRow(
        title: 'Khôi phục tất cả User-Agent mặc định',
        onTap: busy
            ? null
            : () => confirm(
                'Đặt lại User-Agent?',
                'Đặt lại User-Agent của engine và trình duyệt, đóng trang nguồn đang mở và giữ cookie đăng nhập. Website có thể yêu cầu xác minh lại.',
                () => ref.read(sourceMaintenanceProvider).resetUserAgents(),
              ),
      ),
      SettingsRow(
        title: 'Đặt lại domain đã ẩn Cloudflare',
        onTap: busy
            ? null
            : () => confirm(
                'Hiện lại thông báo Cloudflare?',
                'Thông báo HTTP/xác minh bị ẩn trên các domain sẽ được hiển thị lại.',
                () => ref.read(deviceToolsProvider).resetMutedDomains(),
              ),
      ),
      const SettingsNote(
        'Ẩn thông báo theo domain trong 24 giờ từ menu trang nguồn. Trang và lỗi HTTP vẫn được giữ để bạn xử lý. Khả năng hoàn tất Cloudflare phụ thuộc website và WebKit; app không bỏ qua xác minh. Lỗi mạng và thời gian chờ được báo bằng tiếng Việt, có tải lại hoặc thử lại từ màn đang dùng.',
      ),
    ],
  );
}
