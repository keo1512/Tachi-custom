import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import 'app_settings_screens.dart';
import '../../sync/presentation/sync_screen.dart';
import 'reading_info_screen.dart';
import 'settings_widgets.dart';
import 'help_licenses_screen.dart';
import '../../library/presentation/upcoming_screen.dart';

class MoreScreen extends StatelessWidget {
  const MoreScreen({super.key});

  static const syncPage = SyncScreen();

  @override
  Widget build(BuildContext context) {
    void open(Widget page) => openSettingsPage(context, page);
    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 56,
        title: const Text('Thêm'),
        titleTextStyle: TextStyle(
          color: settingsLabel(context),
          fontSize: 20,
          fontWeight: FontWeight.w400,
        ),
      ),
      body: ListView(
        padding: EdgeInsets.only(
          bottom: MediaQuery.paddingOf(context).bottom + 16,
        ),
        children: [
          SettingsRow(
            leading: const PremiumCrown(),
            title: 'TachiBooks · Cá nhân',
            height: 68,
            showChevron: false,
            onTap: () => open(
              const FeatureStatusScreen(
                title: 'TachiBooks cá nhân',
                description: 'Các chức năng trong app được mở sẵn cho bạn. Đăng nhập Google để dùng đồng bộ giữa các máy, hoặc xuất bản sao lưu đầy đủ trong Đồng bộ → Sao lưu & Khôi phục.',
              ),
            ),
          ),
          const Divider(height: .5, thickness: .5),
          SettingsRow(
            icon: CupertinoIcons.person_crop_circle_fill,
            title: 'Tài khoản',
            height: 68,
            onTap: () => open(const AccountScreen()),
          ),
          SettingsRow(
            icon: CupertinoIcons.cloud,
            title: 'Đồng bộ ngay',
            subtitle: 'Tài khoản Google và sao lưu',
            height: 68,
            onTap: () => open(syncPage),
          ),
          const Divider(height: .5, thickness: .5),
          const SizedBox(height: 8),
          SettingsRow(
            icon: CupertinoIcons.slider_horizontal_3,
            title: 'Chung',
            onTap: () => open(const GeneralSettingsScreen()),
          ),
          SettingsRow(
            icon: Icons.palette,
            title: 'Giao diện',
            onTap: () => open(const AppearanceSettingsScreen()),
          ),
          SettingsRow(
            icon: CupertinoIcons.book_fill,
            title: 'Thư viện',
            onTap: () => open(const LibrarySettingsScreen()),
          ),
          SettingsRow(
            icon: CupertinoIcons.book,
            title: 'Độc giả',
            onTap: () => open(const ReaderSettingsScreen()),
          ),
          SettingsRow(
            icon: CupertinoIcons.cloud,
            title: 'Đồng bộ',
            onTap: () => open(syncPage),
          ),
          SettingsRow(
            icon: CupertinoIcons.arrow_2_circlepath,
            title: 'Theo dõi',
            onTap: () => open(
              const FeatureStatusScreen(
                title: 'Theo dõi',
                description: 'App chưa kết nối dịch vụ tracker bên ngoài. Tiến độ đọc và dấu trang vẫn được lưu trong thư viện trên thiết bị.',
              ),
            ),
          ),
          SettingsRow(
            icon: CupertinoIcons.compass_fill,
            title: 'Phần mở rộng',
            onTap: () => open(const ExtensionSettingsScreen()),
          ),
          SettingsRow(
            icon: CupertinoIcons.shield_lefthalf_fill,
            title: 'Bảo mật',
            onTap: () => open(const PrivacySettingsScreen()),
          ),
          SettingsRow(
            icon: CupertinoIcons.chart_bar,
            title: 'Thông tin Đọc',
            onTap: () => open(const ReadingInfoScreen()),
          ),
          SettingsRow(
            icon: CupertinoIcons.calendar,
            title: 'Lịch chương dự kiến',
            onTap: () => open(const UpcomingScreen()),
          ),
          SettingsRow(
            icon: CupertinoIcons.arrow_down_to_line,
            title: 'Tải xuống Manga',
            onTap: () => open(const DownloadSettingsScreen()),
          ),
          SettingsRow(
            icon: CupertinoIcons.question_circle,
            title: 'Trợ giúp & Giấy phép',
            onTap: () => open(const HelpLicensesScreen()),
          ),
        ],
      ),
    );
  }
}
