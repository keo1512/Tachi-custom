import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/widgets/feedback.dart';
import '../data/extension_index.dart';
import '../domain/catalogue.dart';
import '../domain/source_languages.dart';
import 'browse_widgets.dart';
import 'extension_catalogue_controller.dart';
import 'source_catalogue_tools.dart';

class ExtensionCatalogueView extends ConsumerWidget {
  const ExtensionCatalogueView({
    super.key,
    required this.installed,
    required this.installing,
    required this.onInstall,
    required this.onAdd,
    this.onManage,
    this.query = '',
    this.language,
    this.languages = const SourceLanguages(null),
    this.onRefresh,
    this.adding = false,
    this.engineErrors = const [],
    this.queued = const {},
    this.installErrors = const {},
    this.updatingAll = false,
    this.onUpdateAll,
    this.onUninstall,
    this.canUninstall,
    this.onPackageInfo,
    this.onImportApk,
    this.importing = false,
  });
  final List<CatalogueExtension> installed;
  final Set<String> installing;
  final void Function(CatalogueExtension) onInstall;
  final VoidCallback onAdd;
  final VoidCallback? onManage;
  final String query;
  final String? language;
  final SourceLanguages languages;
  final Future<void> Function()? onRefresh;
  final bool adding;
  final List<String> engineErrors;
  final Set<String> queued;
  final Map<String, String> installErrors;
  final bool updatingAll;
  final VoidCallback? onUpdateAll;
  final void Function(CatalogueExtension)? onUninstall;
  final bool Function(CatalogueExtension)? canUninstall;
  final void Function(CatalogueExtension)? onPackageInfo;
  final VoidCallback? onImportApk;
  final bool importing;

  bool _visible(CatalogueExtension item) =>
      item.name.toLowerCase().contains(query.toLowerCase()) &&
      languages.allows(item.lang) &&
      (language == null || item.lang == language);

  bool _sameExtension(CatalogueExtension a, CatalogueExtension b) =>
      a.engine == b.engine &&
      (a.id == b.id ||
          (a.packageUrl.isNotEmpty && a.packageUrl == b.packageUrl));

