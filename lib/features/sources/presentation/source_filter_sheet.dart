import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/widgets/feedback.dart';
import '../../library/presentation/library_view_model.dart';
import '../domain/catalogue.dart';
import '../domain/source_filters.dart';
import 'source_filter_presets.dart';

class SourceFilterSheet extends ConsumerStatefulWidget {
  const SourceFilterSheet({super.key, required this.source, this.selected});
  final CatalogueSource source;
  final SourceFilterSet? selected;
  @override
  ConsumerState<SourceFilterSheet> createState() => _FilterState();
}

class _FilterState extends ConsumerState<SourceFilterSheet> {
  SourceFilterSet? defaults, current;
  String? error;
  bool loading = true;
  int editorRevision = 0;
  String? editingPresetName;
  late final SourceFilterPresetStore presetStore;
  @override
  void initState() {
    super.initState();
    presetStore = ref.read(sourceFilterPresetsProvider);
    Future.microtask(load);
  }

  Future<void> load() async {
    if (!mounted) return;
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final filters = await ref
          .read(sourceRepositoryProvider)
          .sourceFilters(widget.source);
      if (!mounted) return;
      setState(() {
        defaults = filters;
        current = widget.selected?.schema == filters.schema
            ? widget.selected!.clone()
            : filters.clone();
        loading = false;
        editorRevision++;
        if (widget.selected != null &&
            widget.selected!.schema != filters.schema) {
          error = 'Nguồn đã thay đổi bộ lọc. Điều kiện cũ đã được đặt lại.';
        }
      });
    } catch (failure) {
      if (mounted) {
        setState(() {
          error = userFacingError(failure);
          loading = false;
        });
      }
    }
  }

  void change(List<int> path, Object? state) {
    List<SourceFilterNode> update(List<SourceFilterNode> values, int depth) => [
      for (var i = 0; i < values.length; i++)
        if (i != path[depth])
          values[i]
        else if (depth + 1 == path.length)
          values[i].copyWith(state: state)
        else
          values[i].copyWith(children: update(values[i].children, depth + 1)),
    ];
    setState(
      () => current = SourceFilterSet(
        schema: current!.schema,
        filters: update(current!.filters, 0),
      ),
    );
  }

  Future<void> savePreset() async {
    final snapshot = current!.clone();
    final previousName = editingPresetName;
    final name = TextEditingController(text: previousName);
    final chosen = await showCupertinoDialog<String>(
      context: context,
      builder: (ctx) => CupertinoAlertDialog(
        title: Text(previousName == null ? 'Lưu bộ lọc' : 'Sửa bộ lọc'),
        content: CupertinoTextField(
          controller: name,
          placeholder: 'Tên bộ lọc',
          maxLength: 80,
        ),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Hủy'),
          ),
          CupertinoDialogAction(
            onPressed: () => Navigator.pop(ctx, name.text),
            child: const Text('Lưu'),
          ),
        ],
      ),
    );
    name.dispose();
    if (chosen == null || !mounted || current == null) return;
    await perform(context, () async {
      if (previousName == null) {
        await presetStore.save(widget.source.identity, chosen, snapshot);
      } else {
        await presetStore.replace(
          widget.source.identity,
          previousName,
          chosen,
          snapshot,
        );
      }
      if (mounted) setState(() => editingPresetName = chosen.trim());
    }, success: 'Đã lưu bộ lọc');
    if (mounted) setState(() {});
  }

  Future<void> managePresets() async {
    final store = presetStore;
    List<SourceFilterPreset>? presets;
    await perform(
      context,
      () async => presets = store.list(widget.source.identity),
    );
    if (!mounted || presets == null) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, update) => SafeArea(
          child: SizedBox(
            height: MediaQuery.sizeOf(ctx).height * .55,
            child: Column(
              children: [
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text('Bộ lọc đã lưu', style: TextStyle(fontSize: 18)),
                ),
                if (presets!.isEmpty) const Text('Chưa có bộ lọc đã lưu.'),
                Expanded(
                  child: ListView(
                    children: [
                      for (final preset in presets!)
                        ListTile(
                          title: Text(preset.name),
                          subtitle: preset.filters.schema == defaults?.schema
                              ? null
                              : const Text('Nguồn đã thay đổi bộ lọc'),
                          onTap: preset.filters.schema != defaults?.schema
                              ? null
                              : () {
                                  setState(() {
                                    current = preset.filters.clone();
                                    editingPresetName = null;
                                    editorRevision++;
                                  });
                                  Navigator.pop(ctx);
                                },
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                tooltip: 'Sửa ${preset.name}',
                                icon: const Icon(CupertinoIcons.pencil),
                                onPressed:
                                    preset.filters.schema != defaults?.schema
                                    ? null
                                    : () {
                                        setState(() {
                                          current = preset.filters.clone();
                                          editingPresetName = preset.name;
                                          editorRevision++;
                                        });
                                        Navigator.pop(ctx);
                                      },
                              ),
                              IconButton(
                                tooltip: 'Xóa ${preset.name}',
                                icon: const Icon(CupertinoIcons.trash),
                                onPressed: () async {
                                  await perform(
                                    ctx,
                                    () => store.remove(
                                      widget.source.identity,
                                      preset.name,
                                    ),
                                  );
                                  if (ctx.mounted) {
                                    update(
                                      () => presets = store.list(
                                        widget.source.identity,
                                      ),
                                    );
                                  }
                                },
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget node(SourceFilterNode filter, List<int> path) {
    final key = ValueKey('source-filter-${path.join('-')}');
    final tileName = filter.name.isEmpty
        ? 'Điều kiện ${path.last + 1}'
        : filter.name;
    Widget reset() => IconButton(
      tooltip: 'Đặt lại $tileName',
      icon: const Icon(CupertinoIcons.arrow_counterclockwise, size: 20),
      onPressed: () {
        var original = defaults!.filters[path.first];
        for (final index in path.skip(1)) {
          original = original.children[index];
        }
        change(path, original.state);
        setState(() => editorRevision++);
      },
    );
    switch (filter.type) {
      case SourceFilterType.header:
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
          child: Text(
            tileName,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
        );
      case SourceFilterType.separator:
        return const Divider();
      case SourceFilterType.unsupported:
        return ListTile(
          key: key,
          title: Text(tileName),
          subtitle: Text(
            'Bộ lọc này chưa được engine hỗ trợ (${filter.className}). Dùng trạng thái mặc định của nguồn.',
          ),
          leading: const Icon(CupertinoIcons.exclamationmark_triangle),
        );
      case SourceFilterType.group:
        return ExpansionTile(
          key: key,
          initiallyExpanded: true,
          title: Text(tileName),
          children: [
            for (var i = 0; i < filter.children.length; i++)
              node(filter.children[i], [...path, i]),
          ],
        );
      case SourceFilterType.text:
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: TextFormField(
            key: ValueKey('${path.join('-')}:$editorRevision'),
            initialValue: filter.state as String,
            maxLength: 8192,
            decoration: InputDecoration(
              labelText: tileName,
              suffixIcon: reset(),
            ),
            onChanged: (value) => change(path, value),
          ),
        );
      case SourceFilterType.checkbox:
        return CheckboxListTile(
          key: key,
          title: Text(tileName),
          secondary: reset(),
          value: filter.state as bool,
          onChanged: (value) => change(path, value == true),
        );
      case SourceFilterType.tristate:
        return ListTile(
          key: key,
          leading: reset(),
          title: Text(tileName),
          trailing: DropdownButton<int>(
            value: filter.state as int,
            items: const [
              DropdownMenuItem(value: 0, child: Text('Bỏ qua')),
              DropdownMenuItem(value: 1, child: Text('Bao gồm')),
              DropdownMenuItem(value: 2, child: Text('Loại trừ')),
            ],
            onChanged: (value) {
              if (value != null) change(path, value);
            },
          ),
        );
      case SourceFilterType.select:
        return ListTile(
          key: key,
          leading: reset(),
          title: Text(tileName),
          subtitle: DropdownButton<int>(
            isExpanded: true,
            value: filter.state as int,
            items: [
              for (var i = 0; i < filter.values.length; i++)
                DropdownMenuItem(
                  value: i,
                  child: Text(
                    filter.values[i],
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
            onChanged: (value) {
              if (value != null) change(path, value);
            },
          ),
        );
      case SourceFilterType.sort:
        final selection = filter.state as Map<String, dynamic>?;
        return ListTile(
          key: key,
          leading: reset(),
          title: Text(tileName),
          subtitle: DropdownButton<int>(
            isExpanded: true,
            value: selection?['index'] as int? ?? -1,
            items: [
              const DropdownMenuItem(value: -1, child: Text('Mặc định')),
              for (var i = 0; i < filter.values.length; i++)
                DropdownMenuItem(
                  value: i,
                  child: Text(
                    filter.values[i],
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
            onChanged: (value) {
              if (value != null) {
                change(
                  path,
                  value == -1
                      ? null
                      : {
                          'index': value,
                          'ascending': selection?['ascending'] ?? false,
                        },
                );
              }
            },
          ),
          trailing: IconButton(
            tooltip: selection?['ascending'] == true ? 'Tăng dần' : 'Giảm dần',
            onPressed: selection == null
                ? null
                : () => change(path, {
                    'index': selection['index'],
                    'ascending': selection['ascending'] != true,
                  }),
            icon: Icon(
              selection?['ascending'] == true
                  ? CupertinoIcons.arrow_up
                  : CupertinoIcons.arrow_down,
            ),
          ),
        );
    }
  }

  @override
  Widget build(BuildContext context) => SafeArea(
    child: SizedBox(
      height: MediaQuery.sizeOf(context).height * .8,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
            child: Row(
              children: [
                const Expanded(
                  child: Text(
                    'Bộ lọc của nguồn',
                    style: TextStyle(fontSize: 18),
                  ),
                ),
                IconButton(
                  tooltip: 'Tải lại bộ lọc',
                  onPressed: loading ? null : load,
                  icon: const Icon(CupertinoIcons.refresh),
                ),
              ],
            ),
          ),
          if (loading) const LinearProgressIndicator(),
          if (error != null)
            Padding(padding: const EdgeInsets.all(12), child: Text(error!)),
          Expanded(
            child: current == null
                ? const SizedBox()
                : ListView(
                    children: current!.filters.isEmpty
                        ? [
                            const ListTile(
                              title: Text('Nguồn này không có bộ lọc.'),
                            ),
                          ]
                        : [
                            for (var i = 0; i < current!.filters.length; i++)
                              node(current!.filters[i], [i]),
                          ],
                  ),
          ),
          if (current != null && !loading)
            Wrap(
              alignment: WrapAlignment.center,
              children: [
                TextButton(
                  onPressed: () => setState(() {
                    current = defaults!.clone();
                    editorRevision++;
                  }),
                  child: const Text('Đặt lại'),
                ),
                TextButton(
                  onPressed: savePreset,
                  child: Text(
                    editingPresetName == null ? 'Lưu bộ lọc' : 'Lưu thay đổi',
                  ),
                ),
                TextButton(
                  onPressed: managePresets,
                  child: const Text('Bộ lọc đã lưu'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(context, current),
                  child: const Text('Áp dụng'),
                ),
              ],
            ),
        ],
      ),
    ),
  );
}
