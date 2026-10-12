import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/widgets/feedback.dart';
import '../../library/data/coordinated_preferences.dart';
import '../../settings/settings_controller.dart';
import '../domain/source_languages.dart';
import 'browse_widgets.dart';
import 'source_languages_controller.dart';

Future<void> showSourceLanguages(BuildContext context, Set<String> codes) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _LanguageSheet(codes: codes),
    );

class _LanguageSheet extends ConsumerStatefulWidget {
  const _LanguageSheet({required this.codes});
  final Set<String> codes;
  @override
  ConsumerState<_LanguageSheet> createState() => _LanguageSheetState();
}

class _LanguageSheetState extends ConsumerState<_LanguageSheet> {
  late bool all;
  late Set<String> selected;
  late List<String> codes;
  int? generation;
  bool saving = false;
  @override
  void initState() {
    super.initState();
    final current = ref.read(sourceLanguagesProvider);
    all = current.enabled == null;
    selected = {...?current.enabled};
    codes = {...widget.codes, ...selected}.toList()
      ..sort((a, b) => sourceLanguage(a).compareTo(sourceLanguage(b)));
    final preferences = ref.read(preferencesProvider);
    generation = preferences is CoordinatedPreferences
        ? preferences.mutationGeneration
        : null;
  }

  Future<void> save() async {
    setState(() => saving = true);
    await perform(context, () async {
      await ref
          .read(sourceLanguagesProvider.notifier)
          .save(
            SourceLanguages(all ? null : selected),
            expectedGeneration: generation,
          );
      if (mounted) Navigator.pop(context);
    });
    if (mounted) setState(() => saving = false);
  }

  @override
  Widget build(BuildContext context) => SafeArea(
    child: SizedBox(
      height: MediaQuery.sizeOf(context).height * .75,
      child: Column(
        children: [
          ListTile(
            title: const Text('Ngôn ngữ nguồn và extension'),
            trailing: TextButton(
              onPressed: saving ? null : save,
              child: saving
                  ? const CupertinoActivityIndicator()
                  : const Text('Lưu'),
            ),
          ),
          SwitchListTile(
            title: const Text('Tất cả ngôn ngữ'),
            subtitle: const Text('Gồm cả ngôn ngữ mới được thêm vào kho.'),
            value: all,
            onChanged: saving ? null : (value) => setState(() => all = value),
          ),
          Expanded(
            child: ListView(
              children: [
                for (final code in codes)
                  CheckboxListTile(
                    title: Text(sourceLanguage(code)),
                    subtitle: Text(code),
                    value: all || selected.contains(code),
                    onChanged: saving
                        ? null
                        : (value) => setState(() {
                            if (all) selected = codes.toSet();
                            all = false;
                            if (value == true) {
                              selected.add(code);
                            } else {
                              selected.remove(code);
                            }
                          }),
                  ),
              ],
            ),
          ),
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text(
              'Chỉ ẩn hoặc hiện danh sách; các nguồn đã cài vẫn được giữ.',
            ),
          ),
        ],
      ),
    ),
  );
}
