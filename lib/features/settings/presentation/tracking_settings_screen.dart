import 'package:flutter/cupertino.dart';

import 'reading_statistics_book_list.dart';
import 'settings_widgets.dart';

class TrackingSettingsScreen extends StatelessWidget {
  const TrackingSettingsScreen({super.key});

  @override
  Widget build(BuildContext context) => SettingsPage(
    title: 'Trạng thái và đánh giá',
    children: [
      const SettingsHeading('Tiến độ trong thư viện'),
      SettingsRow(
        title: 'Trạng thái và đánh giá từng truyện',
        subtitle: 'Dự định đọc, đang đọc, tạm dừng, hoàn thành và điểm đọc',
        icon: CupertinoIcons.book,
        onTap: () =>
            openSettingsPage(context, const ReadingStatisticsBookList()),
      ),
      const SettingsNote(
        'Trạng thái, điểm, chương đã đọc và dấu trang được lưu cùng thư viện. '
        'Bạn có thể sửa trạng thái và điểm của từng truyện ở danh sách trên.',
      ),
    ],
  );
}
