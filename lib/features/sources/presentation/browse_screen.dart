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
  bool extensions = false, loading = false;
  SourceEngine engine = SourceEngine.tachimanga;
  List<CatalogueSource> sources = [];
  List<CatalogueExtension> packages = [];
  String? error;
  int request = 0;
  String lastConnection = '';
  @override
  void initState() {
    super.initState();
    Future.microtask(load);
  }

  Future<void> load() async {
    final current = ++request;
    if (mounted) {
      setState(() {
        loading = true;
        error = null;
      });
    }
    final settings = ref.read(settingsProvider);
    final configured = engine == SourceEngine.vbook
        ? settings.vbookUrl
        : settings.tachimangaUrl;
    if (configured.isEmpty) {
      if (mounted) {
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
      final result = extensions
          ? await repo.extensions(engine)
          : await repo.listSources(engine);
      if (!mounted || current != request) return;
      setState(() {
        if (extensions) {
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

  Future<void> add() async {
    var url = '';
    var registry = true;
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) => AlertDialog(
          title: Text(
            engine == SourceEngine.tachimanga
                ? 'Thêm extension Tachimanga'
                : 'Thêm extension vBook',
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SegmentedButton<bool>(
                segments: const [
                  ButtonSegment(value: true, label: Text('Repository')),
                  ButtonSegment(value: false, label: Text('Gói extension')),
                ],
                selected: {registry},
                onSelectionChanged: (v) => set(() => registry = v.first),
              ),
              const SizedBox(height: 14),
              TextFormField(
                onChanged: (value) => url = value,
                keyboardType: TextInputType.url,
                decoration: InputDecoration(
                  labelText: registry
                      ? 'URL registry JSON'
                      : engine == SourceEngine.tachimanga
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
            FilledButton(
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
        await repo.addRepository(engine, value);
      } else {
        await repo.installExtension(engine, value);
      }
      await load();
    }, success: registry ? 'Đã thêm repository' : 'Đã cài extension');
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
        actions: [
          IconButton(
            tooltip: 'Kết nối nguồn',
            onPressed: () => showConnections(context, ref),
            icon: const Icon(CupertinoIcons.cloud),
          ),
          if (extensions)
            IconButton(
              tooltip: 'Thêm repository hoặc extension',
              onPressed: configured ? add : () => showConnections(context, ref),
              icon: const Icon(CupertinoIcons.plus),
            ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: SizedBox(
              width: double.infinity,
              child: SegmentedButton<bool>(
                segments: const [
                  ButtonSegment(value: false, label: Text('Nguồn')),
                  ButtonSegment(value: true, label: Text('Tiện ích')),
                ],
                selected: {extensions},
                onSelectionChanged: (v) {
                  setState(() => extensions = v.first);
                  load();
                },
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Row(
              children: SourceEngine.values
                  .map(
                    (e) => Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: ChoiceChip(
                        label: Text(
                          e == SourceEngine.tachimanga ? 'Tachimanga' : 'vBook',
                        ),
                        selected: e == engine,
                        showCheckmark: false,
                        onSelected: (_) {
                          setState(() => engine = e);
                          load();
                        },
                      ),
                    ),
                  )
                  .toList(),
            ),
          ),
          if (!extensions)
            ListTile(
              leading: const Icon(CupertinoIcons.folder, color: Colors.orange),
              title: const Text('Nguồn trong thiết bị'),
              subtitle: const Text('EPUB · TXT · CBZ · ZIP'),
              trailing: const Icon(CupertinoIcons.chevron_right, size: 18),
              onTap: () => perform(
                context,
                () => ref.read(libraryProvider.notifier).importFiles(),
              ),
            ),
          const Divider(height: 1),
          Expanded(
            child: loading
                ? const Center(child: CircularProgressIndicator())
                : !configured
                ? EmptyPanel(
                    icon: CupertinoIcons.link,
                    title:
                        'Kết nối ${engine == SourceEngine.vbook ? 'vBook' : 'Tachimanga'}',
                    description: 'Thêm địa chỉ runtime để cài extension và tìm truyện. Sách đã nhập hoặc tải vẫn đọc được offline.',
                    action: FilledButton(
                      onPressed: () => showConnections(context, ref),
                      child: const Text('Thiết lập kết nối'),
                    ),
                  )
                : error != null
                ? EmptyPanel(
                    icon: Icons.wifi_off_rounded,
                    title: 'Không kết nối được',
                    description: error!,
                    action: FilledButton(
                      onPressed: load,
                      child: const Text('Thử lại'),
                    ),
                  )
                : extensions
                ? packages.isEmpty
                      ? EmptyPanel(
                          icon: Icons.extension_outlined,
                          title: 'Chưa có extension',
                          description: 'Thêm repository hoặc cài gói extension gốc của hệ đang chọn.',
                          action: FilledButton(
                            onPressed: add,
                            child: const Text('Thêm extension'),
                          ),
                        )
                      : RefreshIndicator(
                          onRefresh: load,
                          child: ListView.separated(
                            itemCount: packages.length,
                            separatorBuilder: (_, _) =>
                                const Divider(height: 1, indent: 60),
                            itemBuilder: (_, i) {
                              final p = packages[i];
                              return ListTile(
                                leading: const Icon(Icons.extension_outlined),
                                title: Text(p.name),
                                subtitle: Text(
                                  '${p.version} · ${p.lang}${p.limitations.isEmpty ? '' : ' · ${p.limitations.join(', ')}'}',
                                ),
                                trailing: p.installed
                                    ? const Text(
                                        'Đã cài',
                                        style: TextStyle(color: Colors.grey),
                                      )
                                    : TextButton(
                                        onPressed: () => perform(
                                          context,
                                          () async {
                                            await ref
                                                .read(sourceRepositoryProvider)
                                                .installExtension(
                                                  engine,
                                                  p.installRef,
                                                );
                                            await load();
                                          },
                                        ),
                                        child: const Text('Cài'),
                                      ),
                              );
                            },
                          ),
                        )
                : sources.isEmpty
                ? EmptyPanel(
                    icon: CupertinoIcons.square_stack_3d_up,
                    title: 'Chưa có nguồn',
                    description: 'Mở Tiện ích để cài extension.',
                    action: TextButton(
                      onPressed: () {
                        setState(() => extensions = true);
                        load();
                      },
                      child: const Text('Mở tiện ích'),
                    ),
                  )
                : RefreshIndicator(
                    onRefresh: load,
                    child: ListView.separated(
                      itemCount: sources.length,
                      separatorBuilder: (_, _) =>
                          const Divider(height: 1, indent: 62),
                      itemBuilder: (_, i) {
                        final source = sources[i];
                        return ListTile(
                          leading: CircleAvatar(
                            backgroundColor: Colors.blue.withValues(alpha: .08),
                            child: Icon(
                              source.kind == ContentKind.manga
                                  ? CupertinoIcons.photo
                                  : CupertinoIcons.book,
                              size: 22,
                            ),
                          ),
                          title: Text(source.name),
                          subtitle: Text(
                            '${source.lang} · ${source.kind == ContentKind.manga ? 'Truyện tranh' : 'Truyện chữ'}',
                          ),
                          trailing: source.engine == SourceEngine.tachimanga
                              ? IconButton(
                                  tooltip: 'Cấu hình ${source.name}',
                                  onPressed: () =>
                                      showSourcePreferences(context, source),
                                  icon: const Icon(
                                    CupertinoIcons.gear,
                                    size: 21,
                                  ),
                                )
                              : const Icon(
                                  CupertinoIcons.chevron_right,
                                  size: 18,
                                ),
                          onTap: () => context.push('/source', extra: source),
                        );
                      },
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}
