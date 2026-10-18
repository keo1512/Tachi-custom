import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/widgets/feedback.dart';
import '../../../core/diagnostics/diagnostic_log.dart';
import '../../library/presentation/library_view_model.dart';
import '../../library/presentation/library_locations.dart';
import '../../library/presentation/library_add_categories.dart';
import '../../settings/settings_controller.dart';
import '../domain/catalogue.dart';
import '../domain/source_filters.dart';
import 'source_filter_sheet.dart';
import 'source_catalogue_tools.dart';
import 'source_result_tile.dart';
import 'source_cover_image.dart';

class SourceSearchScreen extends ConsumerStatefulWidget {
  const SourceSearchScreen({
    super.key,
    required this.source,
    this.initialQuery = '',
  });
  final CatalogueSource source;
  final String initialQuery;
  @override
  ConsumerState<SourceSearchScreen> createState() => _SearchState();
}

class _SearchState extends ConsumerState<SourceSearchScreen> {
  final text = TextEditingController();
  final adding = <String>{};
  List<CatalogueBook> books = [];
  String? error;
  String submittedQuery = '';
  bool busy = false, searched = false, hasMore = true;
  bool retryMore = false;
  int request = 0, page = 1;
  SourceBrowseMode? mode;
  String layout = 'comfortable';
  SourceFilterSet? selectedFilters;

  Future<void> chooseFilters() async {
    final selected = await showModalBottomSheet<SourceFilterSet>(
      context: context,
      isScrollControlled: true,
      builder: (_) =>
          SourceFilterSheet(source: widget.source, selected: selectedFilters),
    );
    if (selected == null || !mounted) return;
    setState(() {
      selectedFilters = selected;
      mode = null;
    });
    await search();
  }

  @override
  void initState() {
    super.initState();
    final saved = ref
        .read(preferencesProvider)
        .getString('sourceCatalogueLayoutV1');
    if (['list', 'compact', 'comfortable'].contains(saved)) layout = saved!;
    text.text = widget.initialQuery;
    if (widget.initialQuery.isNotEmpty) {
      Future.microtask(search);
    } else if (ref
        .read(sourceRepositoryProvider)
        .supportsCatalogueBrowsing(widget.source.engine)) {
      mode = SourceBrowseMode.popular;
      Future.microtask(search);
    }
  }

