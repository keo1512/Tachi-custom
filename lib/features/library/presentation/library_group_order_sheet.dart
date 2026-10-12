import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../domain/library_grouping.dart';

Future<List<String>?> showLibraryGroupOrderSheet(
  BuildContext context,
  List<LibraryGroup> groups,
) => showModalBottomSheet<List<String>>(
  context: context,
  useSafeArea: true,
  showDragHandle: true,
  constraints: const BoxConstraints(maxWidth: 600),
  builder: (_) => _GroupOrderSheet(groups: groups),
);

class _GroupOrderSheet extends StatefulWidget {
  const _GroupOrderSheet({required this.groups});
  final List<LibraryGroup> groups;

  @override
  State<_GroupOrderSheet> createState() => _GroupOrderSheetState();
}

class _GroupOrderSheetState extends State<_GroupOrderSheet> {
  late final groups = [...widget.groups];
  final _listViewportKey = GlobalKey();
  final _scrollController = ScrollController();

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SafeArea(
    child: SizedBox(
      height: MediaQuery.sizeOf(context).height * .65,
      child: Column(
        children: [
          Text(
            'Sắp xếp các mục',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const Padding(
            padding: EdgeInsets.all(12),
            child: Text('Giữ và kéo để đổi thứ tự. Mục Tất cả luôn ở đầu.'),
          ),
          Expanded(
            child: SizedBox(
              key: _listViewportKey,
              child: ReorderableListView.builder(
                scrollController: _scrollController,
                buildDefaultDragHandles: false,
                itemCount: groups.length,
                dragBoundaryProvider: (_) {
                  final box =
                      _listViewportKey.currentContext!.findRenderObject()!
                          as RenderBox;
                  return _GroupOrderDragBoundary(
                    box.localToGlobal(Offset.zero).dy,
                    _scrollController.position,
                  );
                },
                onReorderItem: (oldIndex, newIndex) => setState(() {
                  groups.insert(newIndex, groups.removeAt(oldIndex));
                }),
                itemBuilder: (_, index) {
                  final group = groups[index];
                  return ReorderableDelayedDragStartListener(
                    key: ValueKey('group-order-${group.key}'),
                    index: index,
                    child: ColoredBox(
                      color: Colors.transparent,
                      child: ListTile(
                        title: Text(group.label),
                        subtitle: Text('${group.bookIds.length} truyện'),
                        trailing: const Icon(CupertinoIcons.line_horizontal_3),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                CupertinoButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Hủy'),
                ),
                CupertinoButton(
                  onPressed: () => Navigator.pop(
                    context,
                    groups.map((group) => group.key).toList(),
                  ),
                  child: const Text('Lưu'),
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}

/// Clamp only above the first row. Allow overshoot elsewhere so a long list
/// still auto-scrolls while the user holds a row beyond either visible edge.
class _GroupOrderDragBoundary extends DragBoundaryDelegate<Rect> {
  _GroupOrderDragBoundary(this.top, this.position);

  final double top;
  final ScrollPosition position;

  @override
  bool isWithinBoundary(Rect draggedObject) =>
      position.pixels > position.minScrollExtent || draggedObject.top >= top;

  @override
  Rect nearestPositionWithinBoundary(Rect draggedObject) =>
      isWithinBoundary(draggedObject)
      ? draggedObject
      : draggedObject.shift(Offset(0, top - draggedObject.top));
}
