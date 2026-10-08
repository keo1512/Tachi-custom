import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/widgets/feedback.dart';
import '../../library/presentation/library_view_model.dart';
import '../../settings/presentation/connection_dialog.dart';
import '../../settings/settings_controller.dart';
import '../domain/catalogue.dart';
import 'source_preferences_dialog.dart';

class BrowseScreen extends ConsumerStatefulWidget {
  const BrowseScreen({super.key});
  @override
  ConsumerState<BrowseScreen> createState() => _BrowseState();
}

class _BrowseState extends ConsumerState<BrowseScreen> {
  bool extensions = false, loading = false, searching = false;
  SourceEngine engine = SourceEngine.tachimanga;
  List<CatalogueSource> sources = [];
  List<CatalogueExtension> packages = [];
  final installing = <String>{};
  String? error;
  String query = '', lastConnection = '';
  int request = 0;

  @override
  void initState() {
    super.initState();
    Future.microtask(load);
  }

  Future<void> load() async {
    final current = ++request;
    final target = engine;
    final showExtensions = extensions;
    if (mounted) {
      setState(() {
        loading = true;
        error = null;
      });
    }
    final settings = ref.read(settingsProvider);
    final configured = target == SourceEngine.vbook
        ? settings.vbookUrl
        : settings.tachimangaUrl;
    if (configured.isEmpty) {
      if (mounted && current == request) {
        setState(() {
          loading = false;
          sources = [];
          packages = [];
        });
      }
      return;
    }
    try {
      final repo = ref.read(sourceRepositoryProvider);
      final result = showExtensions
          ? await repo.extensions(target)
          : await repo.listSources(target);
      if (!mounted || current != request) return;
      setState(() {
        if (showExtensions) {
          packages = result.cast<CatalogueExtension>();
        } else {
          sources = result.cast<CatalogueSource>();
        }
        loading = false;
      });
    } catch (e) {
      if (mounted && current == request) {
        setState(() {
          error = '$e';
          loading = false;
        });
      }
    }
  }

  Future<void> connect() async {
    await showConnections(context, ref);
    if (mounted) await load();
  }

