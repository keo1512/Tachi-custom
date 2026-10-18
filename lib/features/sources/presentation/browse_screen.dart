import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/widgets/feedback.dart';
import '../../library/presentation/library_view_model.dart';
import '../../settings/presentation/settings_widgets.dart';
import '../../settings/settings_controller.dart';
import '../../sync/presentation/sync_screen.dart';
import '../domain/catalogue.dart';
import '../domain/source_languages.dart';
import 'browse_dialogs.dart';
import 'browse_widgets.dart';
import 'source_migration_library_screen.dart';
import 'local_source_screen.dart';
import 'source_preferences_dialog.dart';
import 'extension_catalogue_controller.dart';
import 'extension_catalogue_view.dart';
import 'extension_file_import.dart';
import 'global_search_screen.dart';
import 'source_order_sheet.dart';
import 'source_catalogue_tools.dart';
import 'source_languages_controller.dart';
import 'source_languages_sheet.dart';

class BrowseScreen extends ConsumerStatefulWidget {
  const BrowseScreen({super.key});
  @override
  ConsumerState<BrowseScreen> createState() => _BrowseState();
}

class _BrowseState extends ConsumerState<BrowseScreen> {
  int tab = 0, request = 0;
  bool loading = false, searching = false, adding = false;
  String query = '';
  String? language;
  final sourceLists = <SourceEngine, List<CatalogueSource>>{};
  final packageLists = <SourceEngine, List<CatalogueExtension>>{};
  final sourceUrls = <SourceEngine, String>{};
  final packageUrls = <SourceEngine, String>{};
  final errors = <SourceEngine, String>{};
  final installing = <String>{};
  final queuedInstalls = <String>{};
  final installErrors = <String, String>{};
  bool updatingAll = false;
  bool importing = false;

  @override
  void initState() {
    super.initState();
    Future.microtask(load);
  }

  String connection(AppSettings settings, SourceEngine engine) =>
      engine == SourceEngine.tachimanga
      ? settings.tachimangaUrl
      : settings.vbookUrl;

  List<CatalogueSource> get sources =>
      sourceLists.values.expand((values) => values).toList();

  Future<void> load() async {
    if (!mounted) return;
    final current = ++request;
    final extensions = tab == 1;
    final settings = ref.read(settingsProvider);
    final repo = ref.read(sourceRepositoryProvider);
    final urls = extensions ? packageUrls : sourceUrls;
    setState(() {
      loading = true;
      errors.clear();
      for (final engine in SourceEngine.values) {
        final url = connection(settings, engine);
        if (urls[engine] != url) {
          if (extensions) {
            packageLists.remove(engine);
          } else {
            sourceLists.remove(engine);
          }
          urls[engine] = url;
        }
      }
    });
    await Future.wait(
      SourceEngine.values.map((engine) async {
        if (repo.requiresExternalConnection(engine) &&
            connection(settings, engine).isEmpty) {
          return;
        }
        try {
          if (extensions) {
            final result = await repo.extensions(engine);
            if (mounted && current == request) {
              setState(() => packageLists[engine] = result);
            }
          } else {
            final result = await repo.listSources(engine);
            if (mounted && current == request) {
              setState(() => sourceLists[engine] = result);
            }
          }
        } catch (error) {
          if (mounted && current == request) {
            setState(() => errors[engine] = userFacingError(error));
          }
        }
      }),
    );
    if (mounted && current == request) setState(() => loading = false);
  }

  Future<void> manageRepositories() async {
    await context.push('/repositories');
    if (mounted) await load();
  }

