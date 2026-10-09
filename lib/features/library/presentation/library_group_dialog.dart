import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../domain/library_book.dart';
import '../domain/library_grouping.dart';

class LibraryGroupEdit {
  const LibraryGroupEdit(this.grouping, this.value);
  final LibraryGrouping grouping;
  final String value;
}

Future<LibraryGroupEdit?> showLibraryGroupDialog(
  BuildContext context, {
  required List<LibraryBook> books,
  required Set<String> selectedIds,
  required LibraryGrouping grouping,
}) => showDialog<LibraryGroupEdit>(
  context: context,
  builder: (_) => _LibraryGroupDialog(
    books: books,
    selectedIds: selectedIds,
    grouping: grouping,
  ),
);

class _LibraryGroupDialog extends StatefulWidget {
  const _LibraryGroupDialog({
    required this.books,
    required this.selectedIds,
    required this.grouping,
  });
  final List<LibraryBook> books;
  final Set<String> selectedIds;
  final LibraryGrouping grouping;

  @override
  State<_LibraryGroupDialog> createState() => _LibraryGroupDialogState();
}

class _LibraryGroupDialogState extends State<_LibraryGroupDialog> {
  final form = GlobalKey<FormState>();
  late LibraryGrouping grouping = widget.grouping;
  late final controller = TextEditingController(text: commonValue());

  String commonValue() {
    final values = widget.books
        .where((book) => widget.selectedIds.contains(book.id))
        .map(
          (book) => switch (grouping) {
            LibraryGrouping.collection => book.collection,
            LibraryGrouping.author => book.author,
            LibraryGrouping.series => book.series,
          },
        )
        .toSet();
    return values.length == 1 ? values.single : '';
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final names = libraryGroups(widget.books, grouping)
        .where((group) => group.key != 'missing')
        .map((group) => group.label)
        .toList();
    return AlertDialog(
      scrollable: true,
      title: Text('Gom nhóm ${widget.selectedIds.length} sách'),
      content: SizedBox(
        width: 360,
        child: Form(
          key: form,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              DropdownButtonFormField<LibraryGrouping>(
                initialValue: grouping,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Gán thông tin'),
                items: [
                  for (final mode in LibraryGrouping.values)
                    DropdownMenuItem(value: mode, child: Text(mode.label)),
                ],
                onChanged: (value) {
                  if (value == null) return;
                  setState(() {
                    grouping = value;
                    controller.text = commonValue();
                  });
                },
              ),
              const SizedBox(height: 16),
              TextFormField(
                key: const ValueKey('group-name'),
                controller: controller,
                maxLength: 256,
                decoration: InputDecoration(
                  labelText: 'Tên ${grouping.label.toLowerCase()}',
                ),
                validator: (value) =>
                    grouping == LibraryGrouping.collection &&
                        (value ?? '').trim().isEmpty
                    ? 'Nhập tên kệ.'
                    : null,
              ),
              Text(
                grouping == LibraryGrouping.collection
                    ? 'Chuyển các sách đã chọn vào cùng kệ.'
                    : 'Gán cùng ${grouping.label.toLowerCase()} cho các sách đã chọn. Kệ thủ công được giữ nguyên. Để trống để xóa thông tin này.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              if (names.isNotEmpty) ...[
                const SizedBox(height: 12),
                const Text('Tên đã có'),
                SizedBox(
                  height: 44,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    itemCount: names.length,
                    separatorBuilder: (_, _) => const SizedBox(width: 6),
                    itemBuilder: (_, i) => ActionChip(
                      label: Text(names[i]),
                      onPressed: () => controller.text = names[i],
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Hủy'),
        ),
        TextButton.icon(
          onPressed: () {
            if (form.currentState!.validate()) {
              Navigator.pop(
                context,
                LibraryGroupEdit(grouping, controller.text.trim()),
              );
            }
          },
          icon: const Icon(CupertinoIcons.check_mark, size: 16),
          label: const Text('Áp dụng'),
        ),
      ],
    );
  }
}
