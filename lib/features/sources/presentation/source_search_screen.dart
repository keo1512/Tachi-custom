import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/widgets/book_cover.dart';
import '../../../core/widgets/feedback.dart';
import '../../library/presentation/library_view_model.dart';
import '../domain/catalogue.dart';

class SourceSearchScreen extends ConsumerStatefulWidget {
  const SourceSearchScreen({super.key, required this.source});
  final CatalogueSource source;
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
  int request = 0, page = 1;

  Future<void> search({bool more = false}) async {
    final query = more ? submittedQuery : text.text.trim();
    if (query.isEmpty || (more && (busy || !hasMore))) return;
    final current = ++request;
    final targetPage = more ? page + 1 : 1;
    setState(() {
      busy = true;
      error = null;
      searched = true;
      if (!more) {
        books = [];
        hasMore = true;
      }
    });
    try {
      final results = await ref
          .read(sourceRepositoryProvider)
          .search(widget.source, query, page: targetPage);
      if (!mounted || current != request) return;
      setState(() {
        books = more
            ? [
                ...books,
                ...results.where(
                  (book) => !books.any((old) => old.identity == book.identity),
                ),
              ]
            : results;
        submittedQuery = query;
        page = targetPage;
        hasMore = results.isNotEmpty;
        busy = false;
      });
    } catch (e) {
      if (mounted && current == request) {
        setState(() {
          error = '$e';
          busy = false;
        });
      }
    }
  }

  Future<void> open(CatalogueBook book) async {
    if (adding.contains(book.identity)) return;
    setState(() => adding.add(book.identity));
    final item = await perform(
      context,
      () => ref.read(libraryProvider.notifier).addFromSource(book),
    );
    if (!mounted) return;
    setState(() => adding.remove(book.identity));
    if (item != null) context.push('/book/${item.id}');
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
            CupertinoIcons.search,
            size: 36,
            color: CupertinoColors.secondaryLabel.resolveFrom(context),
          ),
          const SizedBox(height: 12),
          Text(
            searched && !busy ? 'Không có kết quả' : 'Tìm truyện',
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 6),
          Text(
            'Tìm trong ${widget.source.name}',
            style: TextStyle(
              fontSize: 13,
              color: CupertinoColors.secondaryLabel.resolveFrom(context),
            ),
          ),
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
        IconButton(
          tooltip: 'Tìm',
          onPressed: busy ? null : search,
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
            onSubmitted: (_) => search(),
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
        const Divider(height: 1),
        if (busy) const LinearProgressIndicator(minHeight: 2),
        if (error != null)
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
                    onPressed: busy
                        ? null
                        : () => search(more: books.isNotEmpty),
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
                    : empty()
              : LayoutBuilder(
                  builder: (context, constraints) {
                    final columns = constraints.maxWidth >= 1000
                        ? 6
                        : constraints.maxWidth >= 700
                        ? 4
                        : constraints.maxWidth >= 500
                        ? 3
                        : 2;
                    return CustomScrollView(
                      slivers: [
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
                              final book = books[index];
                              final pending = adding.contains(book.identity);
                              return Semantics(
                                label: 'Thêm ${book.title} vào thư viện',
                                button: true,
                                child: InkWell(
                                  onTap: pending ? null : () => open(book),
                                  child: Stack(
                                    fit: StackFit.expand,
                                    children: [
                                      BookCover(
                                        title: book.title,
                                        cover: book.coverUrl,
                                        kind: book.kind.name,
                                      ),
                                      Positioned(
                                        top: 5,
                                        right: 5,
                                        child: pending
                                            ? const CupertinoActivityIndicator(
                                                color: Colors.white,
                                              )
                                            : const Icon(
                                                CupertinoIcons.plus_circle_fill,
                                                size: 21,
                                                color: Colors.white,
                                              ),
                                      ),
                                    ],
                                  ),
                                ),
                              );
                            }, childCount: books.length),
                          ),
                        ),
                        SliverToBoxAdapter(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 8),
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
                                        color: CupertinoColors.secondaryLabel
                                            .resolveFrom(context),
                                      ),
                                    ),
                            ),
                          ),
                        ),
                      ],
                    );
                  },
                ),
        ),
      ],
    ),
  );
}