  Future<void> add() async {
    final target = engine;
    var url = '';
    var registry = true;
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) => AlertDialog(
          title: Text(
            target == SourceEngine.tachimanga
                ? 'Thêm extension Tachimanga'
                : 'Thêm extension vBook',
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: double.infinity,
                child: CupertinoSlidingSegmentedControl<bool>(
                  groupValue: registry,
                  children: const {
                    true: Text('Repository'),
                    false: Text('Gói extension'),
                  },
                  onValueChanged: (value) {
                    if (value != null) set(() => registry = value);
                  },
                ),
              ),
              const SizedBox(height: 14),
              TextFormField(
                onChanged: (value) => url = value,
                keyboardType: TextInputType.url,
                autocorrect: false,
                decoration: InputDecoration(
                  labelText: registry
                      ? 'URL registry JSON'
                      : target == SourceEngine.tachimanga
                      ? 'URL APK'
                      : 'URL plugin.zip',
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Hủy'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Thêm'),
            ),
          ],
        ),
      ),
    );
    final value = url.trim();
    if (result != true || value.isEmpty || !mounted) return;
    await perform(context, () async {
      final repo = ref.read(sourceRepositoryProvider);
      if (registry) {
        await repo.addRepository(target, value);
      } else {
        await repo.installExtension(target, value);
      }
      await load();
    }, success: registry ? 'Đã thêm repository' : 'Đã cài extension');
  }

  Future<void> install(CatalogueExtension package) async {
    final key = '${package.engine.name}:${package.id}';
    if (installing.contains(key)) return;
    setState(() => installing.add(key));
    await perform(context, () async {
      await ref
          .read(sourceRepositoryProvider)
          .installExtension(package.engine, package.installRef);
      if (mounted) await load();
    });
    if (mounted) setState(() => installing.remove(key));
  }

  Widget panel({
    required IconData icon,
    required String title,
    required String detail,
    Widget? action,
  }) => Center(
    child: SingleChildScrollView(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 340),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                icon,
                size: 36,
                color: CupertinoColors.secondaryLabel.resolveFrom(context),
              ),
              const SizedBox(height: 12),
              Text(
                title,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                detail,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 13,
                  height: 1.4,
                  color: CupertinoColors.secondaryLabel.resolveFrom(context),
                ),
              ),
              if (action != null) ...[const SizedBox(height: 8), action],
            ],
          ),
        ),
      ),
    ),
  );

  Widget extensionList() {
    final visible = packages
        .where(
          (package) => package.name.toLowerCase().contains(query.toLowerCase()),
        )
        .toList();
    if (visible.isEmpty) {
      return panel(
        icon: CupertinoIcons.square_stack_3d_up,
        title: packages.isEmpty ? 'Chưa có extension' : 'Không có kết quả',
        detail: packages.isEmpty
            ? 'Thêm repository hoặc gói extension bằng nút +.'
            : 'Thử tìm bằng tên extension khác.',
        action: packages.isEmpty
            ? TextButton(onPressed: add, child: const Text('Thêm extension'))
            : null,
      );
    }
    return RefreshIndicator(
      onRefresh: load,
      child: ListView.separated(
        physics: const AlwaysScrollableScrollPhysics(),
        itemCount: visible.length,
        separatorBuilder: (_, _) => const Divider(height: 1, indent: 58),
        itemBuilder: (_, index) {
          final package = visible[index];
          final pending = installing.contains(
            '${package.engine.name}:${package.id}',
          );
          return ListTile(
            minTileHeight: 60,
            minVerticalPadding: 6,
            horizontalTitleGap: 12,
            contentPadding: const EdgeInsets.symmetric(horizontal: 16),
            leading: const SizedBox(
              width: 30,
              height: 36,
              child: Icon(CupertinoIcons.square_stack_3d_up, size: 25),
            ),
            title: Text(
              package.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 16),
            ),
            subtitle: Text(
              '${package.lang.toUpperCase()} · ${package.version}${package.limitations.isEmpty ? '' : ' · ${package.limitations.join(', ')}'}',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                color: CupertinoColors.secondaryLabel.resolveFrom(context),
              ),
            ),
            trailing: pending
                ? const CupertinoActivityIndicator()
                : package.installed
                ? Text(
                    'Đã cài',
                    style: TextStyle(
                      fontSize: 13,
                      color: CupertinoColors.secondaryLabel.resolveFrom(
                        context,
                      ),
                    ),
                  )
                : CupertinoButton(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    minimumSize: const Size(44, 44),
                    onPressed: () => install(package),
                    child: const Text('Cài', style: TextStyle(fontSize: 15)),
                  ),
          );
        },
      ),
    );
  }

  Widget sourceList() {
    final visible = sources
        .where(
          (source) => source.name.toLowerCase().contains(query.toLowerCase()),
        )
        .toList();
    if (visible.isEmpty) {
      return panel(
        icon: CupertinoIcons.square_stack_3d_up,
        title: sources.isEmpty ? 'Chưa có nguồn' : 'Không có kết quả',
        detail: sources.isEmpty
            ? 'Mở Tiện ích để cài extension.'
            : 'Thử tìm bằng tên nguồn khác.',
        action: sources.isEmpty
            ? TextButton(
                onPressed: () {
                  setState(() => extensions = true);
                  load();
                },
                child: const Text('Mở tiện ích'),
              )
            : null,
      );
    }
    return RefreshIndicator(
      onRefresh: load,
      child: ListView.separated(
        physics: const AlwaysScrollableScrollPhysics(),
        itemCount: visible.length,
        separatorBuilder: (_, _) => const Divider(height: 1, indent: 58),
        itemBuilder: (_, index) {
          final source = visible[index];
          return ListTile(
            minTileHeight: 60,
            minVerticalPadding: 6,
            horizontalTitleGap: 12,
            contentPadding: const EdgeInsets.symmetric(horizontal: 16),
            leading: SizedBox(
              width: 30,
              height: 36,
              child: Icon(
                source.kind == ContentKind.manga
                    ? CupertinoIcons.photo
                    : CupertinoIcons.book,
                size: 25,
              ),
            ),
            title: Text(
              source.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 16),
            ),
            subtitle: Text(
              '${source.lang.toUpperCase()} · ${source.kind == ContentKind.manga ? 'Truyện tranh' : 'Truyện chữ'}',
              style: TextStyle(
                fontSize: 12,
                color: CupertinoColors.secondaryLabel.resolveFrom(context),
              ),
            ),
            trailing: source.engine == SourceEngine.tachimanga
                ? IconButton(
                    tooltip: 'Cấu hình ${source.name}',
                    onPressed: () => showSourcePreferences(context, source),
                    icon: const Icon(CupertinoIcons.gear, size: 21),
                  )
                : const Icon(
                    CupertinoIcons.chevron_right,
                    size: 14,
                    color: CupertinoColors.systemGrey,
                  ),
            onTap: () => context.push('/source', extra: source),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
    final connection = '${settings.tachimangaUrl}|${settings.vbookUrl}';
    if (lastConnection != connection) {
      lastConnection = connection;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) load();
      });
    }
    final configured = engine == SourceEngine.vbook
        ? settings.vbookUrl.isNotEmpty
        : settings.tachimangaUrl.isNotEmpty;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Duyệt'),
        leading: IconButton(
          tooltip: 'Tìm nguồn hoặc extension',
          icon: const Icon(CupertinoIcons.search, size: 22),
          onPressed: () => setState(() {
            searching = !searching;
            if (!searching) query = '';
          }),
        ),
        actions: [
          if (extensions)
            IconButton(
              tooltip: 'Thêm repository hoặc extension',
              onPressed: configured ? add : connect,
              icon: const Icon(CupertinoIcons.plus, size: 23),
            ),
          PopupMenuButton<String>(
            tooltip: 'Tùy chọn duyệt',
            icon: const Icon(CupertinoIcons.ellipsis, size: 23),
            onSelected: (value) {
              if (value == 'connection') {
                connect();
              } else {
                load();
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'refresh', child: Text('Làm mới')),
              PopupMenuItem(value: 'connection', child: Text('Kết nối nguồn')),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 7, 16, 7),
            child: SizedBox(
              width: double.infinity,
              child: CupertinoSlidingSegmentedControl<bool>(
                groupValue: extensions,
                children: const {
                  false: Padding(
                    padding: EdgeInsets.symmetric(vertical: 3),
                    child: Text('Nguồn', style: TextStyle(fontSize: 14)),
                  ),
                  true: Padding(
                    padding: EdgeInsets.symmetric(vertical: 3),
                    child: Text('Tiện ích', style: TextStyle(fontSize: 14)),
                  ),
                },
                onValueChanged: (value) {
                  if (value == null || value == extensions) return;
                  setState(() => extensions = value);
                  load();
                },
              ),
            ),
          ),
          if (searching)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: CupertinoSearchTextField(
                autofocus: true,
                placeholder: extensions ? 'Tên extension' : 'Tên nguồn',
                onChanged: (value) => setState(() => query = value),
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 5),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    extensions ? 'EXTENSION' : 'NGUỒN',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      color: CupertinoColors.secondaryLabel.resolveFrom(
                        context,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  width: 200,
                  child: CupertinoSegmentedControl<SourceEngine>(
                    groupValue: engine,
                    padding: EdgeInsets.zero,
                    children: const {
                      SourceEngine.tachimanga: Padding(
                        padding: EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 3,
                        ),
                        child: Text(
                          'Tachimanga',
                          style: TextStyle(fontSize: 12),
                        ),
                      ),
                      SourceEngine.vbook: Padding(
                        padding: EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 3,
                        ),
                        child: Text('vBook', style: TextStyle(fontSize: 12)),
                      ),
                    },
                    onValueChanged: (value) {
                      if (value == engine) return;
                      setState(() => engine = value);
                      load();
                    },
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          if (!extensions) ...[
            ListTile(
              minTileHeight: 60,
              minVerticalPadding: 6,
              horizontalTitleGap: 12,
              contentPadding: const EdgeInsets.symmetric(horizontal: 16),
              leading: const SizedBox(
                width: 30,
                height: 36,
                child: Icon(CupertinoIcons.folder, size: 25),
              ),
              title: const Text(
                'Nguồn trong thiết bị',
                style: TextStyle(fontSize: 16),
              ),
              subtitle: Text(
                'EPUB · TXT · CBZ · ZIP',
                style: TextStyle(
                  fontSize: 12,
                  color: CupertinoColors.secondaryLabel.resolveFrom(context),
                ),
              ),
              trailing: const Icon(
                CupertinoIcons.chevron_right,
                size: 14,
                color: CupertinoColors.systemGrey,
              ),
              onTap: () => perform(
                context,
                () => ref.read(libraryProvider.notifier).importFiles(),
              ),
            ),
            const Divider(height: 1, indent: 58),
          ],
          Expanded(
            child: loading
                ? const Center(child: CupertinoActivityIndicator())
                : !configured
                ? panel(
                    icon: CupertinoIcons.link,
                    title:
                        'Kết nối ${engine == SourceEngine.vbook ? 'vBook' : 'Tachimanga'}',
                    detail: 'Cấu hình kết nối nguồn trong Thêm hoặc menu •••. Nội dung đã lưu vẫn đọc offline.',
                    action: TextButton(
                      onPressed: () => context.go('/more'),
                      child: const Text('Mở cài đặt'),
                    ),
                  )
                : error != null
                ? panel(
                    icon: CupertinoIcons.wifi_slash,
                    title: 'Không kết nối được',
                    detail: error!,
                    action: TextButton(
                      onPressed: load,
                      child: const Text('Thử lại'),
                    ),
                  )
                : extensions
                ? extensionList()
                : sourceList(),
          ),
        ],
      ),
    );
  }
}
