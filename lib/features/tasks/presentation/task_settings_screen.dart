import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/widgets/feedback.dart';
import '../../settings/presentation/settings_widgets.dart';
import '../application/task_notifications.dart';

class TaskSettingsScreen extends ConsumerStatefulWidget {
  const TaskSettingsScreen({super.key});
  @override
  ConsumerState<TaskSettingsScreen> createState() => _TaskSettingsState();
}

class _TaskSettingsState extends ConsumerState<TaskSettingsScreen> {
  bool busy = false;
  Future<void> change(bool value) async {
    setState(() => busy = true);
    try {
      await perform(
        context,
        () => ref.read(taskNotificationsProvider.notifier).setEnabled(value),
      );
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => SettingsPage(
    title: 'Thông báo và tác vụ',
    children: [
      SettingsRow(
        title: 'Thông báo kết quả',
        subtitle: 'Kết quả tải, tạm dừng chạy nền và chương mới',
        trailing: CupertinoSwitch(
          value: ref.watch(taskNotificationsProvider),
          onChanged: busy ? null : change,
        ),
      ),
      const SettingsNote(
        'Thông báo chỉ chứa số lượng, không hiện tên truyện, nguồn hay tài khoản. Phiên ẩn danh không gửi thông báo. Chạm thông báo chương mới để mở đúng truyện; thông báo kết quả hoặc tạm dừng mở Tải xuống/Cập nhật. App vẫn yêu cầu mở khóa nếu đã bật khóa ứng dụng.',
      ),
      const SettingsHeading('Khi chuyển sang ứng dụng khác'),
      const SettingsNote(
        'Tải đang chạy tiếp tục trong khoảng thời gian iOS cho phép. App cũng gửi yêu cầu xử lý phần còn lại khi hệ thống cấp một lượt chạy nền và engine app đang sẵn sàng. iOS quyết định thời điểm và có thể từ chối yêu cầu; mỗi lượt chạy có giới hạn. Khi hết thời gian, chương đã tải và hàng đợi được giữ lại. Bạn có thể mở app và bấm Tiếp tục bất cứ lúc nào.',
      ),
      const SettingsNote(
        'Thông báo tạm dừng được chuẩn bị bằng số lượng trước khi iOS hết thời gian; không cần Dart chạy để tạo nội dung thông báo. Tải nền vẫn dùng engine nguồn gốc để giữ giải mã và biến đổi ảnh. App không đảm bảo tiếp tục sau khi bạn buộc đóng ứng dụng; phiên từng bật ẩn danh không tạo yêu cầu tiếp tục tự động.',
      ),
    ],
  );
}
