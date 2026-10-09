import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/widgets/feedback.dart';
import '../../library/presentation/library_view_model.dart';
import '../../settings/presentation/connection_dialog.dart';
import '../../settings/settings_controller.dart';
import '../domain/catalogue.dart';
import 'browse_dialogs.dart';
import 'browse_widgets.dart';
import 'source_migration_view.dart';
import 'source_preferences_dialog.dart';
import 'extension_catalogue_controller.dart';
import 'extension_catalogue_view.dart';

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
        if (connection(settings, engine).isEmpty) return;
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
            setState(() => errors[engine] = '$error');
          }
        }
      }),
    );
    if (mounted && current == request) setState(() => loading = false);
  }

  Future<void> connect() async {
    await showConnections(context, ref);
    if (mounted) await load();
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

  void requireEngine(SourceEngine engine) {
    if (connection(ref.read(settingsProvider), engine).isEmpty) {
      throw StateError(
        'Bản này chưa có engine ${sourceEngineName(engine)} chạy trực tiếp '
        'trên iPhone. Để cài và đọc nguồn, mở Thêm → Chung → Kết nối nguồn '
        'và kết nối engine. Danh sách kho vẫn dùng được khi chưa kết nối.',
      );
    }
  }

  Future<void> install(CatalogueExtension package) async {
    final key = '${package.engine.name}:${package.id}';
    if (installing.contains(key)) return;
    setState(() => installing.add(key));
    await perform(context, () async {
      requireEngine(package.engine);
      await ref
          .read(sourceRepositoryProvider)
          .installExtension(
            package.engine,
            package.packageUrl.isEmpty
                ? package.installRef
                : package.packageUrl,
          );
      if (mounted) await load();
    });
    if (mounted) setState(() => installing.remove(key));
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
            onPressed: () => Navigator.pop(ctx, '*'),
            child: const Text('Tất cả ngôn ngữ'),
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
      setState(() => language = selected == '*' ? null : selected);
    }
  }

  List<Widget> connectionNotes() {
    final settings = ref.read(settingsProvider);
    return [
      for (final engine in SourceEngine.values)
        if (errors[engine] != null)
          BrowseNote(
            '${sourceEngineName(engine)}: ${errors[engine]}',
            onRetry: load,
          )
        else if (connection(settings, engine).isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                onPressed: connect,
                child: Text('Kết nối ${sourceEngineName(engine)}'),
              ),
            ),
          ),
    ];
  }

  Widget sourceRow(CatalogueSource source, Set<String> pinned) =>
      SourceBrowseRow(
        source: source,
        pinned: pinned.contains(source.identity),
        onOpen: () => openSource(source),
        onPin: () => perform(
          context,
          () => ref
              .read(settingsProvider.notifier)
              .toggleSourcePin(source.identity),
        ),
        onInfo: () => showSourceInfo(context, source),
        onPreferences: source.engine == SourceEngine.tachimanga
            ? () => showSourcePreferences(context, source)
            : null,
      );

  Widget sourceList() {
    final settings = ref.watch(settingsProvider);
    final pinned = settings.pinnedSources.toSet();
    final visible =
        sources
            .where(
              (source) =>
                  source.name.toLowerCase().contains(query.toLowerCase()) &&
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
    final pins = visible.where((source) => pinned.contains(source.identity));
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
          ...connectionNotes(),
          if (recent.isNotEmpty) ...[
            const BrowseHeading('Sử dụng lần cuối'),
            for (final source in recent) sourceRow(source, pinned),
          ],
          if (pins.isNotEmpty) ...[
            const BrowseHeading('Đã ghim'),
            for (final source in pins) sourceRow(source, pinned),
          ],
          for (final lang in langs) ...[
            BrowseHeading(sourceLanguage(lang)),
            for (final source in grouped[lang]!) sourceRow(source, pinned),
          ],
          if (visible.isEmpty && !loading)
            BrowseNote(
              sources.isEmpty
                  ? 'Chưa có nguồn. Mở Phần mở rộng để cài extension.'
                  : 'Không có nguồn phù hợp với bộ lọc.',
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
            onTap: () => perform(
              context,
              () => ref.read(libraryProvider.notifier).importFiles(),
            ),
          ),
        ],
      ),
    );
  }

  Widget extensionList() => ExtensionCatalogueView(
    installed: packageLists.values.expand((items) => items).toList(),
    installing: installing,
    onInstall: install,
    onAdd: add,
    query: query,
    language: language,
    onRefresh: load,
    adding: adding,
    engineErrors: [
      for (final entry in errors.entries)
        'Trạng thái ${sourceEngineName(entry.key)}: ${entry.value}',
    ],
  );

  @override
  Widget build(BuildContext context) {
    ref.listen(
      settingsProvider.select((s) => (s.tachimangaUrl, s.vbookUrl)),
      (_, _) => load(),
    );
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Duyệt'),
          leading: IconButton(
            tooltip: 'Kết nối nguồn',
            icon: const Icon(CupertinoIcons.cloud),
            onPressed: connect,
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
            PopupMenuButton<String>(
              tooltip: 'Quản lý nguồn và extension',
              icon: const Icon(CupertinoIcons.globe),
              onSelected: (value) {
                if (value == 'add') {
                  add();
                } else if (value == 'connection') {
                  connect();
                } else {
                  load();
                  if (tab == 1) {
                    perform(
                      context,
                      () => ref
                          .read(extensionCatalogueProvider.notifier)
                          .refresh(),
                    );
                  }
                }
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'refresh', child: Text('Làm mới')),
                PopupMenuItem(
                  value: 'add',
                  child: Text('Thêm kho hoặc gói extension'),
                ),
                PopupMenuItem(
                  value: 'connection',
                  child: Text('Kết nối nguồn'),
                ),
              ],
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
              Tab(text: 'Nguồn'),
              Tab(text: 'Phần mở rộng'),
              Tab(text: 'Di chuyển'),
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
            if (searching)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                child: CupertinoSearchTextField(
                  autofocus: true,
                  placeholder: tab == 2
                      ? 'Tên truyện trong thư viện'
                      : 'Tên nguồn hoặc extension',
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
            Expanded(
              child: tab == 0
                  ? sourceList()
                  : tab == 1
                  ? extensionList()
                  : SourceMigrationView(
                      sources: sources,
                      onOpenSource: openSource,
                      query: query,
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
