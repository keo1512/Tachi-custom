import '../../../core/format/error_messages.dart';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../library/domain/library_book.dart';
import '../../library/presentation/library_view_model.dart';
import '../domain/catalogue.dart';
import 'browse_widgets.dart';
import 'migration_source_selection.dart';

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
    final selected = await chooseMigrationSources(
      context,
      candidates: candidates.toList(),
      title: book.title,
    );
    if (selected == null || selected.isEmpty || !context.mounted) return;
    await context.push(
      '/migrate',
      extra: <String, Object>{
        'bookId': book.id,
        'source': selected.first,
        'sources': selected,
      },
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) => ref
      .watch(libraryProvider)
      .when(
        loading: () => const Center(child: CupertinoActivityIndicator()),
        error: (error, _) => Center(child: Text(userFacingError(error))),
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
                'Chọn truyện, tìm kết quả ở nguồn mới rồi xem trước dữ liệu được chuyển. Chỉ ghép chương có số hoặc tên khớp duy nhất; nội dung offline ở lại truyện cũ.',
              ),
              const BrowseHeading('Truyện trong thư viện'),
              if (online.isNotEmpty)
                ListTile(
                  leading: const Icon(CupertinoIcons.square_stack),
                  title: const Text('Chuyển nguồn hàng loạt'),
                  subtitle: const Text(
                    'Chọn và kiểm tra kết quả cho từng truyện',
                  ),
                  onTap: () => context.push('/migrate-batch', extra: sources),
                ),
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
