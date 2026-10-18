import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../../core/format/error_messages.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/widgets/book_cover.dart';
import '../../library/domain/library_book.dart';
import '../../library/presentation/library_view_model.dart';
import '../../library/presentation/library_source_label.dart';
import '../domain/catalogue.dart';
import '../domain/source_migration.dart';
import '../application/source_migration_service.dart';
import '../application/bulk_migration_matcher.dart';
import 'bulk_migration_settings.dart';
import 'bulk_migration_review.dart';
import 'migration_source_selection.dart';
import 'source_cover_image.dart';
import 'source_migration_screen.dart';

class BulkSourceMigrationScreen extends ConsumerStatefulWidget {
  const BulkSourceMigrationScreen({
    super.key,
    required this.sources,
    this.initialSource = '',
    this.initialBookIds = const {},
  });
  final List<CatalogueSource> sources;
  final String initialSource;
  final Set<String> initialBookIds;
  @override
  ConsumerState<BulkSourceMigrationScreen> createState() =>
      _BulkMigrationState();
}

class _BulkMigrationState extends ConsumerState<BulkSourceMigrationScreen> {
  final selected = <String>{};
  final previews = <String, SourceMigrationPreview>{};
  List<CatalogueSource> targetSources = const [];
  int targetRevision = 0;
  late int selectionRevision = ref
      .read(libraryRepositoryProvider)
      .replacementRevision;
  late String source = widget.initialSource;
  String query = '';
  String? error;
  bool busy = false;
  bool matching = false, reviewing = false;
  int runGeneration = 0;
  BulkMigrationSettings settings = const BulkMigrationSettings();
  BulkMigrationProgress? progress;
  final outcomes = <String, BulkMigrationMatch>{};
  SourceMigrationSession? session;
  late final BulkMigrationMatcher matcher;

  @override
  void initState() {
    super.initState();
    selected.addAll(widget.initialBookIds);
    matcher = BulkMigrationMatcher(
      ref.read(sourceRepositoryProvider),
      ref.read(sourceMigrationProvider),
    );
  }

  @override
  void dispose() {
    runGeneration++;
    matcher.cancel();
    super.dispose();
  }

  void cancelMatching() {
    matcher.cancel();
    runGeneration++;
    setState(() {
      matching = false;
      busy = false;
      progress = null;
    });
  }

  Future<void> startMatching() async {
    if (busy || selected.isEmpty) return;
    final expectedRevision = selectionRevision;
    if (targetSources.isEmpty) await chooseTargets();
    if (!mounted || targetSources.isEmpty || selected.isEmpty) return;
    final chosen = await showBulkMigrationSettings(context, settings);
    if (!mounted || chosen == null) return;
    final latestRevision = ref
        .read(libraryRepositoryProvider)
        .replacementRevision;
    if (latestRevision != expectedRevision) {
      resetAfterReplacement(latestRevision);
      return;
    }
    final migration = ref.read(sourceMigrationProvider);
    final request = ++runGeneration;
    final targetsVersion = targetRevision;
    setState(() {
      if (settings.strategy != chosen.strategy) {
        previews.clear();
        outcomes.clear();
      }
      settings = chosen;
      busy = true;
      matching = true;
      reviewing = true;
      error = null;
      for (final id in previews.keys.toList()) {
        previews[id] = previews[id]!.withOptions(settings.options);
      }
    });
    void check() {
      if (!mounted ||
          request != runGeneration ||
          targetsVersion != targetRevision) {
        throw StateError('Đã hủy tìm và ghép nguồn.');
      }
      if (ref.read(libraryRepositoryProvider).replacementRevision !=
          selectionRevision) {
        throw StateError('Thư viện đã khôi phục. Hãy chọn và tìm lại.');
      }
    }

    try {
      check();
      final activeSession =
          session ?? await migration.beginSession(check: check);
      check();
      migration.checkSession(activeSession);
      session = activeSession;
      final pending = selected
          .where((id) => !previews.containsKey(id))
          .toList();
      if (pending.isNotEmpty) {
        await matcher.match(
          bookIds: pending,
          targets: targetSources,
          strategy: settings.strategy,
          options: settings.options,
          session: activeSession,
          usedTargetIds: previews.values.map((p) => p.replacement.id).toSet(),
          onProgress: (value) {
            if (mounted && request == runGeneration) {
              setState(() => progress = value);
            }
          },
          onResult: (value) {
            if (!mounted || request != runGeneration) return;
            setState(() {
              outcomes[value.bookId] = value;
              if (value.preview != null) {
                previews[value.bookId] = value.preview!;
              }
            });
          },
        );
      }
      check();
    } catch (e) {
      if (mounted && request == runGeneration) {
        setState(() {
          error = userFacingError(e);
          session = null;
          previews.clear();
          outcomes.clear();
        });
      }
    } finally {
      if (mounted && request == runGeneration) {
        setState(() {
          busy = false;
          matching = false;
          progress = null;
        });
      }
    }
  }