  String _installedIcon(CatalogueExtension item, List<ExtensionIndex> indexes) {
    if (item.iconUrl.isNotEmpty) return item.iconUrl;
    for (final index in indexes) {
      for (final candidate in index.entries) {
        if (_sameExtension(item, candidate) && candidate.iconUrl.isNotEmpty) {
          return candidate.iconUrl;
        }
      }
    }
    return '';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final indexes = ref.watch(extensionCatalogueProvider);
    final updates = availableExtensionUpdates(
      indexes.value?.expand((index) => index.entries) ?? const [],
      installed,
    );
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
          if (onUpdateAll != null && (updates.isNotEmpty || updatingAll))
            ListTile(
              leading: updatingAll
                  ? const CupertinoActivityIndicator()
                  : const Icon(CupertinoIcons.arrow_2_circlepath),
              title: Text(
                updatingAll
                    ? 'Đang cập nhật extension'
                    : 'Cập nhật tất cả (${updates.length})',
              ),
              subtitle: updatingAll
                  ? Text(
                      '${installing.length} đang cài · ${queued.length} đang chờ',
                    )
                  : null,
              onTap: importing || updatingAll || installing.isNotEmpty
                  ? null
                  : onUpdateAll,
            ),
          if (onManage != null)
            ListTile(
              leading: const Icon(CupertinoIcons.list_bullet),
              title: const Text('Kho tiện ích mở rộng'),
              trailing: const Icon(CupertinoIcons.chevron_right, size: 16),
              onTap: onManage,
            ),
          ListTile(
            leading: const Icon(CupertinoIcons.plus),
            title: const Text('Thêm kho extension bằng link'),
            trailing: adding ? const CupertinoActivityIndicator() : null,
            onTap: adding ? null : onAdd,
          ),
          if (onImportApk != null)
            ListTile(
              leading: const Icon(CupertinoIcons.doc),
              title: const Text('Nhập extension APK từ Files'),
              trailing: importing ? const CupertinoActivityIndicator() : null,
              onTap: importing || updatingAll || installing.isNotEmpty
                  ? null
                  : onImportApk,
            ),
          for (final error in engineErrors) BrowseNote(error),
          ...indexes.when(
            loading: () => const <Widget>[LinearProgressIndicator()],
            error: (error, _) => <Widget>[BrowseNote(userFacingError(error))],
            data: (values) => <Widget>[
              if (values.isEmpty)
                const BrowseNote(
                  'Nhập link kho để xem danh sách, sau đó chọn extension cần cài.',
                ),
              for (final index in values) ..._index(context, ref, index),
            ],
          ),
          if (installed.any(
            (item) =>
                (item.installed || item.loadError.isNotEmpty) && _visible(item),
          )) ...[
            const BrowseHeading('Gói trên thiết bị'),
            for (final item in installed.where(
              (item) =>
                  (item.installed || item.loadError.isNotEmpty) &&
                  _visible(item),
            ))
              ListTile(
                onLongPress: onPackageInfo == null
                    ? null
                    : () => onPackageInfo!(item),
                leading: _ExtensionIcon(
                  iconUrl: _installedIcon(item, indexes.value ?? const []),
                ),
                title: Text(item.name),
                subtitle: Text(
                  '${sourceEngineName(item.engine)} · ${item.version}${item.loadError.isEmpty ? '' : '\nChưa nạp được nguồn: ${item.loadError}'}',
                ),
                trailing:
                    canUninstall?.call(item) == true && onUninstall != null
                    ? IconButton(
                        tooltip: 'Gỡ ${item.name}',
                        icon: const Icon(CupertinoIcons.trash),
                        onPressed:
                            importing || installing.isNotEmpty || updatingAll
                            ? null
                            : () => onUninstall!(item),
                      )
                    : Text(item.installed ? 'Đã cài' : 'Lỗi nạp'),
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
        title: Text(index.displayName),
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
                      _sameExtension(candidate, item) && candidate.installed,
                )
                .firstOrNull;
            final busy = installing.contains('${item.engine.name}:${item.id}');
            final waiting = queued.contains('${item.engine.name}:${item.id}');
            final failure = installErrors['${item.engine.name}:${item.id}'];
            final versionOrder = match == null
                ? null
                : compareExtensionVersions(match.version, item.version);
            final currentOrNewer =
                match != null &&
                (match.version == item.version ||
                    (versionOrder != null && versionOrder >= 0));
            return ListTile(
              onLongPress: onPackageInfo == null
                  ? null
                  : () => onPackageInfo!(item),
              leading: _ExtensionIcon(iconUrl: item.iconUrl),
              title: Text(
                item.name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(
                '${sourceLanguage(item.lang)} · ${item.version}${failure == null ? '' : '\n$failure'}',
                style: const TextStyle(fontSize: 12),
              ),
              trailing: busy
                  ? const CupertinoActivityIndicator()
                  : waiting
                  ? const Text('Đang chờ', style: TextStyle(fontSize: 13))
                  : currentOrNewer
                  ? Text(
                      versionOrder != null && versionOrder > 0
                          ? 'Đã cài bản mới hơn'
                          : 'Đã cài',
                      style: const TextStyle(fontSize: 13),
                    )
                  : CupertinoButton(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      onPressed: importing || updatingAll
                          ? null
                          : () => onInstall(item),
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

class _ExtensionIcon extends StatelessWidget {
  const _ExtensionIcon({required this.iconUrl});
  final String iconUrl;

  @override
  Widget build(BuildContext context) {
    final gray = Theme.of(context).brightness == Brightness.dark
        ? const Color(0xFFBFC1CB)
        : const Color(0xFF46464E);
    Widget placeholder() => Icon(
      CupertinoIcons.square_stack_3d_up,
      key: const ValueKey('extension-icon-placeholder'),
      color: gray,
      size: 22,
    );
    return Container(
      width: 38,
      height: 38,
      decoration: BoxDecoration(
        color: gray.withValues(alpha: .12),
        borderRadius: BorderRadius.circular(4),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: iconUrl.isEmpty
            ? placeholder()
            : Image.network(
                iconUrl,
                width: 38,
                height: 38,
                fit: BoxFit.contain,
                cacheWidth: 114,
                cacheHeight: 114,
                excludeFromSemantics: true,
                errorBuilder: (_, _, _) => placeholder(),
                loadingBuilder: (_, child, progress) =>
                    progress == null ? child : placeholder(),
              ),
      ),
    );
  }
}
