import 'package:flutter/cupertino.dart';

import '../../downloads/presentation/download_settings_screen.dart'
    as downloads;
import '../../sync/presentation/sync_screen.dart';
import 'advanced_settings_screen.dart';
import 'app_settings_screens.dart';
import 'settings_widgets.dart';
import 'storage_maintenance_screen.dart';
import 'tracking_settings_screen.dart';

class SettingsHomeScreen extends StatelessWidget {
  const SettingsHomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    void open(Widget page) => openSettingsPage(context, page);
    return SettingsPage(
      title: 'Cài đặt',
      children: [
        const SettingsHeading('Ứng dụng'),
        SettingsRow(
          icon: CupertinoIcons.slider_horizontal_3,
          title: 'Chung',
          subtitle: 'Điều hướng, nhập truyện và tác vụ',
          onTap: () => open(const GeneralSettingsScreen()),
        ),
        SettingsRow(
          icon: CupertinoIcons.paintbrush,
          title: 'Giao diện',
          subtitle: 'Chủ đề và hiển thị',
          onTap: () => open(const AppearanceSettingsScreen()),
        ),
        SettingsRow(
          icon: CupertinoIcons.book_fill,
          title: 'Thư viện',
          subtitle: 'Danh mục, bố cục và cập nhật',
          onTap: () => open(const LibrarySettingsScreen()),
        ),
        const SettingsHeading('Đọc và tải truyện'),
        SettingsRow(
          icon: CupertinoIcons.compass,
          title: 'Nguồn',
          subtitle: 'Kho tiện ích và tùy chọn nguồn',
          onTap: () => open(const ExtensionSettingsScreen()),
        ),
        SettingsRow(
          icon: CupertinoIcons.book,
          title: 'Trình đọc',
          subtitle: 'Truyện tranh, truyện chữ và đọc thành tiếng',
          onTap: () => open(const ReaderSettingsScreen()),
        ),
        SettingsRow(
          icon: CupertinoIcons.arrow_down_circle,
          title: 'Tải xuống',
          subtitle: 'Hàng chờ, tự tải và xóa sau đọc',
          onTap: () => open(const downloads.DownloadSettingsScreen()),
        ),
        const SettingsHeading('Dữ liệu và riêng tư'),
        SettingsRow(
          icon: CupertinoIcons.arrow_2_circlepath,
          title: 'Trạng thái và đánh giá',
          subtitle: 'Trạng thái và điểm đọc trong thư viện',
          onTap: () => open(const TrackingSettingsScreen()),
        ),
        SettingsRow(
          icon: CupertinoIcons.shield_lefthalf_fill,
          title: 'Bảo mật',
          subtitle: 'Khóa ứng dụng và bảo vệ màn hình',
          onTap: () => open(const PrivacySettingsScreen()),
        ),
        SettingsRow(
          icon: CupertinoIcons.cloud,
          title: 'Đồng bộ',
          subtitle: 'Tài khoản Google, sao lưu và khôi phục',
          onTap: () => open(const SyncScreen()),
        ),
        SettingsRow(
          icon: CupertinoIcons.archivebox,
          title: 'Lưu trữ',
          subtitle: 'Nội dung đã lưu và bộ nhớ tạm',
          onTap: () => open(const StorageMaintenanceScreen()),
        ),
        SettingsRow(
          icon: CupertinoIcons.wrench,
          title: 'Nâng cao và chẩn đoán',
          subtitle: 'Mạng, nhật ký và phục hồi thư viện',
          onTap: () => open(const AdvancedSettingsScreen()),
        ),
      ],
    );
  }
}