  Future<void> chooseTargets() async {
    final revision = ref.read(libraryRepositoryProvider).replacementRevision;
    final candidates = widget.sources
        .where((s) => source.isEmpty || s.identity != source)
        .toList();
    final result = await selectMigrationSources(
      context,
      candidates: candidates,
      selected: targetSources.map((s) => s.identity).toSet(),
      title: 'Chọn nguồn đích',
      ordered: true,
    );
    if (!mounted ||
        result == null ||
        result.isEmpty ||
        revision != ref.read(libraryRepositoryProvider).replacementRevision) {
      return;
    }
    setState(() {
      targetSources = result;
      targetRevision++;
      previews.clear();
      outcomes.clear();
      session = null;
      error = null;
    });
  }

  Future<void> choose(LibraryBook book) async {
    final revision = ref.read(libraryRepositoryProvider).replacementRevision;
    final targetsVersion = targetRevision;
    final candidates = widget.sources
        .where(
          (s) =>
              s.kind.name == book.kind &&
              s.identity != '${book.engine}:${book.sourceId}',
        )
        .toList();
    final List<CatalogueSource>? targets;
    if (targetSources.isEmpty) {
      targets = await chooseMigrationSources(
        context,
        candidates: candidates,
        title: book.title,
      );
    } else {
      final identities = candidates.map((s) => s.identity).toSet();
      targets = targetSources
          .where((s) => identities.contains(s.identity))
          .toList();
      if (targets.isEmpty) {
        setState(
          () => error = 'Nguồn đích đã chọn không phù hợp với truyện này. Chọn nguồn khác loại phù hợp và khác nguồn cũ.',
        );
        return;
      }
    }
    if (targets == null ||
        targets.isEmpty ||
        !mounted ||
        revision != ref.read(libraryRepositoryProvider).replacementRevision ||
        targetsVersion != targetRevision) {
      return;
    }
    final chosenTargets = targets;
    final preview = reviewing
        ? await Navigator.of(context).push<SourceMigrationPreview>(
            CupertinoPageRoute(
              builder: (_) => SourceMigrationScreen(
                bookId: book.id,
                source: chosenTargets.first,
                alternatives: chosenTargets,
                selectionOnly: true,
                session: session,
                options: settings.options,
              ),
            ),
          )
        : await context.push<SourceMigrationPreview>(
            '/migrate',
            extra: <String, Object>{
              'bookId': book.id,
              'source': targets.first,
              'sources': targets,
              'selectionOnly': true,
            },
          );
    if (preview != null &&
        mounted &&
        revision == ref.read(libraryRepositoryProvider).replacementRevision &&
        targetsVersion == targetRevision) {
      try {
        final adjusted = preview.withOptions(settings.options);
        final shared = previews.isEmpty
            ? adjusted
            : adjusted.sharingSnapshot(previews.values.first);
        setState(() {
          selected.add(book.id);
          previews[book.id] = shared;
          outcomes.remove(book.id);
          error = null;
        });
      } catch (e) {
        setState(() => error = userFacingError(e));
      }
    }
  }

