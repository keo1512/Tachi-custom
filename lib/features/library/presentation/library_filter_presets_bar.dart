import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/widgets/feedback.dart';
import '../data/coordinated_preferences.dart';
import '../../settings/settings_controller.dart';
import 'library_filter_controller.dart';
import 'library_filter_sheet.dart';

class LibraryFilterPresetsBar extends ConsumerStatefulWidget {
  const LibraryFilterPresetsBar({
    super.key,
    required this.filter,
    required this.onApply,
  });
  final LibraryFilter filter;
  final ValueChanged<LibraryFilter> onApply;
  @override
  ConsumerState<LibraryFilterPresetsBar> createState() => _PresetState();
}

class _PresetState extends ConsumerState<LibraryFilterPresetsBar> {
  late final int generation = switch (ref.read(preferencesProvider)) {
    final CoordinatedPreferences preferences => preferences.mutationGeneration,
    _ => 0,
  };
  Future<void> save() async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Lưu bộ lọc thư viện'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 80,
          decoration: const InputDecoration(
            labelText: 'Tên bộ lọc',
            helperText: 'Tên đã có sẽ cập nhật bộ lọc tương ứng.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Hủy'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('Lưu'),
          ),
        ],
      ),
    );
    // TextField can still be disposing during the route's closing animation.
    await Future<void>.delayed(const Duration(milliseconds: 300));
    controller.dispose();
    if (name == null || !mounted) return;
    await perform(
      context,
      () => ref
          .read(libraryFilterProvider.notifier)
          .savePreset(name, widget.filter, expectedGeneration: generation),
    );
  }

  @override
  Widget build(BuildContext context) {
    final presets = ref.watch(libraryFilterProvider).presets;
    return Row(
      children: [
        Expanded(
          child: PopupMenuButton<String>(
            tooltip: 'Bộ lọc thư viện đã lưu',
            enabled: presets.isNotEmpty,
            onSelected: (name) => widget.onApply(presets[name]!),
            itemBuilder: (_) => [
              for (final name in presets.keys)
                PopupMenuItem(value: name, child: Text(name)),
            ],
            child: const Padding(
              padding: EdgeInsets.all(12),
              child: Text('Bộ lọc đã lưu'),
            ),
          ),
        ),
        IconButton(
          tooltip: 'Lưu bộ lọc hiện tại',
          onPressed: save,
          icon: const Icon(Icons.bookmark_add_outlined),
        ),
        PopupMenuButton<String>(
          tooltip: 'Xóa bộ lọc đã lưu',
          enabled: presets.isNotEmpty,
          icon: const Icon(Icons.delete_outline),
          onSelected: (name) => perform(
            context,
            () => ref
                .read(libraryFilterProvider.notifier)
                .removePreset(name, expectedGeneration: generation),
          ),
          itemBuilder: (_) => [
            for (final name in presets.keys)
              PopupMenuItem(value: name, child: Text(name)),
          ],
        ),
      ],
    );
  }
}
