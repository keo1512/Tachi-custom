import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/widgets/feedback.dart';
import '../../library/presentation/library_source_label.dart';
import '../../library/presentation/library_view_model.dart';
import '../domain/catalogue.dart';
import 'browse_widgets.dart';
import 'source_migration_view.dart';

/// Entry point shared by More and Browse; loading installed sources does not
/// migrate or rewrite any restored book identity.
class SourceMigrationLibraryScreen extends ConsumerStatefulWidget {
  const SourceMigrationLibraryScreen({super.key});

  @override
  ConsumerState<SourceMigrationLibraryScreen> createState() =>
      _MigrationLibraryState();
}

class _MigrationLibraryState
    extends ConsumerState<SourceMigrationLibraryScreen> {
  final sources = <SourceEngine, List<CatalogueSource>>{};
  final errors = <SourceEngine, String>{};
  bool busy = true;
  int generation = 0;
  String query = '';

  @override
  void initState() {
    super.initState();
    Future.microtask(load);
  }

  Future<void> load() async {
    final current = ++generation;
    setState(() {
      busy = true;
      errors.clear();
    });
    final repository = ref.read(sourceRepositoryProvider);
    await Future.wait(
      SourceEngine.values.map((engine) async {
        try {
          final values = await repository.listSources(engine);
          if (mounted && generation == current) {
            setState(() => sources[engine] = values);
          }
        } catch (error) {
          if (mounted && generation == current) {
            setState(() => errors[engine] = userFacingError(error));
          }
        }
      }),
    );
    if (mounted && generation == current) setState(() => busy = false);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Chuyển nguồn'),
      actions: [
        IconButton(
          tooltip: 'Làm mới nguồn đã cài',
          onPressed: busy ? null : load,
          icon: const Icon(CupertinoIcons.refresh),
        ),
      ],
    ),
    body: Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: CupertinoSearchTextField(
            placeholder: 'Tìm nguồn cũ hoặc tên truyện',
            onChanged: (value) =>
                setState(() => query = value.trim().toLowerCase()),
          ),
        ),
        if (busy) const LinearProgressIndicator(minHeight: 2),
        for (final error in errors.entries)
          BrowseNote(
            '${sourceEngineName(error.key)}: ${error.value}',
            onRetry: busy ? null : load,
          ),
        Expanded(
          child: ref
              .watch(libraryProvider)
              .when(
                loading: () =>
                    const Center(child: CupertinoActivityIndicator()),
                error: (error, _) => BrowseNote(
                  userFacingError(error),
                  onRetry: () => ref.read(libraryProvider.notifier).refresh(),
                ),
                data: (books) {
                  final online = books
                      .where((book) => book.engine != 'local')
                      .toList();
                  final known = {
                    for (final source in sources.values.expand(
                      (items) => items,
                    ))
                      source.identity: source,
                  };
                  final identities = online
                      .map((book) => '${book.engine}:${book.sourceId}')
                      .toSet()
                      .toList();
                  String label(String identity) =>
                      known[identity]?.name ??
                      librarySourceLabel(
                        online.firstWhere(
                          (book) =>
                              '${book.engine}:${book.sourceId}' == identity,
                        ),
                      );
                  identities.sort((a, b) => label(a).compareTo(label(b)));
                  return RefreshIndicator(
                    onRefresh: () async {
                      await load();
                      await ref.read(libraryProvider.notifier).refresh();
                    },
                    child: ListView(
                      physics: const AlwaysScrollableScrollPhysics(),
                      children: [
                        const BrowseHeading('Chọn nguồn cũ'),
                        if (online.isEmpty)
                          const BrowseNote(
                            'Chưa có truyện online trong thư viện để chuyển nguồn.',
                          ),
                        for (final identity in identities)
                          if (label(identity).toLowerCase().contains(query) ||
                              online.any(
                                (book) =>
                                    '${book.engine}:${book.sourceId}' ==
                                        identity &&
                                    book.title.toLowerCase().contains(query),
                              ))
                            ListTile(
                              key: ValueKey('migration-origin-$identity'),
                              leading: const Icon(
                                CupertinoIcons.square_stack_3d_up,
                              ),
                              title: Text(
                                label(identity),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                              subtitle: Text(
                                '${online.where((book) => '${book.engine}:${book.sourceId}' == identity).length} truyện',
                              ),
                              trailing: const Icon(
                                CupertinoIcons.chevron_right,
                                size: 16,
                              ),
                              onTap: () => Navigator.of(context).push(
                                CupertinoPageRoute(
                                  builder: (_) => Scaffold(
                                    appBar: AppBar(
                                      title: Text(label(identity)),
                                    ),
                                    body: SourceMigrationView(
                                      sources: sources.values
                                          .expand((items) => items)
                                          .toList(),
                                      onOpenSource: (_) async {},
                                      query: '',
                                      originIdentity: identity,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                        if (online.isNotEmpty &&
                            identities.every(
                              (identity) =>
                                  !label(identity)
                                      .toLowerCase()
                                      .contains(query) &&
                                  !online.any(
                                    (book) =>
                                        '${book.engine}:${book.sourceId}' ==
                                            identity &&
                                        book.title.toLowerCase().contains(
                                          query,
                                        ),
                                  ),
                            ))
                          const BrowseNote(
                            'Không có nguồn hoặc truyện phù hợp với từ khóa.',
                          ),
                      ],
                    ),
                  );
                },
              ),
        ),
      ],
    ),
  );
}
