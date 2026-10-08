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
    try {
      final values = await ref
          .read(sourceRepositoryProvider)
          .sourcePreferences(widget.source);
      if (mounted) setState(() => preferences = values);
    } catch (e) {
      if (mounted) setState(() => error = '$e');
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
            initialValue: entryValues.any((v) => '$v' == selected)
                ? selected
                : null,
            decoration: InputDecoration(labelText: title),
            items: [
              for (var i = 0; i < entries.length; i++)
                DropdownMenuItem(
                  value: '${entryValues[i]}',
                  child: Text('${entries[i]}'),
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
    return ListTile(
      title: Text(title),
      subtitle: Text(
        props['summary']?.toString() ?? 'Kiểu cấu hình này chưa được hỗ trợ.',
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
          ? Text(error!)
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
