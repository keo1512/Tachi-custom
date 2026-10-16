import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/widgets/book_cover.dart';
import '../../../core/widgets/feedback.dart';
import '../../library/presentation/library_view_model.dart';
import '../../library/presentation/library_locations.dart';
import '../../library/presentation/local_comic_library_screen.dart';
import 'browse_widgets.dart';
import 'source_cover_image.dart';

/// The local source uses the same library identities and chapter storage as
/// imported books; opening it never launches a second import automatically.
class LocalSourceScreen extends ConsumerStatefulWidget {
  const LocalSourceScreen({super.key});

  @override
  ConsumerState<LocalSourceScreen> createState() => _LocalSourceState();
}

class _LocalSourceState extends ConsumerState<LocalSourceScreen> {
  bool importing = false;

  Future<void> import() async {
    if (importing) return;
    setState(() => importing = true);
    try {
      final count = await perform(
        context,
        () => ref.read(libraryProvider.notifier).importFiles(),
      );
      if (mounted && count != null && count > 0) {
        message(context, 'Đã nhập $count truyện vào thiết bị.');
      }
    } finally {
      if (mounted) setState(() => importing = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Truyện trong thiết bị'),
      actions: [
        IconButton(
          tooltip: 'Làm mới truyện cục bộ',
          onPressed: importing
              ? null
              : () => perform(
                  context,
                  () => ref.read(libraryProvider.notifier).refresh(),
                ),
          icon: const Icon(CupertinoIcons.refresh),
        ),
        IconButton(
          tooltip: 'Quản lý thư mục truyện',
          onPressed: importing
              ? null
              : () => Navigator.of(context).push(
                  CupertinoPageRoute(
                    builder: (_) => const LocalComicLibraryScreen(),
                  ),
                ),
          icon: const Icon(CupertinoIcons.folder),
        ),
      ],
    ),
    body: ref
        .watch(libraryProvider)
        .when(
          loading: () => const Center(child: CupertinoActivityIndicator()),
          error: (error, _) => BrowseNote(
            userFacingError(error),
            onRetry: () => ref.read(libraryProvider.notifier).refresh(),
          ),
          data: (all) {
            final books = all.where((book) => book.engine == 'local').toList();
            return RefreshIndicator(
              onRefresh: () => ref.read(libraryProvider.notifier).refresh(),
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                children: [
                  ListTile(
                    leading: importing
                        ? const CupertinoActivityIndicator()
                        : const Icon(CupertinoIcons.doc),
                    title: Text(
                      importing ? 'Đang nhập truyện…' : 'Nhập truyện từ Files',
                    ),
                    subtitle: const Text('EPUB · TXT · CBZ · ZIP · RAR · CBR'),
                    onTap: importing ? null : import,
                  ),
                  if (books.isEmpty)
                    const BrowseNote(
                      'Chưa có truyện cục bộ. Nhập tệp từ Files hoặc chọn thư mục truyện để đọc trên thiết bị.',
                    ),
                  for (final book in books)
                    ListTile(
                      key: ValueKey('local-source-${book.id}'),
                      leading: SizedBox(
                        width: 42,
                        height: 60,
                        child: BookCover(
                          title: book.title,
                          cover: book.cover,
                          kind: book.kind,
                          imageProvider: libraryCoverImage(ref, book),
                        ),
                      ),
                      title: Text(
                        book.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text('${book.chapters.length} chương'),
                      trailing: const Icon(
                        CupertinoIcons.chevron_right,
                        size: 16,
                      ),
                      onTap: () => context.push(libraryBookLocation(book.id)),
                    ),
                ],
              ),
            );
          },
        ),
  );
}
