import 'package:flutter/material.dart';

import '../domain/chapter_list_options.dart';

Future<void> showChapterOptions(
  BuildContext context, {
  required ChapterListOptions options,
  required List<String> scanlators,
  required ValueChanged<ChapterListOptions> onChanged,
}) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  backgroundColor: Theme.of(context).scaffoldBackgroundColor,
  shape: const RoundedRectangleBorder(
    borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
  ),
  builder: (_) => _ChapterOptionsSheet(
    options: options,
    scanlators: scanlators,
    onChanged: onChanged,
  ),
);

class _ChapterOptionsSheet extends StatefulWidget {
  const _ChapterOptionsSheet({
    required this.options,
    required this.scanlators,
    required this.onChanged,
  });
  final ChapterListOptions options;
  final List<String> scanlators;
  final ValueChanged<ChapterListOptions> onChanged;
  @override
  State<_ChapterOptionsSheet> createState() => _ChapterOptionsSheetState();
}

class _ChapterOptionsSheetState extends State<_ChapterOptionsSheet> {
  late ChapterListOptions options = widget.options;
  void patch(Map<String, dynamic> value) {
    setState(() => options = options.patch(value));
    widget.onChanged(options);
  }

  Widget filter(
    String label,
    String key,
    String value,
    Map<String, String> choices,
  ) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 10),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(label),
        const SizedBox(height: 8),
        SegmentedButton<String>(
          segments: [
            for (final entry in choices.entries)
              ButtonSegment(
                value: entry.key,
                label: Text(entry.value, style: const TextStyle(fontSize: 12)),
              ),
          ],
          selected: {value},
          expandedInsets: EdgeInsets.zero,
          showSelectedIcon: false,
          onSelectionChanged: (value) => patch({key: value.first}),
        ),
      ],
    ),
  );
  Widget scanlator(String label, String key, String value) =>
      DropdownButtonFormField<String>(
        initialValue: widget.scanlators.contains(value) ? value : '',
        isExpanded: true,
        decoration: InputDecoration(labelText: label),
        items: [
          const DropdownMenuItem(
            value: '',
            child: Text('Tất cả / không ưu tiên'),
          ),
          for (final group in widget.scanlators)
            DropdownMenuItem(
              value: group,
              child: Text(group, overflow: TextOverflow.ellipsis),
            ),
        ],
        onChanged: (value) => patch({key: value ?? ''}),
      );
  @override
  Widget build(BuildContext context) => SafeArea(
    child: SizedBox(
      height: MediaQuery.sizeOf(context).height * .7,
      child: Column(
        children: [
          ListTile(
            title: const Text('Lọc và sắp xếp chương'),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextButton(
                  onPressed: () {
                    setState(() => options = const ChapterListOptions());
                    widget.onChanged(options);
                  },
                  child: const Text('Đặt lại'),
                ),
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Đóng'),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
              children: [
                filter('Đã đọc', 'read', options.read, const {
                  'all': 'Tất cả',
                  'read': 'Đã đọc',
                  'unread': 'Chưa đọc',
                }),
                filter('Đã tải', 'download', options.download, const {
                  'all': 'Tất cả',
                  'downloaded': 'Đã tải',
                  'online': 'Chưa tải',
                }),
                filter('Dấu trang', 'bookmarked', options.bookmarked, const {
                  'all': 'Tất cả',
                  'yes': 'Có dấu',
                  'no': 'Không có',
                }),
                DropdownButtonFormField<ChapterSort>(
                  initialValue: options.sort,
                  decoration: const InputDecoration(labelText: 'Sắp xếp'),
                  items: [
                    for (final entry in const {
                      ChapterSort.source: 'Thứ tự nguồn',
                      ChapterSort.number: 'Số chương',
                      ChapterSort.title: 'Tên chương',
                    }.entries)
                      DropdownMenuItem(
                        value: entry.key,
                        child: Text(entry.value),
                      ),
                  ],
                  onChanged: (value) => patch({'sort': value!.name}),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Giảm dần'),
                  value: options.descending,
                  onChanged: (value) => patch({'descending': value}),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Bỏ qua chương trùng'),
                  subtitle: const Text(
                    'Chỉ ghép số chương hợp lệ. Chương không có số luôn được giữ.',
                  ),
                  value: options.hideDuplicates,
                  onChanged: (value) => patch({'hideDuplicates': value}),
                ),
                if (widget.scanlators.isNotEmpty) ...[
                  scanlator(
                    'Chỉ hiển thị nhóm dịch',
                    'scanlator',
                    options.scanlator,
                  ),
                  scanlator(
                    'Nhóm dịch ưu tiên khi trùng chương',
                    'preferredScanlator',
                    options.preferredScanlator,
                  ),
                  const Padding(
                    padding: EdgeInsets.only(top: 16),
                    child: Text('Loại trừ nhóm dịch'),
                  ),
                  for (final group in widget.scanlators)
                    CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(group),
                      value: options.excludedScanlators.contains(group),
                      onChanged: (value) {
                        final next = options.excludedScanlators.toSet();
                        if (value == true) {
                          next.add(group);
                        } else {
                          next.remove(group);
                        }
                        patch({'excludedScanlators': next.toList()});
                      },
                    ),
                ],
              ],
            ),
          ),
        ],
      ),
    ),
  );
}
