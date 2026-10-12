import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../../core/format/error_messages.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../library/domain/library_book.dart';
import '../../library/presentation/library_view_model.dart';
import '../domain/catalogue.dart';
import '../domain/source_migration.dart';
import 'migration_source_selection.dart';

class BulkSourceMigrationScreen extends ConsumerStatefulWidget {
  const BulkSourceMigrationScreen({super.key, required this.sources});
  final List<CatalogueSource> sources;
  @override
  ConsumerState<BulkSourceMigrationScreen> createState() =>
      _BulkMigrationState();
}

class _BulkMigrationState extends ConsumerState<BulkSourceMigrationScreen> {
  final selected = <String>{};
  final previews = <String, SourceMigrationPreview>{};
  String source = '', query = '';
  String? error;
  bool busy = false;

  Future<void> choose(LibraryBook book) async {
    final candidates = widget.sources
        .where(
          (s) =>
              s.kind.name == book.kind &&
              s.identity != '${book.engine}:${book.sourceId}',
        )
        .toList();
    final targets = await chooseMigrationSources(
      context,
      candidates: candidates,
      title: book.title,
    );
    if (targets == null || targets.isEmpty || !mounted) return;
    final preview = await context.push<SourceMigrationPreview>(
      '/migrate',
      extra: <String, Object>{
        'bookId': book.id,
        'source': targets.first,
        'sources': targets,
        'selectionOnly': true,
      },
    );
    if (preview != null && mounted) {
      try {
        final shared = previews.isEmpty
            ? preview
            : preview.sharingSnapshot(previews.values.first);
        setState(() {
          selected.add(book.id);
          previews[book.id] = shared;
          error = null;
        });
      } catch (e) {
        setState(() => error = userFacingError(e));
      }
    }
  }

  Future<void> commit() async {
    final ready = [
      for (final id in selected)
        if (previews[id] != null) previews[id]!,
    ];
    if (ready.isEmpty || busy) return;
    final offline = ready.fold<int>(0, (sum, p) => sum + p.oldOfflineChapters);
    final choice = await showCupertinoModalPopup<bool>(
      context: context,
      builder: (ctx) => CupertinoActionSheet(
        title: Text('Xác nhận chuyển ${ready.length} truyện'),
        message: Text(
          'Chỉ chuyển các kết quả bạn đã xem trước. ${selected.length - ready.length} truyện chưa có kết quả sẽ được bỏ qua. $offline chương offline vẫn thuộc truyện cũ; nguồn mới cần tải lại. Dữ liệu được ghi cùng lúc và có bản phục hồi.',
        ),
        actions: [
          CupertinoActionSheetAction(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Chuyển và giữ truyện cũ'),
          ),
          CupertinoActionSheetAction(
            isDestructiveAction: true,
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Thay thế truyện cũ và xóa nội dung tải cũ'),
          ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('Hủy'),
        ),
      ),
    );
    if (choice == null || !mounted) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final completed = await SourceMigration(
        ref.read(libraryRepositoryProvider),
      ).commitBatch(ready, replaceOld: choice);
      if (!mounted) return;
      await ref.read(libraryProvider.notifier).refresh();
      if (!mounted) return;
      setState(() {
        selected.clear();
        previews.clear();
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Đã chuyển ${completed.length} truyện.')),
      );
    } catch (e) {
      if (mounted) {
        setState(() => error = 'Chưa chuyển truyện nào. ${userFacingError(e)}');
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final books = (ref.watch(libraryProvider).value ?? [])
        .where((b) => b.engine != 'local')
        .toList();
    final sourceKeys =
        books.map((b) => '${b.engine}:${b.sourceId}').toSet().toList()..sort();
    final visible = books
        .where(
          (b) =>
              (source.isEmpty || source == '${b.engine}:${b.sourceId}') &&
              b.title.toLowerCase().contains(query.toLowerCase()),
        )
        .toList();
    final ready = selected.where(previews.containsKey).length;
    return PopScope(
      canPop: !busy,
      child: Scaffold(
        appBar: AppBar(title: const Text('Chuyển nguồn hàng loạt')),
        body: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                children: [
                  DropdownButtonFormField<String>(
                    initialValue: sourceKeys.contains(source) ? source : '',
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: 'Nguồn cũ'),
                    items: [
                      const DropdownMenuItem(
                        value: '',
                        child: Text('Tất cả nguồn'),
                      ),
                      for (final key in sourceKeys)
                        DropdownMenuItem(
                          value: key,
                          child: Text(
                            widget.sources
                                    .where((s) => s.identity == key)
                                    .firstOrNull
                                    ?.name ??
                                key,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                    onChanged: busy
                        ? null
                        : (v) => setState(() => source = v ?? ''),
                  ),
                  TextField(
                    enabled: !busy,
                    onChanged: (v) => setState(() => query = v),
                    decoration: const InputDecoration(
                      labelText: 'Tìm truyện cũ',
                    ),
                  ),
                  Wrap(
                    children: [
                      TextButton(
                        onPressed: busy
                            ? null
                            : () => setState(
                                () => selected.addAll(visible.map((b) => b.id)),
                              ),
                        child: const Text('Chọn tất cả'),
                      ),
                      TextButton(
                        onPressed: busy
                            ? null
                            : () => setState(() {
                                selected.clear();
                                previews.clear();
                              }),
                        child: const Text('Bỏ chọn'),
                      ),
                    ],
                  ),
                  Text(
                    'Đã xem trước $ready/${selected.length} truyện. Chọn từng truyện để tìm, kiểm tra và sửa kết quả ghép.',
                  ),
                  if (selected.isNotEmpty)
                    LinearProgressIndicator(value: ready / selected.length),
                  if (error != null)
                    Text(
                      error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                ],
              ),
            ),
            Expanded(
              child: ListView(
                children: [
                  for (final book in visible)
                    ListTile(
                      leading: Checkbox(
                        value: selected.contains(book.id),
                        onChanged: busy
                            ? null
                            : (value) => setState(() {
                                if (value == true) {
                                  selected.add(book.id);
                                } else {
                                  selected.remove(book.id);
                                  previews.remove(book.id);
                                }
                              }),
                      ),
                      title: Text(
                        book.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        previews[book.id] == null
                            ? 'Chưa chọn kết quả'
                            : '→ ${previews[book.id]!.replacement.title}\nGhép ${previews[book.id]!.matches.length}/${book.chapters.length} chương',
                      ),
                      trailing: const Icon(CupertinoIcons.search),
                      onTap: busy ? null : () => choose(book),
                    ),
                ],
              ),
            ),
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: ready == 0 || busy ? null : commit,
                    child: busy
                        ? const CupertinoActivityIndicator()
                        : Text('Xem lại và chuyển $ready truyện'),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
