import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/format/error_messages.dart';
import '../../../core/widgets/book_cover.dart';
import '../../library/presentation/library_view_model.dart';
import '../../library/data/library_mutation.dart';
import '../../library/presentation/library_source_label.dart';
import '../../library/presentation/library_locations.dart';
import '../domain/catalogue.dart';
import '../domain/source_migration.dart';
import '../application/migration_search.dart';
import '../application/source_migration_service.dart';
import 'migration_source_selection.dart';
import 'source_cover_image.dart';

class SourceMigrationScreen extends ConsumerStatefulWidget {
  const SourceMigrationScreen({
    super.key,
    required this.bookId,
    required this.source,
    this.alternatives = const [],
    this.selectionOnly = false,
  });
  final String bookId;
  final CatalogueSource source;
  final List<CatalogueSource> alternatives;
  final bool selectionOnly;
  @override
  ConsumerState<SourceMigrationScreen> createState() => _SourceMigrationState();
}

class _SourceMigrationState extends ConsumerState<SourceMigrationScreen> {
  final query = TextEditingController();
  List<CatalogueBook> results = [];
  String? error;
  bool busy = false, hasMore = false, committing = false;
  int generation = 0, page = 0;
  String submittedQuery = '';
  Set<String> moreSourceIdentities = {};
  late final MigrationSearch searches = MigrationSearch(
    ref.read(sourceRepositoryProvider),
  );
  late List<CatalogueSource> selectedSources = allSources;
  MigrationSearchProgress? progress;
  List<CatalogueSource> get allSources => {
    widget.source.identity: widget.source,
    for (final source in widget.alternatives) source.identity: source,
  }.values.toList();

  void cancel() {
    if (committing) return;
    searches.cancel();
    generation++;
    setState(() => busy = false);
  }

  Future<void> selectSources() async {
    final selected = await selectMigrationSources(
      context,
      candidates: allSources,
      selected: selectedSources.map((source) => source.identity).toSet(),
    );
    if (selected == null || !mounted) return;
    setState(() => selectedSources = selected);
    await search();
  }

  @override
  void initState() {
    super.initState();
    Future.microtask(() async {
      final book = await ref
          .read(libraryRepositoryProvider)
          .find(widget.bookId);
      if (!mounted) return;
      query.text = book?.title ?? '';
      if (query.text.isNotEmpty) await search();
    });
  }

  @override
  void dispose() {
    generation++;
    searches.cancel();
    query.dispose();
    super.dispose();
  }

  Future<void> search({bool more = false}) async {
    final text = more ? submittedQuery : query.text.trim();
    if (busy || text.isEmpty) return;
    final participants = more
        ? selectedSources
              .where((source) => moreSourceIdentities.contains(source.identity))
              .toList()
        : selectedSources;
    if (participants.isEmpty) return;
    final request = ++generation, nextPage = more ? page + 1 : 1;
    setState(() {
      busy = true;
      error = null;
      progress = null;
    });
    try {
      final outcome = await searches.search(
        participants,
        text,
        page: nextPage,
        onProgress: (value) {
          if (mounted && generation == request) {
            setState(() => progress = value);
          }
        },
      );
      if (outcome == null) return;
      final incoming = outcome.results
          .expand((result) => result.books)
          .toList();
      if (!mounted || generation != request) return;
      setState(() {
        results = more
            ? [
                ...results,
                ...incoming.where(
                  (b) => !results.any((old) => b.identity == old.identity),
                ),
              ]
            : incoming;
        page = nextPage;
        moreSourceIdentities = {
          for (final result in outcome.results)
            if (result.error.isEmpty &&
                (result.hasNextPage ?? result.books.isNotEmpty))
              result.source.identity,
        };
        hasMore = moreSourceIdentities.isNotEmpty;
        submittedQuery = text;
      });
    } catch (e) {
      if (mounted && generation == request) {
        setState(() => error = userFacingError(e));
      }
    } finally {
      if (mounted && generation == request) setState(() => busy = false);
    }
  }

