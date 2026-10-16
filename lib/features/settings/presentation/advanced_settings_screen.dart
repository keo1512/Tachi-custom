import 'package:flutter/cupertino.dart';

import 'library_diagnostics_screen.dart';
import 'log_diagnostics_screen.dart';
import 'network_tools_screen.dart';
import 'settings_widgets.dart';

class AdvancedSettingsScreen extends StatelessWidget {
  const AdvancedSettingsScreen({super.key});

  @override
  Widget build(BuildContext context) => SettingsPage(
    title: 'Nâng cao và chẩn đoán',
    children: [
      const SettingsHeading('Nguồn truyện'),
      SettingsRow(
        title: 'Trình duyệt và mạng',
        subtitle: 'Trang nguồn, cookie và thông tin trình duyệt',
        icon: CupertinoIcons.globe,
        onTap: () => openSettingsPage(context, const NetworkToolsScreen()),
      ),
      SettingsRow(
        title: 'Nhật ký và chẩn đoán',
        subtitle: 'Xem lỗi, thử lại đúng luồng và xuất nhật ký',
        icon: CupertinoIcons.doc_text_search,
        onTap: () => openSettingsPage(context, const LogDiagnosticsScreen()),
      ),
      const SettingsHeading('Thư viện'),
      SettingsRow(
        title: 'Kiểm tra thư viện',
        subtitle: 'Đối chiếu nội dung đã lưu và mở luồng phục hồi',
        icon: CupertinoIcons.checkmark_shield,
        onTap: () =>
            openSettingsPage(context, const LibraryDiagnosticsScreen()),
      ),
    ],
  );
}
