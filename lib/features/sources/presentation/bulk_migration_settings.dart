import 'package:flutter/material.dart';

import '../application/bulk_migration_matcher.dart';
import '../domain/source_migration.dart';

class BulkMigrationSettings {
  const BulkMigrationSettings({
    this.strategy = BulkMigrationStrategy.firstMatch,
    this.options = const SourceMigrationOptions(),
  });
  final BulkMigrationStrategy strategy;
  final SourceMigrationOptions options;
}

Future<BulkMigrationSettings?> showBulkMigrationSettings(
  BuildContext context,
  BulkMigrationSettings value,
) => showDialog<BulkMigrationSettings>(
  context: context,
  builder: (_) => _Settings(value),
);

class _Settings extends StatefulWidget {
  const _Settings(this.value);
  final BulkMigrationSettings value;
  @override
  State<_Settings> createState() => _SettingsState();
}

class _SettingsState extends State<_Settings> {
  late var strategy = widget.value.strategy;
  late var chapters = widget.value.options.chapters;
  late var categories = widget.value.options.categories;
  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Cài đặt chuyển nguồn'),
    content: SizedBox(
      width: 480,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Dữ liệu chuyển sang nguồn mới'),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Tiến độ chương và dấu trang'),
              value: chapters,
              onChanged: (v) => setState(() => chapters = v!),
            ),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Danh mục và thư mục'),
              value: categories,
              onChanged: (v) => setState(() => categories = v!),
            ),
            const Text(
              'Chương tải xuống không chuyển giữa các nguồn. Bước xác nhận cho phép giữ truyện cũ hoặc thay thế và xóa nội dung tải cũ.',
            ),
            const SizedBox(height: 20),
            const Text('Chiến lược chuyển nguồn'),
            RadioGroup<BulkMigrationStrategy>(
              groupValue: strategy,
              onChanged: (v) => setState(() => strategy = v!),
              child: const Column(
                children: [
                  RadioListTile(
                    contentPadding: EdgeInsets.zero,
                    value: BulkMigrationStrategy.firstMatch,
                    title: Text('Dùng nguồn khớp đầu tiên'),
                    subtitle: Text(
                      'Tìm theo thứ tự ưu tiên và dừng khi có kết quả.',
                    ),
                  ),
                  RadioListTile(
                    contentPadding: EdgeInsets.zero,
                    value: BulkMigrationStrategy.mostChapters,
                    title: Text('Dùng nguồn có nhiều chương nhất'),
                    subtitle: Text('Kiểm tra mọi nguồn đã chọn, chậm hơn.'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Hủy'),
      ),
      FilledButton(
        key: const ValueKey('migration-settings-start'),
        onPressed: () => Navigator.pop(
          context,
          BulkMigrationSettings(
            strategy: strategy,
            options: SourceMigrationOptions(
              chapters: chapters,
              categories: categories,
            ),
          ),
        ),
        child: const Text('Bắt đầu tìm và ghép'),
      ),
    ],
  );
}