  Future<void> choose(CatalogueBook item) async {
    if (busy) return;
    final request = ++generation;
    final repository = ref.read(libraryRepositoryProvider);
    final revision = repository.replacementRevision;
    setState(() {
      busy = true;
      error = null;
      progress = null;
    });
    try {
      final sources = ref.read(sourceRepositoryProvider);
      final detail = await sources.detail(item);
      if (!mounted || request != generation) return;
      if (detail.engine != item.engine ||
          detail.sourceId != item.sourceId ||
          detail.ref != item.ref) {
        throw const FormatException(
          'Nguồn trả về truyện có danh tính khác với kết quả đã chọn.',
        );
      }
      final chapters = await sources.chapters(item);
      if (!mounted || request != generation) return;
      final service = ref.read(sourceMigrationProvider);
      checkLibraryRevision(repository.replacementRevision, revision);
      final preview = await service.preview(
        widget.bookId,
        detail,
        chapters,
        sourceName:
            selectedSources
                .where(
                  (source) =>
                      source.id == item.sourceId &&
                      source.engine == item.engine,
                )
                .firstOrNull
                ?.name ??
            '',
      );
      checkLibraryRevision(repository.replacementRevision, revision);
      if (!mounted || request != generation) return;
      setState(() => busy = false);
      if (widget.selectionOnly) {
        final accepted = await showModalBottomSheet<bool>(
          context: context,
          isScrollControlled: true,
          useSafeArea: true,
          builder: (_) =>
              _MigrationPreview(preview: preview, selectionOnly: true),
        );
        checkLibraryRevision(repository.replacementRevision, revision);
        if (accepted == true && mounted && request == generation) {
          context.pop(preview);
        }
        return;
      }
      final replace = await showModalBottomSheet<bool>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        builder: (_) => _MigrationPreview(preview: preview),
      );
      if (replace == null || !mounted || request != generation) return;
      checkLibraryRevision(repository.replacementRevision, revision);
      setState(() {
        busy = true;
        committing = true;
      });
      final saved = await service.commit(
        preview,
        replaceOld: replace,
        expectedRevision: revision,
      );
      if (!mounted || request != generation) return;
      await ref.read(libraryProvider.notifier).refresh();
      if (mounted) context.replace(libraryBookLocation(saved.id));
    } catch (e) {
      if (e is SourceMigrationRecoveryRequired && mounted) {
        await ref.read(libraryProvider.notifier).refresh();
      }
      if (mounted && request == generation) {
        setState(() => error = userFacingError(e));
      }
    } finally {
      if (mounted && request == generation) {
        setState(() {
          busy = false;
          committing = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !committing,
    child: Scaffold(
      appBar: AppBar(title: const Text('Chuyển nguồn truyện')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: TextField(
              controller: query,
              enabled: !busy,
              onSubmitted: (_) => search(),
              decoration: InputDecoration(
                labelText: selectedSources.length == 1
                    ? 'Tìm ở ${selectedSources.single.name}'
                    : 'Tìm ở ${selectedSources.length} nguồn',
                suffixIcon: IconButton(
                  onPressed: busy ? null : search,
                  icon: const Icon(CupertinoIcons.search),
                ),
              ),
            ),
          ),
          if (allSources.length > 1)
            TextButton(
              onPressed: busy ? null : selectSources,
              child: Text('Chọn nguồn (${selectedSources.length})'),
            ),
          if (busy) ...[
            LinearProgressIndicator(value: progress?.fraction),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Flexible(
                  child: Text(
                    progress == null
                        ? 'Đang tải thông tin truyện'
                        : 'Đã tìm ${progress!.completed}/${progress!.total} nguồn',
                  ),
                ),
                TextButton(
                  onPressed: committing ? null : cancel,
                  child: Text(committing ? 'Đang lưu dữ liệu' : 'Hủy tìm kiếm'),
                ),
              ],
            ),
          ],
          if (error != null)
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          Expanded(
            child: ListView(
              children: [
                for (final failed
                    in progress?.results.where(
                          (result) => result.error.isNotEmpty,
                        ) ??
                        <MigrationSourceResult>[])
                  ListTile(
                    title: Text(failed.source.name),
                    subtitle: Text(userFacingError(failed.error)),
                    leading: Icon(
                      Icons.error_outline,
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                if (results.isEmpty && !busy)
                  const Padding(
                    padding: EdgeInsets.all(24),
                    child: Text(
                      'Chưa có kết quả. Thử tên khác hoặc quay lại chọn nguồn khác.',
                    ),
                  ),
                for (final item in results)
                  ListTile(
                    leading: SizedBox(
                      width: 46,
                      height: 64,
                      child: BookCover(
                        title: item.title,
                        showTitle: false,
                        cover: item.coverUrl,
                        imageProvider: sourceCoverImage(ref, item),
                        kind: item.kind.name,
                      ),
                    ),
                    title: Text(
                      item.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      '${sourceDisplayLabel(engine: item.engine.name, sourceName: selectedSources.where((source) => source.id == item.sourceId && source.engine == item.engine).firstOrNull?.name ?? '', sourceRef: item.ref)}${item.author.isEmpty ? '' : ' · ${item.author}'}',
                    ),
                    onTap: busy ? null : () => choose(item),
                  ),
                if (hasMore)
                  TextButton(
                    onPressed: busy ? null : () => search(more: true),
                    child: const Text('Tải thêm'),
                  ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}

class _MigrationPreview extends ConsumerStatefulWidget {
  const _MigrationPreview({required this.preview, this.selectionOnly = false});
  final SourceMigrationPreview preview;
  final bool selectionOnly;
  @override
  ConsumerState<_MigrationPreview> createState() => _MigrationPreviewState();
}

class _MigrationPreviewState extends ConsumerState<_MigrationPreview> {
  bool replace = false;
  @override
  Widget build(BuildContext context) {
    final value = widget.preview;
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Xem trước chuyển nguồn',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 12),
            for (final entry in [
              ('Truyện gốc', value.original),
              ('Truyện ở nguồn mới', value.replacement),
            ])
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Row(
                  key: ValueKey('migration-preview-${entry.$2.id}'),
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 48,
                      height: 68,
                      child: BookCover(
                        title: entry.$2.title,
                        cover: entry.$2.cover,
                        imageProvider: libraryCoverImage(ref, entry.$2),
                        kind: entry.$2.kind,
                        showTitle: false,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            entry.$1,
                            style: Theme.of(context).textTheme.labelMedium,
                          ),
                          Text(
                            entry.$2.title,
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                          Text(resolvedLibrarySourceLabel(ref, entry.$2)),
                          Text('${entry.$2.chapters.length} chương'),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            Text(
              '${value.replacement.chapters.length} chương ở nguồn mới; ghép được ${value.matches.length}/${value.original.chapters.length} chương cũ.',
            ),
            Text(
              'Giữ ${value.mappedReadChapters} chương đã đọc, ${value.replacement.bookmarks.length} dấu chương. ${value.unmatchedBookmarks} dấu trang không ghép được.',
            ),
            const SizedBox(height: 12),
            const Text(
              'Danh mục, yêu thích, ghi chú, thiết lập đọc và lần đọc gần nhất được giữ. Vị trí đọc và dấu trang ở nguồn mới bắt đầu từ đầu chương vì số trang giữa hai nguồn có thể khác nhau.',
            ),
            const Text(
              'Thư mục được giữ cho truyện ở nguồn mới. Khi thay thế, thời lượng đọc chuyển sang truyện mới; khi giữ cả hai, thời lượng đã ghi vẫn thuộc truyện cũ để không cộng hai lần.',
            ),
            Text(
              '${value.oldOfflineChapters} chương offline vẫn thuộc truyện cũ. Cần tải lại từ nguồn mới để đọc offline.',
            ),
            if (!widget.selectionOnly)
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: replace,
                onChanged: (v) => setState(() => replace = v ?? false),
                title: const Text('Thay thế truyện cũ'),
                subtitle: const Text(
                  'Xóa truyện cũ và nội dung offline của nó khỏi thư viện. Bản phục hồi được lưu trước khi thay đổi. Mặc định giữ cả hai truyện.',
                ),
              ),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: () =>
                  Navigator.pop(context, widget.selectionOnly || replace),
              child: Text(
                widget.selectionOnly
                    ? 'Dùng kết quả này'
                    : replace
                    ? 'Xác nhận thay thế'
                    : 'Chuyển và giữ truyện cũ',
              ),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Tìm lại kết quả'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Hủy'),
            ),
          ],
        ),
      ),
    );
  }
}