  Future<void> commit() async {
    final revision = ref.read(libraryRepositoryProvider).replacementRevision;
    if (revision != selectionRevision) {
      resetAfterReplacement(revision);
      return;
    }
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
          'Chuyển các kết quả đang hiển thị để đối chiếu. ${selected.length - ready.length} truyện chưa có kết quả sẽ được bỏ qua. $offline chương offline vẫn thuộc truyện cũ; nguồn mới cần tải lại. ${settings.options.categories ? 'Giữ danh mục và thư mục.' : 'Truyện mới vào danh mục Mặc định, không sao chép thư mục.'} ${settings.options.chapters ? 'Giữ tiến độ chương và dấu trang khớp.' : 'Không sao chép tiến độ chương và dấu trang.'} Thời lượng đọc chỉ chuyển khi thay thế; giữ cả hai thì thời lượng vẫn ở truyện cũ để không cộng hai lần. Dữ liệu được ghi cùng lúc và có bản phục hồi.',
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
    final latestRevision = ref
        .read(libraryRepositoryProvider)
        .replacementRevision;
    if (latestRevision != revision) {
      resetAfterReplacement(latestRevision);
      return;
    }
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final repository = ref.read(libraryRepositoryProvider);
      final completed = await ref
          .read(sourceMigrationProvider)
          .commitBatch(ready, replaceOld: choice, expectedRevision: revision);
      if (!mounted) return;
      final committedRevision = repository.replacementRevision;
      if (committedRevision != revision + 1) {
        resetAfterReplacement(committedRevision);
        return;
      }
      setState(() {
        selectionRevision = committedRevision;
        selected.clear();
        previews.clear();
        outcomes.clear();
        session = null;
        reviewing = false;
        error = null;
      });
      await ref.read(libraryProvider.notifier).refresh();
      if (!mounted) return;
      if (repository.replacementRevision != committedRevision) return;
      final remaining =
          ref.read(libraryProvider).value ?? const <LibraryBook>[];
      if (source.isNotEmpty &&
          !remaining.any((b) => '${b.engine}:${b.sourceId}' == source)) {
        setState(() => source = '');
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Đã chuyển ${completed.length} truyện.')),
      );
    } catch (e) {
      if (e is SourceMigrationRecoveryRequired && mounted) {
        setState(() {
          selectionRevision = ref
              .read(libraryRepositoryProvider)
              .replacementRevision;
          selected.clear();
          previews.clear();
          outcomes.clear();
          session = null;
        });
        await ref.read(libraryProvider.notifier).refresh();
      }
      if (mounted) {
        setState(
          () => error = e is SourceMigrationRecoveryRequired
              ? userFacingError(e)
              : 'Chưa chuyển truyện nào. ${userFacingError(e)}',
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  void resetAfterReplacement(int revision) {
    setState(() {
      selectionRevision = revision;
      selected.clear();
      previews.clear();
      outcomes.clear();
      session = null;
      error = 'Thư viện đã được khôi phục. Hãy chọn và xem trước kết quả lại.';
    });
  }

  @override
  Widget build(BuildContext context) {
    final books = (ref.watch(libraryProvider).value ?? [])
        .where((b) => b.engine != 'local')
        .toList();
    final revision = ref.read(libraryRepositoryProvider).replacementRevision;
    if (selectionRevision != revision) {
      selectionRevision = revision;
      selected.clear();
      previews.clear();
      outcomes.clear();
      session = null;
      matcher.cancel();
      runGeneration++;
      matching = false;
      busy = false;
      error = 'Thư viện đã được khôi phục. Hãy chọn và xem trước kết quả lại.';
    }
    final sourceKeys =
        books.map((b) => '${b.engine}:${b.sourceId}').toSet().toList()..sort();
    final sourceLabels = {
      for (final book in books)
        '${book.engine}:${book.sourceId}': resolvedLibrarySourceLabel(
          ref,
          book,
        ),
      for (final known in widget.sources)
        known.identity: sourceDisplayLabel(
          engine: known.engine.name,
          sourceName: known.name,
          sourceRef: known.baseUrl,
        ),
    };
    final visible = books
        .where(
          (b) =>
              (source.isEmpty || source == '${b.engine}:${b.sourceId}') &&
              b.title.toLowerCase().contains(query.toLowerCase()),
        )
        .toList();
    final ready = selected.where(previews.containsKey).length;
    return PopScope(
      canPop: !busy || matching,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Chuyển nguồn hàng loạt'),
          actions: [
            if (reviewing && !busy)
              TextButton(
                onPressed: () => setState(() => reviewing = false),
                child: const Text('Chọn lại'),
              ),
          ],
        ),
        body: Column(
          children: [
            if (reviewing)
              Expanded(
                child: BulkMigrationReview(
                  books: [
                    for (final book in books)
                      if (selected.contains(book.id)) book,
                  ],
                  previews: previews,
                  outcomes: outcomes,
                  progress: progress,
                  busy: busy,
                  onChange: choose,
                  onSkip: (book) => setState(() {
                    selected.remove(book.id);
                    previews.remove(book.id);
                    outcomes.remove(book.id);
                  }),
                ),
              ),
            if (!reviewing)
              Expanded(
                child: ListView.builder(
                  itemCount: visible.length + 1,
                  itemBuilder: (context, index) {
                    if (index == 0) {
                      return Padding(
                        padding: const EdgeInsets.all(12),
                        child: Column(
                          children: [
                            DropdownButtonFormField<String>(
                              initialValue: sourceKeys.contains(source)
                                  ? source
                                  : '',
                              isExpanded: true,
                              decoration: const InputDecoration(
                                labelText: 'Nguồn cũ',
                              ),
                              items: [
                                const DropdownMenuItem(
                                  value: '',
                                  child: Text('Tất cả nguồn'),
                                ),
                                for (final key in sourceKeys)
                                  DropdownMenuItem(
                                    value: key,
                                    child: Text(
                                      sourceLabels[key]!,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                              ],
                              onChanged: busy
                                  ? null
                                  : (v) => setState(() {
                                      source = v ?? '';
                                      targetSources = targetSources
                                          .where((s) => s.identity != source)
                                          .toList();
                                      targetRevision++;
                                      previews.clear();
                                      selected.clear();
                                      outcomes.clear();
                                      session = null;
                                    }),
                            ),
                            const SizedBox(height: 16),
                            OutlinedButton.icon(
                              key: const ValueKey('migration-target-sources'),
                              onPressed: busy ? null : chooseTargets,
                              icon: const Icon(
                                CupertinoIcons.arrow_right_arrow_left,
                              ),
                              label: Padding(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 12,
                                ),
                                child: Text(
                                  targetSources.isEmpty
                                      ? 'Chọn nguồn đích'
                                      : 'Nguồn đích: ${targetSources.map((s) => s.name).join(', ')}',
                                  textAlign: TextAlign.center,
                                ),
                              ),
                            ),
                            const SizedBox(height: 16),
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
                                          () => selected.addAll(
                                            visible.map((b) => b.id),
                                          ),
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
                              LinearProgressIndicator(
                                value: ready / selected.length,
                              ),
                            if (error != null)
                              Text(
                                error!,
                                style: TextStyle(
                                  color: Theme.of(context).colorScheme.error,
                                ),
                              ),
                          ],
                        ),
                      );
                    }
                    final book = visible[index - 1];
                    return ListTile(
                      key: ValueKey('migration-bulk-book-${book.id}'),
                      leading: SizedBox(
                        width: 86,
                        child: Row(
                          children: [
                            Checkbox(
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
                            SizedBox(
                              width: 38,
                              height: 54,
                              child: BookCover(
                                title: book.title,
                                cover: book.cover,
                                imageProvider: libraryCoverImage(ref, book),
                                kind: book.kind,
                                showTitle: false,
                              ),
                            ),
                          ],
                        ),
                      ),
                      title: Text(
                        book.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        previews[book.id] == null
                            ? '${resolvedLibrarySourceLabel(ref, book)}\nChưa chọn kết quả'
                            : '${resolvedLibrarySourceLabel(ref, book)}\n→ ${previews[book.id]!.replacement.title}\nGhép ${previews[book.id]!.matches.length}/${book.chapters.length} chương',
                      ),
                      trailing: const Icon(CupertinoIcons.search),
                      onTap: busy ? null : () => choose(book),
                    );
                  },
                ),
              ),
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: SizedBox(
                  width: double.infinity,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (error != null && reviewing)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: Text(
                            error!,
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.error,
                            ),
                          ),
                        ),
                      if (matching)
                        OutlinedButton(
                          onPressed: cancelMatching,
                          child: const Text('Hủy tìm và ghép'),
                        )
                      else if (selected.isNotEmpty &&
                          (!reviewing ||
                              selected.any((id) => !previews.containsKey(id))))
                        SizedBox(
                          width: double.infinity,
                          child: FilledButton.icon(
                            key: const ValueKey('migration-batch-start'),
                            onPressed: busy ? null : startMatching,
                            icon: const Icon(CupertinoIcons.search),
                            label: Text(
                              reviewing
                                  ? 'Thử lại truyện chưa ghép'
                                  : 'Bắt đầu tìm và ghép ${selected.length} truyện',
                            ),
                          ),
                        ),
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton(
                          onPressed: ready == 0 || busy ? null : commit,
                          child: busy
                              ? const CupertinoActivityIndicator()
                              : Text('Xem lại và chuyển $ready truyện'),
                        ),
                      ),
                    ],
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
