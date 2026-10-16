import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/widgets/feedback.dart';
import '../../library/presentation/library_view_model.dart';
import '../domain/catalogue.dart';

Future<void> showSourcePreferences(
  BuildContext context,
  CatalogueSource source,
) => showDialog<void>(
  context: context,
  builder: (_) => _SourcePreferences(source: source),
);

class _SourcePreferences extends ConsumerStatefulWidget {
  const _SourcePreferences({required this.source});
  final CatalogueSource source;

  @override
  ConsumerState<_SourcePreferences> createState() => _PreferenceState();
}

class _PreferenceState extends ConsumerState<_SourcePreferences> {
  List<Map<String, dynamic>>? preferences;
  final controllers = <int, TextEditingController>{};
  final saving = <int>{};
  String? error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (mounted) {
      setState(() {
        error = null;
        preferences = null;
      });
    }
    try {
      final values = await ref
          .read(sourceRepositoryProvider)
          .sourcePreferences(widget.source);
      if (mounted) setState(() => preferences = values);
    } catch (e) {
      if (mounted) setState(() => error = userFacingError(e));
    }
  }

  Future<void> _save(int position, dynamic value) async {
    if (saving.contains(position)) return;
    setState(() => saving.add(position));
    try {
      await ref
          .read(sourceRepositoryProvider)
          .setSourcePreference(widget.source, position, value);
      if (!mounted) return;
      setState(() {
        final props = preferences![position]['props'] as Map;
        props['currentValue'] = value;
      });
      message(context, 'Đã lưu cấu hình nguồn');
    } catch (e) {
      if (mounted) message(context, e);
    } finally {
      if (mounted) setState(() => saving.remove(position));
    }
  }

  @override
  void dispose() {
    for (final controller in controllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  Widget _preference(int position) {
    final item = preferences![position];
    final raw = item['props'];
    if (raw is! Map) return const SizedBox.shrink();
    final props = Map<String, dynamic>.from(raw);
    if (props['visible'] == false) return const SizedBox.shrink();
    final title = '${props['title'] ?? props['key'] ?? 'Cấu hình'}';
    final value = props['currentValue'] ?? props['defaultValue'];
    final enabled = props['enabled'] != false && !saving.contains(position);
    final type = '${item['type']}';
    if (type == 'PreferenceCategory' || type == 'PreferenceScreen') {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Align(
          alignment: Alignment.centerLeft,
          child: Text(title, style: Theme.of(context).textTheme.titleSmall),
        ),
      );
    }
    if (type == 'EditTextPreference') {
      final controller = controllers.putIfAbsent(
        position,
        () => TextEditingController(text: '${value ?? props['text'] ?? ''}'),
      );
      final password = RegExp(
        r'password|mật khẩu|token|secret',
        caseSensitive: false,
      ).hasMatch('$title ${props['key']}');
      return Padding(
        padding: const EdgeInsets.only(bottom: 16),
        child: TextField(
          controller: controller,
          enabled: enabled,
          obscureText: password,
          autocorrect: false,
          enableSuggestions: !password,
          decoration: InputDecoration(
            labelText: title,
            suffixIcon: saving.contains(position)
                ? const Padding(
                    padding: EdgeInsets.all(14),
                    child: SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                : IconButton(
                    tooltip: 'Lưu $title',
                    onPressed: enabled
                        ? () => _save(position, controller.text)
                        : null,
                    icon: const Icon(Icons.check),
                  ),
          ),
          onSubmitted: enabled ? (text) => _save(position, text) : null,
        ),
      );
    }
    if (type == 'SwitchPreferenceCompat' || type == 'CheckBoxPreference') {
      return SwitchListTile.adaptive(
        title: Text(title),
        value: value == true || value == 'true',
        onChanged: enabled ? (next) => _save(position, next) : null,
      );
    }
    if (type == 'ListPreference' && props['entries'] is List) {
      final entries = props['entries'] as List;
      final entryValues = props['entryValues'];
      if (entryValues is List && entryValues.length == entries.length) {
        final selected = '$value';
        return Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: DropdownButtonFormField<String>(
            isExpanded: true,
            initialValue: entryValues.any((v) => '$v' == selected)
                ? selected
                : null,
            decoration: InputDecoration(labelText: title),
            items: [
              for (var i = 0; i < entries.length; i++)
                DropdownMenuItem(
                  value: '${entryValues[i]}',
                  child: Text(
                    '${entries[i]}',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
            onChanged: enabled
                ? (next) {
                    if (next != null) _save(position, next);
                  }
                : null,
          ),
        );
      }
    }
    if (type == 'MultiSelectListPreference' &&
        props['entries'] is List &&
        props['entryValues'] is List) {
      final entries = props['entries'] as List;
      final values = props['entryValues'] as List;
      if (entries.length == values.length &&
          values.every((item) => item is String) &&
          (value == null ||
              value is Iterable && value.every((item) => item is String))) {
        final selected = (value as Iterable? ?? const [])
            .cast<String>()
            .toSet();
        return ListTile(
          title: Text(title),
          subtitle: Text('${selected.length} lựa chọn'),
          trailing: const Icon(Icons.chevron_right),
          onTap: !enabled
              ? null
              : () async {
                  final draft = {...selected};
                  final accepted = await showDialog<bool>(
                    context: context,
                    builder: (ctx) => StatefulBuilder(
                      builder: (ctx, update) => AlertDialog(
                        title: Text(title),
                        content: SizedBox(
                          width: 360,
                          height: MediaQuery.sizeOf(ctx).height * .45,
                          child: ListView(
                            children: [
                              for (var i = 0; i < values.length; i++)
                                CheckboxListTile(
                                  title: Text('${entries[i]}'),
                                  value: draft.contains(values[i]),
                                  onChanged: (checked) => update(() {
                                    if (checked == true) {
                                      draft.add(values[i] as String);
                                    } else {
                                      draft.remove(values[i]);
                                    }
                                  }),
                                ),
                            ],
                          ),
                        ),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(ctx),
                            child: const Text('Hủy'),
                          ),
                          TextButton(
                            onPressed: () => Navigator.pop(ctx, true),
                            child: const Text('Lưu'),
                          ),
                        ],
                      ),
                    ),
                  );
                  if (accepted == true && mounted) {
                    await _save(
                      position,
                      values.where(draft.contains).cast<String>().toList(),
                    );
                  }
                },
        );
      }
    }
    return ListTile(
      title: Text(title),
      subtitle: Text(
        '${props['summary']?.toString() ?? ''}${props['summary'] == null || props['summary'] == '' ? '' : '\n'}${props['hasClickListener'] == true ? 'Thao tác riêng hoặc đăng nhập của nguồn này chưa được engine hỗ trợ.' : 'Kiểu cấu hình $type chưa được hỗ trợ.'}',
      ),
      enabled: false,
    );
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.source.name),
    content: SizedBox(
      width: 420,
      child: error != null
          ? Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(error!),
                TextButton(onPressed: _load, child: const Text('Thử lại')),
              ],
            )
          : preferences == null
          ? const Padding(
              padding: EdgeInsets.all(24),
              child: Center(child: CircularProgressIndicator()),
            )
          : preferences!.isEmpty
          ? const Text('Nguồn này không có cấu hình riêng.')
          : SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (var i = 0; i < preferences!.length; i++) _preference(i),
                ],
              ),
            ),
    ),
    actions: [
      TextButton(
        onPressed: saving.isEmpty ? () => Navigator.pop(context) : null,
        child: const Text('Đóng'),
      ),
    ],
  );
}
