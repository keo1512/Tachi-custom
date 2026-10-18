import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/widgets/book_cover.dart';
import '../../library/domain/library_book.dart';
import '../../library/presentation/library_source_label.dart';
import '../application/bulk_migration_matcher.dart';
import '../domain/source_migration.dart';
import 'source_cover_image.dart';

class BulkMigrationReview extends ConsumerWidget {
  const BulkMigrationReview({
    super.key,
    required this.books,
    required this.previews,
    required this.outcomes,
    required this.progress,
    required this.busy,
    required this.onChange,
    required this.onSkip,
  });
  final List<LibraryBook> books;
  final Map<String, SourceMigrationPreview> previews;
  final Map<String, BulkMigrationMatch> outcomes;
  final BulkMigrationProgress? progress;
  final bool busy;
  final void Function(LibraryBook) onChange, onSkip;

  @override
  Widget build(BuildContext context, WidgetRef ref) => Column(
    children: [
      Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (progress != null) ...[
              Text('Đang khớp: ${progress!.title}'),
              const SizedBox(height: 8),
              LinearProgressIndicator(
                value: progress!.total == 0
                    ? null
                    : progress!.completed / progress!.total,
              ),
              Text('${progress!.completed}/${progress!.total} truyện'),
            ] else
              Text(
                'Đã ghép ${books.where((b) => previews.containsKey(b.id)).length}/${books.length} truyện. Kiểm tra kết quả trước khi tiếp tục.',
              ),
          ],
        ),
      ),
      Expanded(
        child: ListView.builder(
          itemCount: books.length,
          itemBuilder: (context, index) {
            final book = books[index];
            final preview = previews[book.id];
            return Padding(
              key: ValueKey('migration-bulk-result-${book.id}'),
              padding: const EdgeInsets.fromLTRB(16, 8, 8, 16),
              child: Column(
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(child: _bookCard(ref, book)),
                      const Padding(
                        padding: EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 75,
                        ),
                        child: Icon(CupertinoIcons.arrow_right),
                      ),
                      Expanded(
                        child: preview == null
                            ? ConstrainedBox(
                                constraints: const BoxConstraints(
                                  minHeight: 220,
                                ),
                                child: Center(
                                  child: Text(
                                    outcomes[book.id]?.message ??
                                        (busy
                                            ? 'Đang chờ ghép…'
                                            : 'Chưa có kết quả. Tìm lại hoặc bỏ qua.'),
                                  ),
                                ),
                              )
                            : _bookCard(ref, preview.replacement),
                      ),
                      PopupMenuButton<String>(
                        tooltip: 'Sửa kết quả ${book.title}',
                        icon: const Icon(CupertinoIcons.ellipsis_vertical),
                        enabled: !busy,
                        onSelected: (v) =>
                            v == 'skip' ? onSkip(book) : onChange(book),
                        itemBuilder: (_) => const [
                          PopupMenuItem(
                            value: 'change',
                            child: Text('Tìm và chọn kết quả khác'),
                          ),
                          PopupMenuItem(
                            value: 'skip',
                            child: Text('Bỏ qua truyện này'),
                          ),
                        ],
                      ),
                    ],
                  ),
                  if (preview != null)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        'Ghép ${preview.matches.length}/${book.chapters.length} chương · ${preview.unmatchedBookmarks} dấu trang chưa ghép',
                      ),
                    ),
                  if (preview != null &&
                      outcomes[book.id]?.message.isNotEmpty == true)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        'Một số nguồn không kiểm tra được: ${outcomes[book.id]!.message}',
                      ),
                    ),
                  const Divider(),
                ],
              ),
            );
          },
        ),
      ),
    ],
  );

  Widget _bookCard(WidgetRef ref, LibraryBook book) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      AspectRatio(
        aspectRatio: .7,
        child: Stack(
          children: [
            Positioned.fill(
              child: BookCover(
                title: book.title,
                cover: book.cover,
                imageProvider: libraryCoverImage(ref, book),
                kind: book.kind,
                showTitle: false,
              ),
            ),
            Positioned(
              top: 8,
              left: 8,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: Theme.of(ref.context).colorScheme.primary,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  child: Text(
                    '${book.chapters.length}',
                    style: TextStyle(
                      color: Theme.of(ref.context).colorScheme.onPrimary,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
      const SizedBox(height: 8),
      Text(
        book.title,
        maxLines: 3,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 16),
      ),
      Text(
        resolvedLibrarySourceLabel(ref, book),
        style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 16),
      ),
      Text(
        'Mới nhất: ${_latest(book)}',
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
    ],
  );

  String _latest(LibraryBook book) {
    if (book.chapters.isEmpty) return 'Chưa có chương';
    final numbered = book.chapters
        .where((c) => c.number != null && c.number!.isFinite)
        .toList();
    if (numbered.isNotEmpty) {
      numbered.sort((a, b) => b.number!.compareTo(a.number!));
      return numbered.first.title;
    }
    final dated = book.chapters.where((c) => c.uploadedAt != null).toList()
      ..sort((a, b) => b.uploadedAt!.compareTo(a.uploadedAt!));
    return dated.isNotEmpty ? dated.first.title : book.chapters.last.title;
  }
}
