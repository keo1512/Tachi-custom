import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../domain/catalogue.dart';

Future<List<CatalogueSource>?> chooseMigrationSources(
  BuildContext context, {
  required List<CatalogueSource> candidates,
  required String title,
}) async {
  final chosen = await showCupertinoModalPopup<Object>(
    context: context,
    builder: (ctx) => CupertinoActionSheet(
      title: Text(title),
      message: candidates.isEmpty
          ? const Text(
              'Chưa có nguồn thay thế phù hợp. Cài thêm extension trong Duyệt.',
            )
          : null,
      actions: [
        if (candidates.length > 1)
          CupertinoActionSheetAction(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Tìm trong nhiều nguồn'),
          ),
        for (final source in candidates)
          CupertinoActionSheetAction(
            onPressed: () => Navigator.pop(ctx, source),
            child: Text('${source.name} · ${source.lang}'),
          ),
      ],
      cancelButton: CupertinoActionSheetAction(
        onPressed: () => Navigator.pop(ctx),
        child: const Text('Hủy'),
      ),
    ),
  );
  if (chosen is CatalogueSource) return [chosen];
  if (chosen != true || !context.mounted) return null;
  return selectMigrationSources(
    context,
    candidates: candidates,
    selected: candidates.take(50).map((source) => source.identity).toSet(),
  );
}

Future<List<CatalogueSource>?> selectMigrationSources(
  BuildContext context, {
  required List<CatalogueSource> candidates,
  required Set<String> selected,
  String title = 'Nguồn tìm kiếm',
}) => showDialog<List<CatalogueSource>>(
  context: context,
  builder: (_) => _MigrationSourcesDialog(
    candidates: candidates,
    selected: selected,
    title: title,
  ),
);

class _MigrationSourcesDialog extends StatefulWidget {
  const _MigrationSourcesDialog({
    required this.candidates,
    required this.selected,
    required this.title,
  });
  final List<CatalogueSource> candidates;
  final Set<String> selected;
  final String title;
  @override
  State<_MigrationSourcesDialog> createState() => _MigrationSourcesState();
}

class _MigrationSourcesState extends State<_MigrationSourcesDialog> {
  late final selected = {...widget.selected};
  String query = '';
  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title),
    content: SizedBox(
      width: 420,
      height: MediaQuery.sizeOf(context).height * .5,
      child: Column(
        children: [
          TextField(
            onChanged: (value) => setState(() => query = value),
            decoration: const InputDecoration(labelText: 'Tìm nguồn'),
          ),
          Text('Đã chọn ${selected.length}/50 nguồn'),
          Expanded(
            child: ListView(
              children: [
                if (widget.candidates.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(12),
                    child: Text(
                      'Chưa có nguồn phù hợp. Cài thêm extension trong Duyệt rồi chọn lại nguồn đích.',
                    ),
                  ),
                for (final source in widget.candidates.where(
                  (source) =>
                      source.name.toLowerCase().contains(query.toLowerCase()),
                ))
                  CheckboxListTile(
                    title: Text(source.name),
                    subtitle: Text(source.lang),
                    value: selected.contains(source.identity),
                    onChanged:
                        selected.length >= 50 &&
                            !selected.contains(source.identity)
                        ? null
                        : (value) => setState(() {
                            if (value == true) {
                              selected.add(source.identity);
                            } else {
                              selected.remove(source.identity);
                            }
                          }),
                  ),
              ],
            ),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Hủy'),
      ),
      TextButton(
        onPressed: selected.isEmpty
            ? null
            : () => Navigator.pop(
                context,
                widget.candidates
                    .where((source) => selected.contains(source.identity))
                    .toList(),
              ),
        child: const Text('Tìm trong các nguồn này'),
      ),
    ],
  );
}
