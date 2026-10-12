import 'package:flutter/material.dart';

import '../domain/catalogue.dart';

Future<List<String>?> showPinnedSourceOrder(
  BuildContext context,
  List<CatalogueSource> sources,
) => showModalBottomSheet<List<String>>(
  context: context,
  isScrollControlled: true,
  builder: (_) => _PinnedSourceOrder(sources: sources),
);

class _PinnedSourceOrder extends StatefulWidget {
  const _PinnedSourceOrder({required this.sources});
  final List<CatalogueSource> sources;
  @override
  State<_PinnedSourceOrder> createState() => _PinnedSourceOrderState();
}

class _PinnedSourceOrderState extends State<_PinnedSourceOrder> {
  late final sources = [...widget.sources];
  @override
  Widget build(BuildContext context) => SafeArea(
    child: SizedBox(
      height: MediaQuery.sizeOf(context).height * .7,
      child: Column(
        children: [
          ListTile(
            title: const Text('Sắp xếp nguồn đã ghim'),
            trailing: TextButton(
              onPressed: () => Navigator.pop(
                context,
                sources.map((s) => s.identity).toList(),
              ),
              child: const Text('Lưu'),
            ),
          ),
          Expanded(
            child: ReorderableListView.builder(
              itemCount: sources.length,
              onReorderItem: (oldIndex, newIndex) => setState(() {
                final item = sources.removeAt(oldIndex);
                sources.insert(newIndex, item);
              }),
              itemBuilder: (_, index) => ListTile(
                key: ValueKey(sources[index].identity),
                title: Text(sources[index].name),
                trailing: const Icon(Icons.drag_handle),
              ),
            ),
          ),
        ],
      ),
    ),
  );
}