  Future<void> chooseLayout() async {
    final chosen = await showCupertinoModalPopup<String>(
      context: context,
      builder: (ctx) => CupertinoActionSheet(
        title: const Text('Hiển thị truyện'),
        actions: [
          for (final item in const {
            'list': 'Danh sách',
            'compact': 'Lưới nhỏ gọn',
            'comfortable': 'Lưới lớn',
          }.entries)
            CupertinoActionSheetAction(
              onPressed: () => Navigator.pop(ctx, item.key),
              child: Text(item.value),
            ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('Hủy'),
        ),
      ),
    );
    if (chosen == null || !mounted) return;
    await perform(context, () async {
      await ref
          .read(preferencesProvider)
          .setString('sourceCatalogueLayoutV1', chosen);
      if (mounted) setState(() => layout = chosen);
    });
  }

  CatalogueBook get website => CatalogueBook(
    ref: widget.source.baseUrl,
    title: widget.source.name,
    sourceId: widget.source.id,
    kind: widget.source.kind,
    engine: widget.source.engine,
  );

  Future<void> refresh() => search(preserveResults: true);

  Future<void> retry() =>
      search(more: retryMore, preserveResults: !retryMore && books.isNotEmpty);

  Future<void> search({bool more = false, bool preserveResults = false}) async {
    final query = more ? submittedQuery : text.text.trim();
    if (!mounted ||
        (mode == null && query.isEmpty && selectedFilters == null) ||
        (more && (busy || !hasMore))) {
      return;
    }
    final current = ++request;
    final targetPage = more ? page + 1 : 1;
    setState(() {
      busy = true;
      error = null;
      searched = true;
      if (!more && !preserveResults) {
        books = [];
        hasMore = true;
      }
    });
    try {
      final repository = ref.read(sourceRepositoryProvider);
      final results = mode == null
          ? selectedFilters == null
                ? await repository.search(
                    widget.source,
                    query,
                    page: targetPage,
                  )
                : await repository.searchFiltered(
                    widget.source,
                    query,
                    selectedFilters!,
                    page: targetPage,
                  )
          : await repository.browse(
              widget.source,
              mode: mode!,
              page: targetPage,
            );
      if (!mounted || current != request) return;
      final additions = results
          .where((book) => !books.any((old) => old.identity == book.identity))
          .toList();
      setState(() {
        books = more ? [...books, ...additions] : results;
        submittedQuery = query;
        page = targetPage;
        hasMore = results is CataloguePage
            ? results.hasNextPage
            : results.isNotEmpty && (!more || additions.isNotEmpty);
        busy = false;
      });
    } catch (e) {
      if (mounted && current == request) {
        DiagnosticLogs.error('source', e);
        setState(() {
          error = userFacingError(e);
          retryMore = more;
          busy = false;
        });
      }
    }
  }

  Future<void> open(CatalogueBook book) async {
    final existing = catalogueLibraryIndex(
      ref.read(libraryProvider).value ?? const [],
    )[book.identity];
    if (existing != null) {
      context.push(libraryBookLocation(existing.id));
      return;
    }
    if (adding.contains(book.identity)) return;
    setState(() => adding.add(book.identity));
    final item = await perform(
      context,
      () => addCatalogueBookWithCategories(
        context,
        ref,
        book,
        sourceName: widget.source.name,
      ),
    );
    if (!mounted) return;
    setState(() => adding.remove(book.identity));
    if (item != null) context.push(libraryBookLocation(item.id));
  }

  @override
  void dispose() {
    text.dispose();
    super.dispose();
  }

  Widget empty() => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            error == null
                ? CupertinoIcons.search
                : CupertinoIcons.exclamationmark_circle,
            size: 36,
            color: CupertinoColors.secondaryLabel.resolveFrom(context),
          ),
          const SizedBox(height: 12),
          Text(
            error != null
                ? 'Chưa tải được truyện'
                : searched && !busy
                ? 'Không có kết quả'
                : 'Tìm truyện',
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 6),
          Text(
            error ?? 'Tìm trong ${widget.source.name}',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 13,
              color: CupertinoColors.secondaryLabel.resolveFrom(context),
            ),
          ),
          if (error != null)
            TextButton(onPressed: retry, child: const Text('Thử lại')),
        ],
      ),
    ),
  );

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(
        widget.source.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      actions: [
        if (ref
            .read(sourceRepositoryProvider)
            .supportsSourceFilters(widget.source.engine))
          IconButton(
            tooltip: 'Bộ lọc của nguồn',
            onPressed: busy ? null : chooseFilters,
            icon: Icon(
              CupertinoIcons.line_horizontal_3_decrease,
              color: selectedFilters == null
                  ? null
                  : Theme.of(context).colorScheme.primary,
            ),
          ),
        IconButton(
          tooltip: 'Hiển thị truyện',
          onPressed: chooseLayout,
          icon: const Icon(CupertinoIcons.rectangle_grid_2x2),
        ),
        if (ref.read(sourceRepositoryProvider).canOpenNativeWebsite(website))
          IconButton(
            tooltip: 'Xem trang web',
            onPressed: () => perform(context, () async {
              await ref.read(sourceRepositoryProvider).openWebsite(website);
              if (mounted && searched) await search();
            }),
            icon: const Icon(CupertinoIcons.globe, size: 22),
          ),
        IconButton(
          tooltip: 'Tìm',
          onPressed: busy
              ? null
              : () {
                  mode = null;
                  search();
                },
          icon: const Icon(CupertinoIcons.search, size: 22),
        ),
      ],
    ),
    body: Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 7, 12, 8),
          child: CupertinoSearchTextField(
            controller: text,
            placeholder: 'Tìm truyện trong nguồn',
            onSubmitted: (_) {
              mode = null;
              search();
            },
            onChanged: (value) {
              if (value.isEmpty) {
                setState(() {
                  request++;
                  books = [];
                  busy = false;
                  error = null;
                  searched = false;
                });
              }
            },
          ),
        ),
        if (ref
            .read(sourceRepositoryProvider)
            .supportsCatalogueBrowsing(widget.source.engine))
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            child: widget.source.supportsLatest == false
                ? const Align(
                    alignment: Alignment.centerLeft,
                    child: Text('Phổ biến'),
                  )
                : CupertinoSlidingSegmentedControl<String>(
                    groupValue: mode?.name,
                    children: const {
                      'popular': Text('Phổ biến'),
                      'latest': Text('Mới nhất'),
                    },
                    onValueChanged: (value) {
                      if (value == null) return;
                      setState(() {
                        mode = value == 'popular'
                            ? SourceBrowseMode.popular
                            : value == 'latest'
                            ? SourceBrowseMode.latest
                            : null;
                        request++;
                        busy = false;
                        books = [];
                      });
                      search();
                    },
                  ),
          ),
        const Divider(height: 1),
        if (busy) const LinearProgressIndicator(minHeight: 2),
        if (error != null && books.isNotEmpty)
          Material(
            color: CupertinoColors.systemGroupedBackground.resolveFrom(context),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 6, 4, 6),
              child: Row(
                children: [
                  const Icon(CupertinoIcons.exclamationmark_circle, size: 18),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      error!,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 13),
                    ),
                  ),
                  TextButton(
                    onPressed: busy ? null : retry,
                    child: const Text('Thử lại'),
                  ),
                ],
              ),
            ),
          ),
        Expanded(
          child: books.isEmpty
              ? busy
                    ? const Center(child: CupertinoActivityIndicator())
                    : RefreshIndicator(
                        onRefresh: refresh,
                        child: ListView(
                          physics: const AlwaysScrollableScrollPhysics(),
                          children: [
                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: 40),
                              child: empty(),
                            ),
                          ],
                        ),
                      )
              : LayoutBuilder(
                  builder: (context, constraints) {
                    final columns = constraints.maxWidth >= 1000
                        ? 6
                        : constraints.maxWidth >= 700
                        ? 4
                        : constraints.maxWidth >= 500
                        ? 3
                        : layout == 'compact'
                        ? 3
                        : 2;
                    final library = catalogueLibraryIndex(
                      ref.watch(libraryProvider).value ?? const [],
                    );
                    Widget result(int index, {bool list = false}) {
                      final book = books[index];
                      return SourceResultTile(
                        coverImage: sourceCoverImage(ref, book),
                        book: book,
                        inLibrary: library.containsKey(book.identity),
                        pending: adding.contains(book.identity),
                        list: list,
                        onOpen: () => open(book),
                      );
                    }

                    return RefreshIndicator(
                      onRefresh: refresh,
                      child: NotificationListener<ScrollNotification>(
                        onNotification: (notification) {
                          if (notification is ScrollUpdateNotification &&
                              notification.metrics.axis == Axis.vertical &&
                              notification.metrics.pixels > 0 &&
                              notification.metrics.pixels >
                                  notification.metrics.maxScrollExtent - 300 &&
                              !busy &&
                              hasMore) {
                            search(more: true);
                          }
                          return false;
                        },
                        child: CustomScrollView(
                          physics: const AlwaysScrollableScrollPhysics(),
                          slivers: [
                            if (layout == 'list')
                              SliverList.builder(
                                itemCount: books.length,
                                itemBuilder: (_, index) =>
                                    result(index, list: true),
                              )
                            else
                              SliverPadding(
                                padding: const EdgeInsets.all(6),
                                sliver: SliverGrid(
                                  gridDelegate:
                                      SliverGridDelegateWithFixedCrossAxisCount(
                                        crossAxisCount: columns,
                                        crossAxisSpacing: 6,
                                        mainAxisSpacing: 6,
                                        childAspectRatio: .67,
                                      ),
                                  delegate: SliverChildBuilderDelegate((
                                    context,
                                    index,
                                  ) {
                                    return result(index);
                                  }, childCount: books.length),
                                ),
                              ),
                            SliverToBoxAdapter(
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 8,
                                ),
                                child: Center(
                                  child: hasMore
                                      ? TextButton(
                                          onPressed: busy
                                              ? null
                                              : () => search(more: true),
                                          child: const Text('Tải thêm kết quả'),
                                        )
                                      : Text(
                                          'Đã tải hết kết quả',
                                          style: TextStyle(
                                            fontSize: 13,
                                            color: CupertinoColors
                                                .secondaryLabel
                                                .resolveFrom(context),
                                          ),
                                        ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    ),
  );
}
