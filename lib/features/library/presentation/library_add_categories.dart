import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/library_mutation.dart';
import '../domain/library_book.dart';
import '../../sources/domain/catalogue.dart';
import 'library_category_controller.dart';
import 'library_view_model.dart';

/// Category choice happens before the source request and inserts with the
/// captured replacement revision; cancellation cannot add a partial book.
Future<LibraryBook?> addCatalogueBookWithCategories(
  BuildContext context,
  WidgetRef ref,
  CatalogueBook item, {
  String sourceName = '',
}) async {
  final repository = ref.read(libraryRepositoryProvider);
  final revision = repository.replacementRevision;
  final books = await repository.list();
  checkLibraryRevision(repository.replacementRevision, revision);
  final existing = books
      .where(
        (book) =>
            book.engine == item.engine.name &&
            book.sourceId == item.sourceId &&
            book.sourceRef == item.ref,
      )
      .firstOrNull;
  if (existing != null) return existing;
  if (!context.mounted) return null;
  final registry = ref.read(libraryCategoriesProvider);
  final customNames = registry
      .all(books)
      .map((category) => category.name)
      .where((name) => name != 'Mặc định')
      .toSet()
      .toList();
  final names = customNames.isEmpty ? <String>[] : ['Mặc định', ...customNames];
  final categories = names.isEmpty
      ? registry.defaultCategories
      : await showLibraryAddCategories(
          context,
          title: item.title,
          names: names,
          selected: registry.defaultCategories,
        );
  if (categories == null || !context.mounted) return null;
  checkLibraryRevision(repository.replacementRevision, revision);
  return ref
      .read(libraryProvider.notifier)
      .addFromSource(
        item,
        categories: categories,
        sourceName: sourceName,
        expectedRevision: revision,
      );
}

Future<List<String>?> showLibraryAddCategories(
  BuildContext context, {
  required String title,
  required List<String> names,
  required List<String> selected,
}) => showDialog<List<String>>(
  context: context,
  builder: (_) =>
      _AddCategoriesDialog(title: title, names: names, selected: selected),
);

class _AddCategoriesDialog extends StatefulWidget {
  const _AddCategoriesDialog({
    required this.title,
    required this.names,
    required this.selected,
  });
  final String title;
  final List<String> names, selected;
  @override
  State<_AddCategoriesDialog> createState() => _AddCategoriesDialogState();
}

class _AddCategoriesDialogState extends State<_AddCategoriesDialog> {
  late final selected = widget.selected.where(widget.names.contains).toSet();
  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Thêm vào danh mục'),
    content: SizedBox(
      width: 420,
      height: MediaQuery.sizeOf(context).height * .5,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(widget.title, maxLines: 2, overflow: TextOverflow.ellipsis),
          const SizedBox(height: 8),
          const Text('Bỏ chọn tất cả để thêm vào Mặc định.'),
          const SizedBox(height: 8),
          Expanded(
            child: ListView(
              children: [
                for (final name in widget.names)
                  CheckboxListTile(
                    key: ValueKey('add-category-$name'),
                    title: Text(name),
                    value: selected.contains(name),
                    onChanged: (value) => setState(() {
                      value == true
                          ? selected.add(name)
                          : selected.remove(name);
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
        key: const ValueKey('confirm-add-categories'),
        onPressed: () => Navigator.pop(
          context,
          widget.names.where(selected.contains).toList(),
        ),
        child: const Text('Thêm truyện'),
      ),
    ],
  );
}
