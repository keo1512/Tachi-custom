import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

Future<void> showChapterOptions(
  BuildContext context, {
  required String readingFilter,
  required String downloadFilter,
  required bool newestFirst,
  required ValueChanged<String> onReadFilter,
  required ValueChanged<String> onDownloadFilter,
  required ValueChanged<bool> onSort,
}) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  backgroundColor: Theme.of(context).scaffoldBackgroundColor,
  shape: const RoundedRectangleBorder(
    borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
  ),
  builder: (_) => _ChapterOptionsSheet(
    readingFilter: readingFilter,
    downloadFilter: downloadFilter,
    newestFirst: newestFirst,
    onReadFilter: onReadFilter,
    onDownloadFilter: onDownloadFilter,
    onSort: onSort,
  ),
);

class _ChapterOptionsSheet extends StatefulWidget {
  const _ChapterOptionsSheet({
    required this.readingFilter,
    required this.downloadFilter,
    required this.newestFirst,
    required this.onReadFilter,
    required this.onDownloadFilter,
    required this.onSort,
  });
  final String readingFilter, downloadFilter;
  final bool newestFirst;
  final ValueChanged<String> onReadFilter, onDownloadFilter;
  final ValueChanged<bool> onSort;
  @override
  State<_ChapterOptionsSheet> createState() => _ChapterOptionsSheetState();
}

class _ChapterOptionsSheetState extends State<_ChapterOptionsSheet> {
  String tab = 'filter';
  late String readingFilter, downloadFilter;
  late bool newestFirst;

  @override
  void initState() {
    super.initState();
    readingFilter = widget.readingFilter;
    downloadFilter = widget.downloadFilter;
    newestFirst = widget.newestFirst;
  }

  Widget filterRow(
    String title,
    String selected,
    Map<String, Widget> options,
    ValueChanged<String> onChanged,
  ) {
    final secondary = CupertinoDynamicColor.resolve(
      CupertinoColors.secondaryLabel,
      context,
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: TextStyle(fontSize: 13, color: secondary)),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: CupertinoSlidingSegmentedControl<String>(
              groupValue: selected,
              children: options,
              onValueChanged: (value) {
                if (value != null) onChanged(value);
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget sortRow(String title, bool reverse) => ListTile(
    contentPadding: EdgeInsets.zero,
    title: Text(title, style: const TextStyle(fontSize: 17)),
    trailing: newestFirst == reverse
        ? const Icon(
            CupertinoIcons.checkmark,
            color: CupertinoColors.activeBlue,
            size: 20,
          )
        : null,
    onTap: () {
      setState(() => newestFirst = reverse);
      widget.onSort(reverse);
    },
  );

  @override
  Widget build(BuildContext context) => SafeArea(
    child: SizedBox(
      height: 320,
      child: Column(
        children: [
          SizedBox(
            height: 44,
            child: Row(
              children: [
                const SizedBox(width: 16),
                const Text(
                  'Tùy chọn chương',
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
                ),
                const Spacer(),
                CupertinoButton(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Xong', style: TextStyle(fontSize: 17)),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: SizedBox(
              width: double.infinity,
              child: CupertinoSlidingSegmentedControl<String>(
                groupValue: tab,
                children: const {
                  'filter': Text('Lọc'),
                  'sort': Text('Sắp xếp'),
                },
                onValueChanged: (value) {
                  if (value != null) setState(() => tab = value);
                },
              ),
            ),
          ),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: tab == 'filter'
                  ? Column(
                      children: [
                        filterRow(
                          'Đã đọc',
                          readingFilter,
                          const {
                            'all': Text('Tất cả'),
                            'read': Text('Đã đọc'),
                            'unread': Text('Chưa đọc'),
                          },
                          (value) {
                            setState(() => readingFilter = value);
                            widget.onReadFilter(value);
                          },
                        ),
                        filterRow(
                          'Đã tải',
                          downloadFilter,
                          const {
                            'all': Text('Tất cả'),
                            'downloaded': Text('Đã tải'),
                            'online': Text('Chưa tải'),
                          },
                          (value) {
                            setState(() => downloadFilter = value);
                            widget.onDownloadFilter(value);
                          },
                        ),
                      ],
                    )
                  : Column(
                      children: [
                        sortRow('Chương cũ trước', false),
                        const Divider(height: .5),
                        sortRow('Chương mới trước', true),
                      ],
                    ),
            ),
          ),
        ],
      ),
    ),
  );
}
