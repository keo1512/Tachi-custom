import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/widgets/feedback.dart';
import '../../library/data/coordinated_preferences.dart';
import '../../settings/settings_controller.dart';
import '../../library/presentation/library_view_model.dart';
import '../domain/catalogue.dart';
import '../domain/source_languages.dart';
import 'browse_widgets.dart';
import 'source_languages_controller.dart';
import 'extension_catalogue_controller.dart';

Future<void> showAvailableSourceLanguages(BuildContext context) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => const _AvailableSourceLanguages(),
    );

class _AvailableSourceLanguages extends ConsumerStatefulWidget {
  const _AvailableSourceLanguages();
  @override
  ConsumerState<_AvailableSourceLanguages> createState() =>
      _AvailableSourceLanguagesState();
}

class _AvailableSourceLanguagesState
    extends ConsumerState<_AvailableSourceLanguages> {
  Set<String>? codes;
  String? error;
  bool busy = true;
  @override
  void initState() {
    super.initState();
    Future.microtask(load);
  }

  Future<void> load() async {
    if (!mounted) return;
    setState(() {
      busy = true;
      error = null;
    });
    final found = <String>{
      ...?ref.read(sourceLanguagesProvider).enabled,
      ...?ref
          .read(extensionCatalogueProvider)
          .value
          ?.expand((index) => index.entries)
          .map((entry) => entry.lang),
    };
    final repository = ref.read(sourceRepositoryProvider);
    final settings = ref.read(settingsProvider);
    var successes = 0;
    final failures = <Object>[];
    await Future.wait([
      () async {
        try {
          final indexes = await ref.read(extensionCatalogueProvider.future);
          found.addAll(
            indexes.expand((index) => index.entries).map((entry) => entry.lang),
          );
          for (final index in indexes.where(
            (index) => index.error.isNotEmpty,
          )) {
            failures.add(FormatException(index.error));
          }
        } catch (failure) {
          failures.add(failure);
        }
      }(),
      ...SourceEngine.values.map((engine) async {
        final configured = engine == SourceEngine.tachimanga
            ? settings.tachimangaUrl
            : settings.vbookUrl;
        if (repository.requiresExternalConnection(engine) &&
            configured.isEmpty) {
          return;
        }
        try {
          final sources = await repository.listSources(engine);
          found.addAll(sources.map((source) => source.lang));
          successes++;
        } catch (failure) {
          failures.add(failure);
        }
      }),
    ]);
    if (!mounted) return;
    found.removeWhere(
      (code) =>
          code.isEmpty || !RegExp(r'^[a-zA-Z0-9_-]{1,32}$').hasMatch(code),
    );
    setState(() {
      busy = false;
      if (found.isEmpty && successes == 0 && failures.isNotEmpty) {
        error = userFacingError(failures.first);
      } else {
        codes = found;
      }
    });
  }

  @override
  Widget build(BuildContext context) => codes != null && !busy
      ? _LanguageSheet(codes: codes!)
      : SafeArea(
          child: SizedBox(
            height: MediaQuery.sizeOf(context).height * .5,
            child: ListView(
              padding: const EdgeInsets.symmetric(vertical: 12),
              children: [
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text('Ngôn ngữ nguồn truyện'),
                ),
                if (busy) const CupertinoActivityIndicator(),
                if (error != null) ...[
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(error!),
                  ),
                  TextButton(onPressed: load, child: const Text('Thử lại')),
                ],
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Đóng'),
                ),
              ],
            ),
          ),
        );
}

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
          Expanded(
            child: ListView(
              children: [
                SwitchListTile(
                  title: const Text('Tất cả ngôn ngữ'),
                  subtitle: const Text(
                    'Gồm cả ngôn ngữ mới được thêm vào kho.',
                  ),
                  value: all,
                  onChanged: saving
                      ? null
                      : (value) => setState(() => all = value),
                ),
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
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text(
                    'Chỉ ẩn hoặc hiện danh sách; các nguồn đã cài vẫn được giữ.',
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}
