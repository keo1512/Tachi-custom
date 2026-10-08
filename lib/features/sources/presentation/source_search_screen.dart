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
  List<CatalogueBook> books = [];
  String? error;
  bool busy = false, searched = false;
  int request = 0, page = 1;
  Future<void> search({bool more = false}) async {
    if (text.text.trim().isEmpty) return;
    final current = ++request;
    setState(() {
      busy = true;
      error = null;
      searched = true;
      if (!more) page = 1;
    });
    try {
      final results = await ref
          .read(sourceRepositoryProvider)
          .search(widget.source, text.text.trim(), page: page);
      if (!mounted || current != request) return;
      setState(() {
        books = more
            ? [
                ...books,
                ...results.where(
                  (b) => !books.any((old) => old.identity == b.identity),
                ),
              ]
            : results;
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

  @override
  void dispose() {
    text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(widget.source.name)),
    body: Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: TextField(
            controller: text,
            onSubmitted: (_) => search(),
            decoration: InputDecoration(
              hintText: 'Tìm truyện trong nguồn',
              prefixIcon: const Icon(CupertinoIcons.search),
              suffixIcon: IconButton(
                tooltip: 'Tìm',
                onPressed: busy ? null : search,
                icon: const Icon(CupertinoIcons.arrow_right),
              ),
            ),
          ),
        ),
        if (busy) const LinearProgressIndicator(),
        Expanded(
          child: error != null
              ? EmptyPanel(
                  icon: Icons.error_outline,
                  title: 'Nguồn trả về lỗi',
                  description: error!,
                  action: TextButton(
                    onPressed: search,
                    child: const Text('Thử lại'),
                  ),
                )
              : books.isEmpty
              ? EmptyPanel(
                  icon: CupertinoIcons.search,
                  title: searched && !busy
                      ? 'Không có kết quả'
                      : 'Tìm một câu chuyện',
                  description:
                      'Kết quả được lấy trực tiếp từ extension ${widget.source.name}.',
                )
              : ListView.builder(
                  itemCount: books.length + 1,
                  itemBuilder: (_, i) {
                    if (i == books.length) {
                      return Padding(
                        padding: const EdgeInsets.all(16),
                        child: TextButton(
                          onPressed: busy
                              ? null
                              : () {
                                  page++;
                                  search(more: true);
                                },
                          child: const Text('Tải thêm kết quả'),
                        ),
                      );
                    }
                    final b = books[i];
                    return ListTile(
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 8,
                      ),
                      leading: SizedBox(
                        width: 48,
                        height: 72,
                        child: BookCover(
                          title: b.title,
                          cover: b.coverUrl,
                          kind: b.kind.name,
                        ),
                      ),
                      title: Text(b.title),
                      subtitle: Text(
                        b.author.isEmpty ? widget.source.name : b.author,
                      ),
                      trailing: const Icon(CupertinoIcons.plus_circle),
                      onTap: () async {
                        final item = await perform(
                          context,
                          () => ref
                              .read(libraryProvider.notifier)
                              .addFromSource(b),
                        );
                        if (item != null && context.mounted) {
                          context.push('/book/${item.id}');
                        }
                      },
                    );
                  },
                ),
        ),
      ],
    ),
  );
}
