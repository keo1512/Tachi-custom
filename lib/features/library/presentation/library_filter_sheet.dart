import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

enum LibraryOrder { recent, title, unread }

class LibraryFilter {
  const LibraryFilter({
    this.kind = 'all',
    this.category = 'Tất cả',
    this.order = LibraryOrder.recent,
    this.reverse = false,
    this.compact = false,
  });
  final String kind, category;
  final LibraryOrder order;
  final bool reverse, compact;
  bool get active => kind != 'all' || category != 'Tất cả';

  LibraryFilter copyWith({
    String? kind,
    String? category,
    LibraryOrder? order,
    bool? reverse,
    bool? compact,
  }) => LibraryFilter(
    kind: kind ?? this.kind,
    category: category ?? this.category,
    order: order ?? this.order,
    reverse: reverse ?? this.reverse,
    compact: compact ?? this.compact,
  );
}

class LibraryFilterSheet extends StatefulWidget {
  const LibraryFilterSheet({
    super.key,
    required this.value,
    required this.collections,
    required this.onChanged,
  });
  final LibraryFilter value;
  final List<String> collections;
  final ValueChanged<LibraryFilter> onChanged;
  @override
  State<LibraryFilterSheet> createState() => _LibraryFilterSheetState();
}

class _LibraryFilterSheetState extends State<LibraryFilterSheet> {
  late LibraryFilter filter = widget.value;

  void change(LibraryFilter value) {
    setState(() => filter = value);
    widget.onChanged(value);
  }

  Widget choice(String label, bool selected, VoidCallback onTap) => ListTile(
    title: Text(label),
    trailing: selected
        ? Icon(CupertinoIcons.check_mark, color: Theme.of(context).primaryColor)
        : null,
    onTap: onTap,
    selected: selected,
  );

  Widget section(String title) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 18, 16, 4),
    child: Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
  );

  @override
  Widget build(BuildContext context) => SizedBox(
    height: MediaQuery.sizeOf(context).height * .65,
    child: DefaultTabController(
      length: 3,
      child: Column(
        children: [
          Row(
            children: [
              const Expanded(
                child: TabBar(
                  tabs: [
                    Tab(text: 'Lọc'),
                    Tab(text: 'Sắp xếp'),
                    Tab(text: 'Hiển thị'),
                  ],
                ),
              ),
              IconButton(
                tooltip: 'Đóng bộ lọc',
                onPressed: () => Navigator.pop(context),
                icon: const Icon(CupertinoIcons.xmark, size: 18),
              ),
            ],
          ),
          Expanded(
            child: TabBarView(
              children: [
                ListView(
                  children: [
                    section('Nội dung'),
                    for (final item in const {
                      'all': 'Tất cả nội dung',
                      'manga': 'Truyện tranh',
                      'novel': 'Truyện chữ & ebook',
                    }.entries)
                      choice(
                        item.value,
                        filter.kind == item.key,
                        () => change(filter.copyWith(kind: item.key)),
                      ),
                    const Divider(height: 1),
                    section('Thư viện'),
                    for (final category in [
                      'Tất cả',
                      'Đang đọc',
                      'Yêu thích',
                      'Hoàn thành',
                      ...widget.collections,
                    ])
                      choice(
                        category,
                        filter.category == category,
                        () => change(filter.copyWith(category: category)),
                      ),
                  ],
                ),
                ListView(
                  children: [
                    for (final item in const {
                      LibraryOrder.recent: 'Đọc gần đây',
                      LibraryOrder.title: 'Tên',
                      LibraryOrder.unread: 'Số chương chưa đọc',
                    }.entries)
                      choice(
                        item.value,
                        filter.order == item.key,
                        () => change(filter.copyWith(order: item.key)),
                      ),
                    const Divider(height: 1),
                    SwitchListTile.adaptive(
                      title: const Text('Đảo chiều'),
                      value: filter.reverse,
                      onChanged: (value) =>
                          change(filter.copyWith(reverse: value)),
                    ),
                  ],
                ),
                ListView(
                  children: [
                    SwitchListTile.adaptive(
                      title: const Text('Lưới nhỏ'),
                      subtitle: const Text('Hiển thị thêm bìa trên mỗi hàng'),
                      value: filter.compact,
                      onChanged: (value) =>
                          change(filter.copyWith(compact: value)),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}
