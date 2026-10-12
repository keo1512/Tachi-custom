import 'package:flutter/material.dart';

import '../domain/library_grouping.dart';

class LibraryGroupTabs extends StatelessWidget {
  const LibraryGroupTabs({
    super.key,
    required this.groups,
    required this.selectedKey,
    required this.total,
    required this.onSelected,
    required this.grouping,
    this.onReorder,
  });
  final List<LibraryGroup> groups;
  final String? selectedKey;
  final int total;
  final ValueChanged<String?> onSelected;
  final LibraryGrouping grouping;
  final VoidCallback? onReorder;

  @override
  Widget build(BuildContext context) => Column(
    children: [
      if (grouping != LibraryGrouping.collection)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              'Nhóm theo ${grouping.label.toLowerCase()}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ),
      SizedBox(
        height: 42,
        child: ListView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          children: [
            tab(context, null, 'Tất cả', total),
            for (final group in groups)
              tab(context, group.key, group.label, group.bookIds.length),
          ],
        ),
      ),
    ],
  );

  Widget tab(BuildContext context, String? key, String label, int count) {
    final selected = selectedKey == key;
    return InkWell(
      key: ValueKey('library-group-${key ?? 'all'}'),
      onTap: () => onSelected(key),
      onLongPress: onReorder,
      child: Container(
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              width: 2,
              color: selected
                  ? Theme.of(context).colorScheme.primary
                  : Colors.transparent,
            ),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              style: TextStyle(
                fontSize: 14,
                color: selected ? Theme.of(context).colorScheme.primary : null,
              ),
            ),
            Container(
              margin: const EdgeInsets.only(left: 3),
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
              decoration: BoxDecoration(
                color: Theme.of(context).brightness == Brightness.dark
                    ? const Color(0xFF222224)
                    : const Color(0xFFE6E6E9),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text('$count', style: const TextStyle(fontSize: 11)),
            ),
          ],
        ),
      ),
    );
  }
}