  Future<void> showTools() async {
    final choice = await showCupertinoModalPopup<String>(
      context: context,
      builder: (ctx) => CupertinoActionSheet(
        title: const Text('Công cụ nguồn'),
        actions: [
          CupertinoActionSheetAction(
            onPressed: () => Navigator.pop(ctx, 'repositories'),
            child: const Text('Kho tiện ích mở rộng'),
          ),
          CupertinoActionSheetAction(
            onPressed: () => Navigator.pop(ctx, 'migration'),
            child: const Text('Chuyển nguồn'),
          ),
          CupertinoActionSheetAction(
            onPressed: () => Navigator.pop(ctx, 'local'),
            child: const Text('Truyện trong thiết bị'),
          ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('Hủy'),
        ),
      ),
    );
    if (!mounted) return;
    if (choice == 'repositories') {
      await manageRepositories();
    } else if (choice == 'migration') {
      await Navigator.of(context).push(
        CupertinoPageRoute(
          builder: (_) => const SourceMigrationLibraryScreen(),
        ),
      );
    } else if (choice == 'local') {
      await Navigator.of(context)
          .push(CupertinoPageRoute(builder: (_) => const LocalSourceScreen()));
    }
  }

  Future<void> add() async {
    if (adding) return;
    final engine = await chooseExtensionEngine(context);
    if (engine == null || !mounted) return;
    final input = await requestExtension(context, engine);
    if (input == null || input.url.isEmpty || !mounted) return;
    setState(() => adding = true);
    await perform(context, () async {
      final repo = ref.read(sourceRepositoryProvider);
      if (input.repository) {
        await ref
            .read(extensionCatalogueProvider.notifier)
            .add(engine, input.url);
      } else {
        requireEngine(engine);
        await repo.installExtension(engine, input.url);
      }
      if (mounted) await load();
    }, success: input.repository ? 'Đã thêm repository' : 'Đã cài extension');
    if (mounted) setState(() => adding = false);
  }

  Future<void> importApk() async {
    if (importing || updatingAll || installing.isNotEmpty) return;
    setState(() => importing = true);
    try {
      await perform(context, () async {
        final bytes = await ref.read(extensionPackagePickerProvider)();
        if (bytes == null || !mounted) return;
        final repository = ref.read(sourceRepositoryProvider);
        final package = await repository.installExtensionBytes(
          SourceEngine.tachimanga,
          bytes,
        );
        // Host metadata describes the actual loaded APK, not its filename.
        final confirmed = await repository.extensions(SourceEngine.tachimanga);
        if (!package.installed ||
            !confirmed.any(
              (item) =>
                  item.installed &&
                  item.id == package.id &&
                  item.version == package.version,
            )) {
          throw const ApiException('Engine chưa xác nhận gói APK vừa nhập.');
        }
        if (!mounted) return;
        setState(() => packageLists[SourceEngine.tachimanga] = confirmed);
        await load();
        if (mounted) {
          message(context, 'Đã cài ${package.name} ${package.version}');
        }
      });
    } finally {
      if (mounted) setState(() => importing = false);
    }
  }

  void requireEngine(SourceEngine engine) {
    if (ref.read(sourceRepositoryProvider).requiresExternalConnection(engine) &&
        connection(ref.read(settingsProvider), engine).isEmpty) {
      throw ApiException(
        'Chưa có engine ${sourceEngineName(engine)} trên thiết bị này.',
      );
    }
  }

  Future<void> install(CatalogueExtension package) async {
    final key = '${package.engine.name}:${package.id}';
    if (importing || updatingAll || installing.contains(key)) return;
    setState(() => installing.add(key));
    await perform(context, () async {
      await installPackage(package);
    });
    if (mounted) setState(() => installing.remove(key));
  }

  Future<void> installPackage(CatalogueExtension package) async {
    final key = '${package.engine.name}:${package.id}';
    if (mounted) setState(() => installErrors.remove(key));
    try {
      requireEngine(package.engine);
      final repository = ref.read(sourceRepositoryProvider);
      await repository.installExtension(
        package.engine,
        package.packageUrl.isEmpty ? package.installRef : package.packageUrl,
      );
      final confirmed = await repository.extensions(package.engine);
      if (!confirmed.any(
        (item) =>
            item.installed &&
            sameExtension(item, package) &&
            item.version == package.version,
      )) {
        throw const ApiException(
          'Engine chưa xác nhận đúng phiên bản extension vừa cài.',
        );
      }
      if (mounted) {
        setState(() => packageLists[package.engine] = confirmed);
        await load();
      }
    } catch (error) {
      if (mounted) setState(() => installErrors[key] = userFacingError(error));
      rethrow;
    }
  }

  Future<void> updateAllExtensions() async {
    if (importing || updatingAll || installing.isNotEmpty) return;
    final updates = availableExtensionUpdates(
      ref
              .read(extensionCatalogueProvider)
              .value
              ?.expand((index) => index.entries) ??
          const [],
      packageLists.values.expand((items) => items),
    );
    if (updates.isEmpty) return;
    setState(() {
      updatingAll = true;
      queuedInstalls.addAll(updates.map((p) => '${p.engine.name}:${p.id}'));
    });
    var passed = 0, failed = 0;
    for (final package in updates) {
      if (!mounted) break;
      final key = '${package.engine.name}:${package.id}';
      setState(() {
        queuedInstalls.remove(key);
        installing.add(key);
      });
      try {
        await installPackage(package);
        passed++;
      } catch (_) {
        failed++;
      }
      if (mounted) setState(() => installing.remove(key));
    }
    if (mounted) {
      setState(() {
        updatingAll = false;
        queuedInstalls.clear();
      });
      message(
        context,
        'Đã cập nhật $passed extension${failed > 0 ? ', $failed extension lỗi.' : '.'}',
      );
    }
  }

  Future<void> uninstall(CatalogueExtension package) async {
    if (importing || updatingAll || installing.isNotEmpty) return;
    final accepted = await showCupertinoDialog<bool>(
      context: context,
      builder: (ctx) => CupertinoAlertDialog(
        title: Text('Gỡ ${package.name}?'),
        content: const Text(
          'Các nguồn của extension sẽ không còn truy cập được. Truyện trong thư viện và nội dung đã tải vẫn được giữ.',
        ),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Hủy'),
          ),
          CupertinoDialogAction(
            isDestructiveAction: true,
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Gỡ'),
          ),
        ],
      ),
    );
    if (accepted != true ||
        !mounted ||
        importing ||
        updatingAll ||
        installing.isNotEmpty) {
      return;
    }
    final key = '${package.engine.name}:${package.id}';
    setState(() => installing.add(key));
    try {
      await perform(context, () async {
        await ref
            .read(sourceRepositoryProvider)
            .uninstallExtension(package.engine, package.id);
        await load();
      });
    } finally {
      if (mounted) setState(() => installing.remove(key));
    }
  }

  Future<void> globalSearch() async {
    final languages = ref.read(sourceLanguagesProvider);
    await Navigator.of(context).push(
      CupertinoPageRoute(
        builder: (_) => GlobalSearchScreen(
          sources: sources
              .where((source) => languages.allows(source.lang))
              .toList(),
        ),
      ),
    );
  }

  Future<void> showPackageInfo(CatalogueExtension package) async {
    final names = {for (final source in sources) source.identity: source.name};
    if (package.installed && package.sourceIds.isNotEmpty) {
      try {
        final loaded = await ref
            .read(sourceRepositoryProvider)
            .listSources(package.engine);
        for (final source in loaded) {
          names[source.identity] = source.name;
        }
      } catch (_) {
        // Package information remains available when one source cannot load.
      }
    }
    if (!mounted) return;
    final available = ref
        .read(extensionCatalogueProvider)
        .value
        ?.expand((index) => index.entries)
        .where((item) => sameExtension(item, package))
        .firstOrNull;
    final update =
        available != null &&
        package.installed &&
        (compareExtensionVersions(available.version, package.version) ?? 0) > 0;
    await showCupertinoDialog<void>(
      context: context,
      builder: (ctx) => CupertinoAlertDialog(
        title: Text(package.name),
        content: SingleChildScrollView(
          child: Text(
            [
              '${sourceEngineName(package.engine)} · ${package.version}',
              package.id,
              package.installed
                  ? 'Đã cài và nạp nguồn'
                  : package.loadError.isNotEmpty
                  ? 'Đã lưu gói nhưng chưa nạp được nguồn'
                  : 'Chưa được engine xác nhận đã cài',
              if (package.loadError.isNotEmpty) package.loadError,
              if (package.sourceIds.isNotEmpty)
                'Nguồn của gói:\n${package.sourceIds.map((id) => names['${package.engine.name}:$id'] ?? 'Nguồn chưa nạp').join('\n')}',
              ...package.limitations,
            ].join('\n\n'),
          ),
        ),
        actions: [
          if (!package.installed || update)
            CupertinoDialogAction(
              onPressed: () {
                Navigator.pop(ctx);
                install(update ? available : package);
              },
              child: Text(update ? 'Cập nhật' : 'Cài đặt'),
            ),
          if (package.installed &&
              ref
                  .read(sourceRepositoryProvider)
                  .supportsExtensionRemoval(package.engine))
            CupertinoDialogAction(
              isDestructiveAction: true,
              onPressed: () {
                Navigator.pop(ctx);
                uninstall(package);
              },
              child: const Text('Gỡ tiện ích'),
            ),
          CupertinoDialogAction(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Đóng'),
          ),
        ],
      ),
    );
  }

  Future<void> reorderPinned() async {
    final byId = {for (final source in sources) source.identity: source};
    final pins = ref
        .read(settingsProvider)
        .pinnedSources
        .map((id) => byId[id])
        .whereType<CatalogueSource>()
        .toList();
    final ordered = await showPinnedSourceOrder(context, pins);
    if (ordered == null || !mounted) return;
    await perform(
      context,
      () => ref.read(settingsProvider.notifier).setPinnedSourceOrder(ordered),
    );
  }

  Future<void> openSource(CatalogueSource source) async {
    await perform(context, () async {
      await ref
          .read(settingsProvider.notifier)
          .recordSourceUse(source.identity);
      if (mounted) context.push('/source', extra: source);
    });
  }

  Future<void> chooseLanguage() async {
    final codes = <String>{
      ...sources.map((source) => source.lang),
      ...packageLists.values
          .expand((values) => values)
          .map((item) => item.lang),
      ...?ref
          .read(extensionCatalogueProvider)
          .asData
          ?.value
          .expand((index) => index.entries)
          .map((item) => item.lang),
    }.toList()..sort((a, b) => sourceLanguage(a).compareTo(sourceLanguage(b)));
    final selected = await showCupertinoModalPopup<String>(
      context: context,
      builder: (ctx) => CupertinoActionSheet(
        title: const Text('Ngôn ngữ'),
        actions: [
          CupertinoActionSheetAction(
            onPressed: () => Navigator.pop(ctx, '@multiple'),
            child: const Text('Chọn nhiều ngôn ngữ và lưu'),
          ),
          CupertinoActionSheetAction(
            onPressed: () => Navigator.pop(ctx, '*'),
            child: Text(
              ref.read(sourceLanguagesProvider).enabled == null
                  ? 'Tất cả ngôn ngữ'
                  : 'Tất cả ngôn ngữ đã bật',
            ),
          ),
          for (final code in codes)
            CupertinoActionSheetAction(
              onPressed: () => Navigator.pop(ctx, code),
              child: Text(sourceLanguage(code)),
            ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('Hủy'),
        ),
      ),
    );
    if (selected != null && mounted) {
      if (selected == '@multiple') {
        await showSourceLanguages(context, codes.toSet());
        if (mounted) setState(() => language = null);
        return;
      }
      setState(() => language = selected == '*' ? null : selected);
    }
  }

  Future<void> resetFilters() => perform(context, () async {
    await ref
        .read(sourceLanguagesProvider.notifier)
        .save(const SourceLanguages(null));
    if (!mounted) return;
    setState(() {
      query = '';
      language = null;
      searching = false;
    });
  });

  List<Widget> connectionNotes() {
    return [
      for (final engine in SourceEngine.values)
        if (errors[engine] != null)
          BrowseNote(
            '${sourceEngineName(engine)}: ${errors[engine]}',
            onRetry: load,
          ),
    ];
  }

  Widget sourceRow(
    CatalogueSource source,
    Set<String> pinned,
  ) => SourceBrowseRow(
    source: source,
    pinned: pinned.contains(source.identity),
    onOpen: () => openSource(source),
    onPin: () => perform(
      context,
      () =>
          ref.read(settingsProvider.notifier).toggleSourcePin(source.identity),
    ),
    onInfo: () => showSourceInfo(context, source),
    onPreferences:
        source.engine == SourceEngine.tachimanga && source.configurable != false
        ? () => showSourcePreferences(context, source)
        : null,
  );

  Widget sourceList() {
    final settings = ref.watch(settingsProvider);
    final languages = ref.watch(sourceLanguagesProvider);
    final pinned = settings.pinnedSources.toSet();
    final visible =
        sources
            .where(
              (source) =>
                  source.name.toLowerCase().contains(query.toLowerCase()) &&
                  languages.allows(source.lang) &&
                  (language == null || source.lang == language),
            )
            .toList()
          ..sort((a, b) => a.name.compareTo(b.name));
    final byIdentity = {for (final source in visible) source.identity: source};
    final recent = settings.recentSources
        .map((id) => byIdentity[id])
        .whereType<CatalogueSource>()
        .take(1)
        .toList();
    final pins = settings.pinnedSources
        .map((id) => byIdentity[id])
        .whereType<CatalogueSource>()
        .toList();
    final grouped = <String, List<CatalogueSource>>{};
    for (final source in visible.where(
      (source) => !pinned.contains(source.identity),
    )) {
      grouped.putIfAbsent(source.lang, () => []).add(source);
    }
    final langs = grouped.keys.toList()
      ..sort((a, b) => sourceLanguage(a).compareTo(sourceLanguage(b)));
    return RefreshIndicator(
      onRefresh: load,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: EdgeInsets.only(
          bottom: MediaQuery.paddingOf(context).bottom + 16,
        ),
        children: [
          ListTile(
            leading: const Icon(CupertinoIcons.search),
            title: const Text('Tìm truyện toàn bộ nguồn'),
            onTap: sources.isEmpty ? null : globalSearch,
          ),
          ...connectionNotes(),
          if (recent.isNotEmpty) ...[
            const BrowseHeading('Sử dụng lần cuối'),
            for (final source in recent) sourceRow(source, pinned),
          ],
          if (pins.isNotEmpty) ...[
            Row(
              children: [
                const Expanded(child: BrowseHeading('Đã ghim')),
                if (settings.pinnedSources.length > 1)
                  IconButton(
                    tooltip: 'Sắp xếp nguồn đã ghim',
                    onPressed: reorderPinned,
                    icon: const Icon(CupertinoIcons.slider_horizontal_3),
                  ),
              ],
            ),
            for (final source in pins) sourceRow(source, pinned),
          ],
          for (final lang in langs) ...[
            BrowseHeading(sourceLanguage(lang)),
            for (final source in grouped[lang]!) sourceRow(source, pinned),
          ],
          if (visible.isEmpty && !loading)
            BrowseNote(
              sources.isEmpty
                  ? 'Chưa có nguồn. Mở Tiện ích để cài extension.'
                  : 'Không có nguồn phù hợp với bộ lọc.',
            ),
          if (visible.isEmpty && sources.isNotEmpty && !loading)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                onPressed: resetFilters,
                child: const Text('Hiện tất cả nguồn'),
              ),
            ),
          if (sources.isEmpty && !loading)
            Builder(
              builder: (tabContext) => Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  onPressed: () {
                    DefaultTabController.of(tabContext).animateTo(1);
                    setState(() => tab = 1);
                    load();
                  },
                  child: const Text('Mở Tiện ích'),
                ),
              ),
            ),
          const BrowseHeading('Trong thiết bị'),
          ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 20),
            leading: const Icon(CupertinoIcons.folder, size: 28),
            title: const Text(
              'Nguồn trong thiết bị',
              style: TextStyle(fontSize: 16),
            ),
            subtitle: const Text(
              'EPUB · TXT · CBZ · ZIP',
              style: TextStyle(fontSize: 13),
            ),
            trailing: const Icon(CupertinoIcons.chevron_right, size: 16),
            onTap: () => Navigator.of(context).push(
              CupertinoPageRoute(builder: (_) => const LocalSourceScreen()),
            ),
          ),
        ],
      ),
    );
  }

  Widget extensionList() => ExtensionCatalogueView(
    installed: packageLists.values.expand((items) => items).toList(),
    installing: installing,
    queued: queuedInstalls,
    installErrors: installErrors,
    updatingAll: updatingAll,
    importing: importing,
    onImportApk:
        ref
            .read(sourceRepositoryProvider)
            .supportsExtensionFileImport(SourceEngine.tachimanga)
        ? importApk
        : null,
    onUpdateAll: updateAllExtensions,
    onUninstall: uninstall,
    onPackageInfo: showPackageInfo,
    canUninstall: (package) => ref
        .read(sourceRepositoryProvider)
        .supportsExtensionRemoval(package.engine),
    onInstall: install,
    onAdd: add,
    onManage: manageRepositories,
    query: query,
    language: language,
    onResetFilters: resetFilters,
    languages: ref.watch(sourceLanguagesProvider),
    onRefresh: load,
    adding: adding,
    engineErrors: [
      for (final entry in errors.entries)
        'Trạng thái ${sourceEngineName(entry.key)}: ${entry.value}',
    ],
  );

  @override
  Widget build(BuildContext context) {
    final enabledLanguages = ref.watch(sourceLanguagesProvider).enabled;
    ref.listen(
      settingsProvider.select((s) => (s.tachimangaUrl, s.vbookUrl)),
      (_, _) => load(),
    );
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Khám phá'),
          leading: IconButton(
            tooltip: 'Đồng bộ',
            icon: const Icon(CupertinoIcons.cloud),
            onPressed: () => openSettingsPage(context, const SyncScreen()),
          ),
          actions: [
            IconButton(
              tooltip: 'Tìm nguồn hoặc extension',
              icon: const Icon(CupertinoIcons.search),
              onPressed: () => setState(() {
                searching = !searching;
                if (!searching) query = '';
              }),
            ),
            IconButton(
              tooltip: 'Công cụ nguồn',
              icon: const Icon(CupertinoIcons.ellipsis),
              onPressed: showTools,
            ),
            IconButton(
              tooltip: 'Ngôn ngữ',
              icon: const Icon(Icons.translate),
              onPressed: chooseLanguage,
            ),
          ],
          bottom: TabBar(
            labelStyle: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w400,
            ),
            unselectedLabelStyle: const TextStyle(fontSize: 14),
            indicatorSize: TabBarIndicatorSize.label,
            indicatorWeight: 3,
            dividerColor: Colors.transparent,
            labelPadding: EdgeInsets.zero,
            tabs: const [
              Tab(text: 'Nguồn truyện'),
              Tab(text: 'Tiện ích'),
            ],
            onTap: (value) {
              if (value == tab) return;
              setState(() => tab = value);
              load();
            },
          ),
        ),
        body: Column(
          children: [
            if (enabledLanguages != null)
              ListTile(
                dense: true,
                title: Text('Đã bật ${enabledLanguages.length} ngôn ngữ'),
                trailing: const Icon(CupertinoIcons.chevron_right, size: 16),
                onTap: chooseLanguage,
              ),
            if (searching)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                child: CupertinoSearchTextField(
                  autofocus: true,
                  placeholder: 'Tên nguồn hoặc tiện ích',
                  onChanged: (value) => setState(() => query = value),
                ),
              ),
            if (language != null)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        sourceLanguage(language!),
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                    TextButton(
                      onPressed: () => setState(() => language = null),
                      child: const Text(
                        'Bỏ lọc',
                        style: TextStyle(fontSize: 12),
                      ),
                    ),
                  ],
                ),
              ),
            if (loading) const LinearProgressIndicator(minHeight: 1),
            Expanded(child: tab == 0 ? sourceList() : extensionList()),
          ],
        ),
      ),
    );
  }
}
