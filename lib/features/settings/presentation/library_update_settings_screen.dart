import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/widgets/feedback.dart';
import '../../../core/format/task_intervals.dart';
import '../../library/application/library_update_policy.dart';
import '../../library/application/library_update_scheduler.dart';
import '../../library/presentation/library_categories_screen.dart';
import '../settings_controller.dart';
import 'settings_widgets.dart';

class LibraryUpdateSettingsScreen extends ConsumerWidget {
  const LibraryUpdateSettingsScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final policy = ref.watch(libraryUpdatePolicyProvider);
    void change(Map<String, dynamic> values) => perform(
      context,
      () => ref.read(libraryUpdatePolicyProvider.notifier).patch(values),
    );
    Widget flag(String label, bool value, String key) =>
        SwitchListTile.adaptive(
          title: Text(label),
          value: value,
          onChanged: (v) => change({key: v}),
        );
    return SettingsPage(
      title: 'Cập nhật & tải tự động',
      children: [
        const SettingsNote(
          'App tự kiểm tra chương mới theo lịch kể cả khi không mở giao diện. iOS quyết định thời điểm đánh thức nên có thể chạy trễ hơn chu kỳ đã chọn. Nếu vuốt tắt hẳn app trong đa nhiệm, cần mở lại để tác vụ nền được tiếp tục.',
        ),
        Padding(
          padding: const EdgeInsets.all(16),
          child: DropdownButtonFormField<int>(
            initialValue: policy.hours,
            decoration: const InputDecoration(labelText: 'Chu kỳ cập nhật'),
            items: [
              for (final hours in LibraryUpdatePolicy.intervals)
                DropdownMenuItem(
                  value: hours,
                  child: Text(taskIntervalLabel(hours)),
                ),
            ],
            onChanged: (v) {
              if (v != null) change({'hours': v});
            },
          ),
        ),
        flag('Chỉ kiểm tra qua Wi-Fi', policy.wifiOnly, 'wifiOnly'),
        flag('Chỉ kiểm tra khi đang sạc', policy.chargingOnly, 'chargingOnly'),
        flag(
          'Kiểm tra tất cả truyện trong thư viện',
          policy.checkAll,
          'checkAll',
        ),
        if (policy.checkAll)
          const SettingsNote(
            'Kiểm tra mọi truyện từ nguồn trực tuyến, kể cả truyện đã hoàn thành và các danh mục đang loại khỏi cập nhật. Thiết lập tự tải của từng danh mục vẫn được giữ.',
          ),
        if (!policy.checkAll) ...[
          flag(
            'Bỏ qua truyện hoàn thành / ngừng phát hành',
            policy.skipCompleted,
            'skipCompleted',
          ),
          flag(
            'Bỏ qua truyện chưa bắt đầu đọc',
            policy.skipUnstarted,
            'skipUnstarted',
          ),
          flag(
            'Bỏ qua truyện còn chương chưa đọc',
            policy.skipUnread,
            'skipUnread',
          ),
          flag(
            'Bỏ qua truyện chưa tới ngày dự kiến',
            policy.skipEarly,
            'skipEarly',
          ),
        ],
        flag(
          'Tự tải chương mới trong danh mục cho phép',
          policy.downloadNew,
          'downloadNew',
        ),
        Padding(
          padding: const EdgeInsets.all(16),
          child: DropdownButtonFormField<int>(
            initialValue: policy.downloadAhead,
            decoration: const InputDecoration(
              labelText: 'Tải trước khi đang đọc',
            ),
            items: [
              for (final n in [0, 1, 2, 3, 5, 10])
                DropdownMenuItem(
                  value: n,
                  child: Text(n == 0 ? 'Tắt' : '$n chương'),
                ),
            ],
            onChanged: (v) {
              if (v != null) change({'downloadAhead': v});
            },
          ),
        ),
        SettingsRow(
          title: 'Danh mục cập nhật / tự tải',
          onTap: () =>
              openSettingsPage(context, const LibraryCategoriesScreen()),
        ),
        SettingsRow(
          title: 'Kiểm tra theo điều kiện đã chọn',
          onTap: () => perform(context, () async {
            final result = await ref
                .read(libraryUpdateSchedulerProvider)
                .check(DateTime.now(), force: true);
            if (context.mounted) message(context, result);
          }),
        ),
        SettingsNote(
          ref
                  .read(preferencesProvider)
                  .getString('libraryAutomaticUpdateResult') ??
              'Chưa có lượt cập nhật tự động.',
        ),
      ],
    );
  }
}
