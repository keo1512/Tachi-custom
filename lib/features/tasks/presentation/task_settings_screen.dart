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
      const SettingsHeading('Dynamic Island và màn hình khóa'),
      const SettingsNote(
        'Khi bạn bấm tải, kiểm tra truyện hoặc Sao lưu ngay trên iOS hỗ trợ, hệ thống có thể hiện tiến độ trong Dynamic Island và màn hình khóa. Nút Dừng của hệ thống tạm dừng đúng lượt công việc đang hiển thị; dữ liệu đã hoàn tất được giữ lại. Giao diện và thời gian được cấp do iOS quản lý.',
      ),
      const SettingsNote(
        'Chỉ hiện loại công việc và số lượng; không có tên truyện, nguồn, tài khoản hay chi tiết lỗi. Khóa app, ẩn danh hoặc khôi phục dữ liệu sẽ xóa tiến độ khỏi giao diện hệ thống. Phiên từng bật ẩn danh tiếp tục được giữ kín đến khi kết thúc. Tùy chọn thông báo kết quả ở trên hoạt động riêng.',
      ),
      const SettingsNote(
        'Yêu cầu tiếp tục công việc cần được khởi tạo khi app đang mở; iOS có thể từ chối. Lịch kiểm tra chương và sao lưu nền vẫn do iOS quyết định, có thể bị hoãn hoặc dừng và không bảo đảm chạy đúng giờ, đặc biệt sau khi buộc đóng app.',
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
