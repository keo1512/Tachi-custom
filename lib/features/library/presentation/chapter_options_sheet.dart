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
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: const TextStyle(fontSize: 14)),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: SegmentedButton<String>(
              segments: options.entries
                  .map(
                    (option) => ButtonSegment<String>(
                      value: option.key,
                      label: option.value,
                    ),
                  )
                  .toList(),
              selected: {selected},
              selectedIcon: const Icon(Icons.check, size: 16),
              expandedInsets: EdgeInsets.zero,
              style: ButtonStyle(
                backgroundColor: WidgetStateProperty.resolveWith(
                  (states) => states.contains(WidgetState.selected)
                      ? Theme.of(context).brightness == Brightness.dark
                            ? const Color(0xFF24456D)
                            : const Color(0xFFCFE4FF)
                      : Colors.transparent,
                ),
                foregroundColor: WidgetStatePropertyAll(
                  Theme.of(context).colorScheme.onSurface,
                ),
                side: const WidgetStatePropertyAll(
                  BorderSide(color: Color(0xFF96969A)),
                ),
                padding: const WidgetStatePropertyAll(
                  EdgeInsets.symmetric(horizontal: 4, vertical: 8),
                ),
                textStyle: const WidgetStatePropertyAll(
                  TextStyle(fontSize: 13),
                ),
                shape: const WidgetStatePropertyAll(StadiumBorder()),
              ),
              onSelectionChanged: (values) => onChanged(values.first),
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

  void resetOptions() {
    setState(() {
      readingFilter = 'all';
      downloadFilter = 'all';
      newestFirst = false;
    });
    widget.onReadFilter('all');
    widget.onDownloadFilter('all');
    widget.onSort(false);
  }

  @override
  Widget build(BuildContext context) => DefaultTabController(
    length: 2,
    child: SafeArea(
      child: SizedBox(
        height: 320,
        child: Column(
          children: [
            SizedBox(
              height: 44,
              child: Row(
                children: [
                  Expanded(
                    child: TabBar(
                      tabs: const [
                        Tab(text: 'Lọc'),
                        Tab(text: 'Sắp xếp'),
                      ],
                      indicatorSize: TabBarIndicatorSize.label,
                      indicatorWeight: 3,
                      indicator: UnderlineTabIndicator(
                        borderSide: BorderSide(
                          width: 3,
                          color: Theme.of(context).colorScheme.primary,
                        ),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      labelStyle: const TextStyle(fontSize: 14),
                      labelColor: Theme.of(context).colorScheme.primary,
                      unselectedLabelColor: Theme.of(context)
                          .colorScheme
                          .onSurface,
                      dividerHeight: 0,
                    ),
                  ),
                  PopupMenuButton<String>(
                    tooltip: 'Tùy chọn chương',
                    icon: const Icon(
                      Icons.more_vert,
                      size: 21,
                      color: Color(0xFF929296),
                    ),
                    onSelected: (value) {
                      if (value == 'reset') {
                        resetOptions();
                      } else {
                        Navigator.pop(context);
                      }
                    },
                    itemBuilder: (_) => const [
                      PopupMenuItem(
                        value: 'reset',
                        child: Text('Đặt lại bộ lọc và sắp xếp'),
                      ),
                      PopupMenuItem(value: 'close', child: Text('Đóng')),
                    ],
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: TabBarView(
                children: [
                  SingleChildScrollView(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Column(
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
                    ),
                  ),
                  SingleChildScrollView(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Column(
                      children: [
                        sortRow('Chương cũ trước', false),
                        const Divider(height: .5),
                        sortRow('Chương mới trước', true),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
