import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/widgets/feedback.dart';
import '../../library/presentation/library_view_model.dart';
import '../../library/presentation/library_locations.dart';
import '../../library/presentation/library_add_categories.dart';
import '../domain/catalogue.dart';
import 'browse_widgets.dart';
import 'global_search_controller.dart';
import 'source_catalogue_tools.dart';
import 'source_result_tile.dart';
import 'source_cover_image.dart';
import 'source_search_screen.dart';

class GlobalSearchScreen extends ConsumerStatefulWidget {
  const GlobalSearchScreen({
    super.key,
    required this.sources,
    this.initialQuery = '',
  });
  final List<CatalogueSource> sources;
  final String initialQuery;
  @override
  ConsumerState<GlobalSearchScreen> createState() => _GlobalSearchState();
}

class _GlobalSearchState extends ConsumerState<GlobalSearchScreen> {
  late final controller = GlobalSearchController(
    ref.read(sourceRepositoryProvider),
  );
  late final text = TextEditingController(text: widget.initialQuery);
  late Set<String> selected = widget.sources
      .map((source) => source.identity)
      .toSet();
  final adding = <String>{};
  @override
  void initState() {
    super.initState();
    if (widget.initialQuery.trim().isNotEmpty) Future.microtask(submit);
  }

  Future<void> submit() => controller.search(
    text.text,
    widget.sources.where((source) => selected.contains(source.identity)),
  );
  Future<void> chooseSources() async {
    final selection = {...selected};
    final accepted = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, update) => AlertDialog(
          title: const Text('Nguồn tham gia tìm kiếm'),
          content: SizedBox(
            width: 420,
            height: MediaQuery.sizeOf(ctx).height * .5,
            child: Column(
              children: [
                Wrap(
                  children: [
                    TextButton(
                      onPressed: () => update(
                        () => selection.addAll(
                          widget.sources.map((s) => s.identity),
                        ),
                      ),
                      child: const Text('Chọn tất cả'),
                    ),
                    TextButton(
                      onPressed: () => update(selection.clear),
                      child: const Text('Bỏ chọn'),
                    ),
                  ],
                ),
                Expanded(
                  child: ListView.builder(
                    itemCount: widget.sources.length,
                    itemBuilder: (_, index) {
                      final source = widget.sources[index];
                      return CheckboxListTile(
                        value: selection.contains(source.identity),
                        title: Text(source.name),
                        subtitle: Text(
                          '${sourceLanguage(source.lang)} · ${sourceEngineName(source.engine)}',
                        ),
                        onChanged: (value) => update(() {
                          if (value == true) {
                            selection.add(source.identity);
                          } else {
                            selection.remove(source.identity);
                          }
                        }),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Hủy'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Áp dụng'),
            ),
          ],
        ),
      ),
    );
    if (accepted == true && mounted) setState(() => selected = selection);
  }

  Future<void> open(CatalogueBook book) async {
    final existing = catalogueLibraryIndex(
      ref.read(libraryProvider).value ?? const [],
    )[book.identity];
    if (existing != null) {
      context.push(libraryBookLocation(existing.id));
      return;
    }
    if (!adding.add(book.identity)) return;
    setState(() {});
    final added = await perform(
      context,
      () => addCatalogueBookWithCategories(
        context,
        ref,
        book,
        sourceName:
            widget.sources
                .where(
                  (source) =>
                      source.id == book.sourceId &&
                      source.engine == book.engine,
                )
                .firstOrNull
                ?.name ??
            '',
      ),
    );
    if (!mounted) return;
    setState(() => adding.remove(book.identity));
    if (added != null) context.push(libraryBookLocation(added.id));
  }

  @override
  void dispose() {
    controller.dispose();
    text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final library = catalogueLibraryIndex(
      ref.watch(libraryProvider).value ?? const [],
    );
    return Scaffold(
      appBar: AppBar(
        title: const Text('Tìm kiếm toàn cục'),
        actions: [
          IconButton(
            tooltip: 'Chọn nguồn tìm kiếm',
            onPressed: chooseSources,
            icon: const Icon(CupertinoIcons.line_horizontal_3_decrease),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: CupertinoSearchTextField(
              controller: text,
              placeholder: 'Tên truyện trên nhiều nguồn',
              onSubmitted: (_) => submit(),
              onChanged: (value) {
                if (value.trim().isEmpty) controller.clear();
              },
            ),
          ),
          Row(
            children: [
              const SizedBox(width: 12),
              Expanded(child: Text('${selected.length} nguồn được chọn')),
              TextButton(
                onPressed: selected.isEmpty ? null : submit,
                child: const Text('Tìm'),
              ),
            ],
          ),
          Expanded(
            child: ListenableBuilder(
              listenable: controller,
              builder: (_, _) => RefreshIndicator(
                onRefresh: submit,
                child: ListView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  children: [
                    if (controller.results.isEmpty)
                      BrowseNote(
                        widget.sources.isEmpty
                            ? 'Chưa có nguồn đã cài để tìm kiếm.'
                            : selected.isEmpty
                            ? 'Chưa chọn nguồn tham gia tìm kiếm.'
                            : 'Nhập tên truyện và chọn nguồn để tìm kiếm.',
                      ),
                    if (controller.results.isEmpty && widget.sources.isNotEmpty)
                      Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton(
                          onPressed: chooseSources,
                          child: const Text('Chọn nguồn tìm kiếm'),
                        ),
                      ),
                    for (final result in controller.results) ...[
                      ListTile(
                        title: Text(result.source.name),
                        subtitle: Text(sourceLanguage(result.source.lang)),
                        trailing: result.phase == SourceSearchPhase.loading
                            ? const CupertinoActivityIndicator()
                            : result.phase == SourceSearchPhase.queued
                            ? const Text('Đang chờ')
                            : TextButton(
                                onPressed: () => Navigator.of(context).push(
                                  CupertinoPageRoute(
                                    builder: (_) => SourceSearchScreen(
                                      source: result.source,
                                      initialQuery: controller.query,
                                    ),
                                  ),
                                ),
                                child: const Text('Xem thêm'),
                              ),
                      ),
                      if (result.error != null)
                        BrowseNote(
                          result.error!,
                          onRetry: () =>
                              controller.retry(result.source.identity),
                        ),
                      if (result.phase == SourceSearchPhase.complete &&
                          result.books.isEmpty)
                        const BrowseNote('Không có kết quả ở nguồn này.'),
                      if (result.books.isNotEmpty)
                        SizedBox(
                          height: 180,
                          child: ListView.separated(
                            scrollDirection: Axis.horizontal,
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                            itemCount: result.books.length.clamp(0, 6),
                            separatorBuilder: (_, _) =>
                                const SizedBox(width: 6),
                            itemBuilder: (_, index) {
                              final book = result.books[index];
                              return SizedBox(
                                width: 116,
                                child: SourceResultTile(
                                  coverImage: sourceCoverImage(ref, book),
                                  book: book,
                                  inLibrary: library.containsKey(book.identity),
                                  pending: adding.contains(book.identity),
                                  onOpen: () => open(book),
                                ),
                              );
                            },
                          ),
                        ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
