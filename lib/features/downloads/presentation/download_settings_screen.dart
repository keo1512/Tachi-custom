import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/widgets/feedback.dart';
import '../../settings/settings_controller.dart';
import 'download_deletion_controller.dart';

class DownloadSettingsScreen extends ConsumerWidget {
  const DownloadSettingsScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final policy = ref.watch(downloadDeletionProvider);
    final controller = ref.read(downloadDeletionProvider.notifier);
    final concurrent = ref.watch(
      settingsProvider.select((value) => value.downloadConcurrency),
    );
    return Scaffold(
      appBar: AppBar(title: const Text('Thiết lập tải xuống')),
      body: ListView(
        children: [
          ListTile(
            title: const Text('Số nguồn tải đồng thời'),
            subtitle: const Text(
              'Mỗi nguồn chỉ tải một chương tại một thời điểm.',
            ),
            trailing: DropdownButton<int>(
              value: concurrent,
              items: [
                for (var value = 1; value <= 4; value++)
                  DropdownMenuItem(value: value, child: Text('$value')),
              ],
              onChanged: (value) {
                if (value != null) {
                  perform(
                    context,
                    () => ref
                        .read(settingsProvider.notifier)
                        .update(downloadConcurrency: value),
                  );
                }
              },
            ),
          ),
          const Divider(),
          SwitchListTile(
            title: const Text('Tự xóa sau khi đọc'),
            subtitle: const Text(
              'Xóa chương đã đọc khi rời trình đọc. Giữ sách nhập EPUB/TXT/CBZ.',
            ),
            value: policy.afterReading,
            onChanged: (value) =>
                perform(context, () => controller.update(afterReading: value)),
          ),
          SwitchListTile(
            title: const Text('Xóa khi đánh dấu đã đọc'),
            subtitle: const Text(
              'Áp dụng khi bạn chủ động đánh dấu chương đã đọc.',
            ),
            value: policy.afterManualRead,
            onChanged: (value) => perform(
              context,
              () => controller.update(afterManualRead: value),
            ),
          ),
          SwitchListTile(
            title: const Text('Bảo vệ chương có dấu trang'),
            subtitle: const Text(
              'Giữ nội dung của chương có dấu trang khi xóa thủ công hoặc tự động.',
            ),
            value: policy.protectBookmarks,
            onChanged: (value) => perform(
              context,
              () => controller.update(protectBookmarks: value),
            ),
          ),
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text(
              'Xóa nội dung tải không xóa truyện khỏi thư viện, tiến độ hay dấu trang. '
              'Bạn có thể tải lại chương từ nguồn. Các yêu cầu đang chạy trước khi xóa sẽ bị từ chối.',
            ),
          ),
        ],
      ),
    );
  }
}
