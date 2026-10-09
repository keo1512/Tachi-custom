import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/widgets/feedback.dart';
import '../data/extension_index.dart';
import '../domain/catalogue.dart';
import 'browse_widgets.dart';
import 'extension_catalogue_controller.dart';

class ExtensionCatalogueView extends ConsumerWidget {
  const ExtensionCatalogueView({
    super.key,
    required this.installed,
    required this.installing,
    required this.onInstall,
    required this.onAdd,
    this.query = '',
    this.language,
    this.onRefresh,
    this.adding = false,
    this.engineErrors = const [],
  });
  final List<CatalogueExtension> installed;
  final Set<String> installing;
  final void Function(CatalogueExtension) onInstall;
  final VoidCallback onAdd;
  final String query;
  final String? language;
  final Future<void> Function()? onRefresh;
  final bool adding;
  final List<String> engineErrors;

  bool _visible(CatalogueExtension item) =>
      item.name.toLowerCase().contains(query.toLowerCase()) &&
      (language == null || item.lang == language);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final indexes = ref.watch(extensionCatalogueProvider);
    return RefreshIndicator(
      onRefresh: () async {
        await perform(context, () async {
          await Future.wait([
            ref.read(extensionCatalogueProvider.notifier).refresh(),
            if (onRefresh != null) onRefresh!(),
          ]);
        });
      },
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: EdgeInsets.only(
          bottom: MediaQuery.paddingOf(context).bottom + 16,
        ),
        children: [
          ListTile(
            leading: const Icon(CupertinoIcons.plus),
            title: const Text('Thêm kho extension bằng link'),
            trailing: adding ? const CupertinoActivityIndicator() : null,
            onTap: adding ? null : onAdd,
          ),
          for (final error in engineErrors) BrowseNote(error),
          ...indexes.when(
            loading: () => const <Widget>[LinearProgressIndicator()],
            error: (error, _) => <Widget>[BrowseNote('$error')],
            data: (values) => <Widget>[
              if (values.isEmpty)
                const BrowseNote(
                  'Nhập link kho để xem danh sách, sau đó chọn extension cần cài.',
                ),
              for (final index in values) ..._index(context, ref, index),
            ],
          ),
          if (installed.any((item) => item.installed && _visible(item))) ...[
            const BrowseHeading('Đã cài trong engine'),
            for (final item in installed.where(
              (item) => item.installed && _visible(item),
            ))
              ListTile(
                title: Text(item.name),
                subtitle: Text(
                  '${sourceEngineName(item.engine)} · ${item.version}',
                ),
                trailing: const Text('Đã cài'),
              ),
          ],
        ],
      ),
    );
  }

  List<Widget> _index(
    BuildContext context,
    WidgetRef ref,
    ExtensionIndex index,
  ) {
    final entries = index.entries.where(_visible);
    // Keep rows as ListView children so thousands of packages do not create
    // render objects until they scroll into view.
    return [
      ListTile(
        title: Text(sourceEngineName(index.engine)),
        subtitle: Text(index.url, maxLines: 2, overflow: TextOverflow.ellipsis),
        trailing: IconButton(
          tooltip: 'Gỡ kho khỏi danh sách',
          icon: const Icon(CupertinoIcons.minus_circle),
          onPressed: () => perform(
            context,
            () => ref
                .read(extensionCatalogueProvider.notifier)
                .remove(index.identity),
          ),
        ),
      ),
      if (index.error.isNotEmpty)
        BrowseNote(
          index.error,
          onRetry: () => perform(
            context,
            () => ref.read(extensionCatalogueProvider.notifier).refresh(),
          ),
        ),
      for (final item in entries)
        Builder(
          builder: (context) {
            final match = installed
                .where(
                  (candidate) =>
                      candidate.engine == item.engine &&
                      (candidate.id == item.id ||
                          (candidate.packageUrl.isNotEmpty &&
                              candidate.packageUrl == item.packageUrl)) &&
                      candidate.installed,
                )
                .firstOrNull;
            final busy = installing.contains('${item.engine.name}:${item.id}');
            return ListTile(
              leading: const Icon(CupertinoIcons.square_stack_3d_up),
              title: Text(
                item.name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(
                '${sourceLanguage(item.lang)} · ${item.version}',
                style: const TextStyle(fontSize: 12),
              ),
              trailing: busy
                  ? const CupertinoActivityIndicator()
                  : match?.version == item.version
                  ? const Text('Đã cài', style: TextStyle(fontSize: 13))
                  : CupertinoButton(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      onPressed: () => onInstall(item),
                      child: Text(
                        match == null ? 'Cài' : 'Cập nhật',
                        style: const TextStyle(fontSize: 14),
                      ),
                    ),
            );
          },
        ),
    ];
  }
}
