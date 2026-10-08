import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/widgets/feedback.dart';
import '../../library/domain/library_book.dart';
import '../../library/presentation/library_view_model.dart';
import '../domain/catalogue.dart';
import 'browse_widgets.dart';

class SourceMigrationView extends ConsumerWidget {
  const SourceMigrationView({
    super.key,
    required this.sources,
    required this.onOpenSource,
    required this.query,
  });
  final List<CatalogueSource> sources;
  final Future<void> Function(CatalogueSource) onOpenSource;
  final String query;

  Future<void> chooseSource(BuildContext context, LibraryBook book) async {
    final candidates = sources.where(
      (source) =>
          (source.kind == ContentKind.manga) == (book.kind == 'manga') &&
          source.identity != '${book.engine}:${book.sourceId}',
    );
    final selected = await showCupertinoModalPopup<CatalogueSource>(
      context: context,
      builder: (ctx) => CupertinoActionSheet(
        title: Text(book.title),
        message: Text(
          candidates.isEmpty
              ? 'Chưa có nguồn khác phù hợp. Cài thêm extension trong Phần mở rộng.'
              : 'Chọn nguồn khác để tìm lại truyện. Tên truyện sẽ được sao chép để dán vào ô tìm kiếm. Sách cũ được giữ nguyên.',
        ),
        actions: [
          for (final source in candidates)
            CupertinoActionSheetAction(
              onPressed: () => Navigator.pop(ctx, source),
              child: Text(
                '${source.name} · ${sourceEngineName(source.engine)}',
              ),
            ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('Hủy'),
        ),
      ),
    );
    if (selected == null || !context.mounted) return;
    await perform(context, () async {
      await Clipboard.setData(ClipboardData(text: book.title));
      if (context.mounted) await onOpenSource(selected);
    });
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) => ref
      .watch(libraryProvider)
      .when(
        loading: () => const Center(child: CupertinoActivityIndicator()),
        error: (error, _) => Center(child: Text('$error')),
        data: (books) {
          final online = books.where(
            (book) =>
                book.engine != 'local' &&
                book.title.toLowerCase().contains(query.toLowerCase()),
          );
          return ListView(
            padding: EdgeInsets.only(
              bottom: MediaQuery.paddingOf(context).bottom + 16,
            ),
            children: [
              const BrowseNote(
                'Chuyển nguồn tự động chưa được hỗ trợ. Chọn truyện đang dùng nguồn online để tìm lại ở nguồn khác. Thao tác này không chuyển cache, tiến độ hoặc dấu trang sang sách mới.',
              ),
              const BrowseHeading('Truyện trong thư viện'),
              if (online.isEmpty)
                const BrowseNote(
                  'Không có truyện online phù hợp trong thư viện.',
                ),
              for (final book in online)
                ListTile(
                  leading: const Icon(CupertinoIcons.book),
                  title: Text(
                    book.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text('${book.engine} · ${book.sourceId}'),
                  trailing: const Icon(CupertinoIcons.chevron_right, size: 16),
                  onTap: () => showCupertinoModalPopup<void>(
                    context: context,
                    builder: (ctx) => CupertinoActionSheet(
                      title: Text(book.title),
                      actions: [
                        CupertinoActionSheetAction(
                          onPressed: () {
                            Navigator.pop(ctx);
                            chooseSource(context, book);
                          },
                          child: const Text('Tìm ở nguồn khác'),
                        ),
                        CupertinoActionSheetAction(
                          onPressed: () {
                            Navigator.pop(ctx);
                            context.push('/book/${book.id}');
                          },
                          child: const Text('Mở sách hiện tại'),
                        ),
                      ],
                      cancelButton: CupertinoActionSheetAction(
                        onPressed: () => Navigator.pop(ctx),
                        child: const Text('Hủy'),
                      ),
                    ),
                  ),
                ),
            ],
          );
        },
      );
}
