import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/widgets/feedback.dart';
import '../domain/library_categories.dart';
import 'library_category_controller.dart';
import 'library_view_model.dart';

class LibraryCategoriesScreen extends ConsumerStatefulWidget {
  const LibraryCategoriesScreen({super.key});

  @override
  ConsumerState<LibraryCategoriesScreen> createState() =>
      _LibraryCategoriesScreenState();
}

class _LibraryCategoriesScreenState
    extends ConsumerState<LibraryCategoriesScreen> {
  bool busy = false;

  Future<void> change(Future<Object?> Function() action) async {
    setState(() => busy = true);
    await perform(context, action);
    if (mounted) setState(() => busy = false);
  }

  Future<String?> nameDialog({String? name}) async {
    final controller = TextEditingController(text: name ?? '');
    final form = GlobalKey<FormState>();
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(name == null ? 'Tạo danh mục' : 'Đổi tên danh mục'),
        content: Form(
          key: form,
          child: TextFormField(
            key: const ValueKey('category-name'),
            controller: controller,
            autofocus: true,
            maxLength: 256,
            decoration: const InputDecoration(labelText: 'Tên danh mục'),
            validator: (value) =>
                (value ?? '').trim().isEmpty ? 'Nhập tên danh mục.' : null,
            onFieldSubmitted: (_) {
              if (form.currentState!.validate()) {
                Navigator.pop(ctx, controller.text.trim());
              }
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Hủy'),
          ),
          TextButton(
            onPressed: () {
              if (form.currentState!.validate()) {
                Navigator.pop(ctx, controller.text.trim());
              }
            },
            child: const Text('Lưu'),
          ),
        ],
      ),
    );
    // The route may still be disposing its text field until the next frame.
    WidgetsBinding.instance.addPostFrameCallback((_) => controller.dispose());
    return result;
  }

  Future<void> create() async {
    final name = await nameDialog();
    if (name == null || !mounted) return;
    await change(() async {
      await ref.read(libraryCategoriesProvider.notifier).create(name);
      return null;
    });
  }

  Future<void> rename(String oldName) async {
    final revision = ref.read(libraryRepositoryProvider).replacementRevision;
    final name = await nameDialog(name: oldName);
    if (name == null || !mounted) return;
    await change(
      () => ref
          .read(libraryCategoriesProvider.notifier)
          .rename(oldName, name, expectedRevision: revision),
    );
  }

  Future<void> remove(String name) async {
    final revision = ref.read(libraryRepositoryProvider).replacementRevision;
    final confirmed = await showCupertinoDialog<bool>(
      context: context,
      builder: (ctx) => CupertinoAlertDialog(
        title: Text('Xóa danh mục $name?'),
        content: const Text(
          'Giữ tất cả truyện và nội dung đã tải. Truyện không còn danh mục nào sẽ về Mặc định.',
        ),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Hủy'),
          ),
          CupertinoDialogAction(
            isDestructiveAction: true,
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Xóa'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await change(
      () => ref
          .read(libraryCategoriesProvider.notifier)
          .remove(name, expectedRevision: revision),
    );
  }

  Widget policy(
    String label,
    CategoryPolicy current,
    ValueChanged<CategoryPolicy>? onChanged,
  ) => DropdownButtonFormField<CategoryPolicy>(
    initialValue: current,
    isExpanded: true,
    decoration: InputDecoration(labelText: label),
    items: [
      for (final option in CategoryPolicy.values)
        DropdownMenuItem(
          value: option,
          child: Text(switch (option) {
            CategoryPolicy.inherit => 'Theo thiết lập chung',
            CategoryPolicy.include => 'Cho phép',
            CategoryPolicy.exclude => 'Loại trừ',
          }),
        ),
    ],
    onChanged: onChanged == null
        ? null
        : (value) {
            if (value != null) onChanged(value);
          },
  );

  @override
  Widget build(BuildContext context) {
    final registry = ref.watch(libraryCategoriesProvider);
    final books = ref.watch(libraryProvider).value ?? const [];
    final categories = registry.all(books);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Danh mục thư viện'),
        actions: [
          IconButton(
            tooltip: 'Tạo danh mục',
            onPressed: busy ? null : create,
            icon: const Icon(CupertinoIcons.add),
          ),
        ],
      ),
      body: ListView(
        children: [
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text(
              'Một truyện có thể thuộc nhiều danh mục. Danh mục mặc định áp dụng cho truyện mới; truyện hiện có giữ nguyên. Loại trừ được ưu tiên khi một truyện thuộc cả danh mục cho phép và loại trừ.',
            ),
          ),
          for (final category in categories)
            ExpansionTile(
              key: ValueKey('category-settings-${category.name}'),
              title: Text(category.name),
              subtitle: Text(
                '${books.where((book) => book.categories.contains(category.name)).length} truyện',
              ),
              childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              children: [
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Mặc định khi thêm truyện'),
                  value: registry.defaultCategories.contains(category.name),
                  onChanged: busy
                      ? null
                      : (value) => change(() async {
                          final selected = registry.defaultCategories.toSet();
                          if (value == true) {
                            selected.add(category.name);
                          } else {
                            selected.remove(category.name);
                          }
                          await ref
                              .read(libraryCategoriesProvider.notifier)
                              .setDefaults(selected);
                          return null;
                        }),
                ),
                policy(
                  'Cập nhật tự động',
                  category.update,
                  busy
                      ? null
                      : (value) => change(() async {
                          await ref
                              .read(libraryCategoriesProvider.notifier)
                              .setPolicy(category.name, update: value);
                          return null;
                        }),
                ),
                const SizedBox(height: 16),
                policy(
                  'Tự tải chương mới',
                  category.download,
                  busy
                      ? null
                      : (value) => change(() async {
                          await ref
                              .read(libraryCategoriesProvider.notifier)
                              .setPolicy(category.name, download: value);
                          return null;
                        }),
                ),
                if (category.name != 'Mặc định')
                  Row(
                    children: [
                      TextButton.icon(
                        onPressed: busy ? null : () => rename(category.name),
                        icon: const Icon(CupertinoIcons.pencil, size: 18),
                        label: const Text('Đổi tên'),
                      ),
                      TextButton.icon(
                        onPressed: busy ? null : () => remove(category.name),
                        icon: const Icon(CupertinoIcons.trash, size: 18),
                        label: const Text('Xóa'),
                      ),
                    ],
                  ),
              ],
            ),
          if (categories.isEmpty)
            const Padding(
              padding: EdgeInsets.all(32),
              child: Text('Chưa có danh mục. Nhấn + để tạo danh mục đầu tiên.'),
            ),
        ],
      ),
    );
  }
}
