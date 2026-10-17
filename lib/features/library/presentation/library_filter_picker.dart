import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

Future<String?> showLibraryFilterPicker(
  BuildContext context, {
  required String title,
  required Map<String, String> options,
  required String selected,
}) => showModalBottomSheet<String>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  showDragHandle: true,
  constraints: const BoxConstraints(maxWidth: 600),
  builder: (_) =>
      _FilterPicker(title: title, options: options, selected: selected),
);

class _FilterPicker extends StatefulWidget {
  const _FilterPicker({
    required this.title,
    required this.options,
    required this.selected,
  });
  final String title, selected;
  final Map<String, String> options;
  @override
  State<_FilterPicker> createState() => _FilterPickerState();
}

class _FilterPickerState extends State<_FilterPicker> {
  final search = TextEditingController();
  String query = '';
  @override
  void dispose() {
    search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final items = widget.options.entries
        .where(
          (item) =>
              item.value.toLowerCase().contains(query.trim().toLowerCase()),
        )
        .toList();
    return Padding(
      padding: EdgeInsets.only(bottom: media.viewInsets.bottom),
      child: SizedBox(
        height: (media.size.height - media.viewInsets.bottom) * .65,
        child: Column(
          children: [
            Row(
              children: [
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Text(
                      widget.title,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Đóng danh sách',
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(CupertinoIcons.xmark, size: 18),
                ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: TextField(
                controller: search,
                key: const ValueKey('library-filter-picker-search'),
                decoration: InputDecoration(
                  hintText: 'Tìm trong danh sách',
                  prefixIcon: const Icon(CupertinoIcons.search),
                  suffixIcon: query.isEmpty
                      ? null
                      : IconButton(
                          tooltip: 'Xóa tìm kiếm',
                          onPressed: () {
                            search.clear();
                            setState(() => query = '');
                          },
                          icon: const Icon(CupertinoIcons.xmark_circle_fill),
                        ),
                ),
                onChanged: (value) => setState(() => query = value),
              ),
            ),
            Expanded(
              child: items.isEmpty
                  ? const Center(child: Text('Không có kết quả phù hợp'))
                  : ListView.builder(
                      itemCount: items.length,
                      itemBuilder: (_, index) {
                        final item = items[index];
                        return ListTile(
                          title: Text(item.value),
                          selected: item.key == widget.selected,
                          trailing: item.key == widget.selected
                              ? Icon(
                                  CupertinoIcons.check_mark,
                                  color: Theme.of(context).colorScheme.primary,
                                )
                              : null,
                          onTap: () => Navigator.pop(context, item.key),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
