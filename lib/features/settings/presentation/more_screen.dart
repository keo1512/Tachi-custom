import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../library/presentation/library_categories_screen.dart';
import '../../library/presentation/upcoming_screen.dart';
import '../../sync/application/sync_controller.dart';
import '../../sync/presentation/sync_screen.dart';
import '../../sources/presentation/source_migration_library_screen.dart';
import 'help_licenses_screen.dart';
import 'reading_info_screen.dart';
import 'settings_home_screen.dart';
import 'settings_widgets.dart';
import 'storage_maintenance_screen.dart';
import 'tracking_settings_screen.dart';

class MoreScreen extends ConsumerWidget {
  const MoreScreen({super.key});

  static const syncPage = SyncScreen();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    void open(Widget page) => openSettingsPage(context, page);
    final sync = ref.watch(syncProvider);
    return SettingsPage(
      title: 'Thêm',
      children: [
        SettingsRow(
          icon: CupertinoIcons.person_crop_circle,
          title: 'Tài khoản',
          subtitle:
              sync.user?.email ?? 'Đăng nhập Google để đồng bộ nhiều thiết bị',
          height: 68,
          onTap: () => open(const AccountScreen()),
        ),
        const SettingsHeading('Công cụ'),
        SettingsRow(
          icon: CupertinoIcons.arrow_down_circle,
          title: 'Tải xuống',
          subtitle: 'Hàng chờ và chương đã lưu',
          onTap: () => context.go('/downloads'),
        ),
        SettingsRow(
          icon: CupertinoIcons.chart_bar,
          title: 'Thống kê',
          subtitle: 'Thời gian đọc, tiến độ và mục tiêu',
          onTap: () => open(const ReadingInfoScreen(title: 'Thống kê')),
        ),
        SettingsRow(
          icon: CupertinoIcons.folder,
          title: 'Quản lý danh mục',
          subtitle: 'Tạo, sắp xếp và gán danh mục cho truyện',
          onTap: () => open(const LibraryCategoriesScreen()),
        ),
        SettingsRow(
          icon: CupertinoIcons.arrow_right_arrow_left,
          title: 'Chuyển nguồn',
          subtitle: 'Chọn truyện và đối chiếu nguồn mới',
          onTap: () => open(const SourceMigrationLibraryScreen()),
        ),
        SettingsRow(
          icon: CupertinoIcons.arrow_2_circlepath,
          title: 'Trạng thái và đánh giá',
          subtitle: 'Trạng thái và điểm đọc lưu trong thư viện',
          onTap: () => open(const TrackingSettingsScreen()),
        ),
        SettingsRow(
          icon: CupertinoIcons.cloud,
          title: 'Đồng bộ',
          subtitle: sync.error
              ? 'Lần đồng bộ chưa hoàn tất'
              : sync.busy
              ? 'Đang đồng bộ…'
              : sync.enabled
              ? 'Đang bật · Sao lưu và khôi phục'
              : 'Tài khoản Google, sao lưu và khôi phục',
          onTap: () => open(syncPage),
        ),
        SettingsRow(
          icon: CupertinoIcons.archivebox,
          title: 'Lưu trữ',
          subtitle: 'Nội dung offline và bộ nhớ tạm',
          onTap: () => open(const StorageMaintenanceScreen()),
        ),
        SettingsRow(
          icon: CupertinoIcons.gear,
          title: 'Cài đặt',
          subtitle: 'Chung, giao diện, nguồn, trình đọc và bảo mật',
          onTap: () => open(const SettingsHomeScreen()),
        ),
        const SettingsHeading('Khác'),
        SettingsRow(
          icon: CupertinoIcons.calendar,
          title: 'Lịch chương dự kiến',
          onTap: () => open(const UpcomingScreen()),
        ),
        SettingsRow(
          icon: CupertinoIcons.question_circle,
          title: 'Trợ giúp & Giấy phép',
          onTap: () => open(const HelpLicensesScreen()),
        ),
      ],
    );
  }
}
