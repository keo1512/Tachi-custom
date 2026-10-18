import 'dart:async';

import '../../../core/format/error_messages.dart';
import '../data/source_repository.dart';
import '../domain/catalogue.dart';
import '../domain/source_migration.dart';

enum BulkMigrationStrategy { firstMatch, mostChapters }

enum BulkMatchState { matched, notFound, ambiguous, failed, duplicate }

class BulkMigrationMatch {
  const BulkMigrationMatch(
    this.bookId,
    this.state, {
    this.preview,
    this.message = '',
  });
  final String bookId;
  final BulkMatchState state;
  final SourceMigrationPreview? preview;
  final String message;
}

class BulkMigrationProgress {
  const BulkMigrationProgress(this.completed, this.total, this.title);
  final int completed, total;
  final String title;
}

class _Cancelled implements Exception {}

/// Matching is read-only. One book/source is requested at a time to avoid
/// flooding extension queues. Cancellation drops late RPC results immediately;
/// it deliberately does not terminate the native extension runtime.
class BulkMigrationMatcher {
  BulkMigrationMatcher(
    this.sources,
    this.migration, {
    this.timeout = const Duration(seconds: 30),
    this.maxPages = 3,
  });
  final SourceRepository sources;
  final SourceMigration migration;
  final Duration timeout;
  final int maxPages;
  int _generation = 0;
  Completer<void>? _cancelled;

  void cancel() {
    _generation++;
    final pending = _cancelled;
    if (pending != null && !pending.isCompleted) pending.complete();
  }

  Future<List<BulkMigrationMatch>?> match({
    required List<String> bookIds,
    required List<CatalogueSource> targets,
    required BulkMigrationStrategy strategy,
    SourceMigrationOptions options = const SourceMigrationOptions(),
    SourceMigrationSession? session,
    Set<String> usedTargetIds = const {},
    void Function(BulkMigrationProgress)? onProgress,
    void Function(BulkMigrationMatch)? onResult,
  }) async {
    if (bookIds.isEmpty ||
        bookIds.length > 10000 ||
        targets.isEmpty ||
        targets.length > 50 ||
        maxPages < 1) {
      throw const FormatException('Chọn truyện và từ 1 đến 50 nguồn đích.');
    }
    cancel();
    final generation = _generation;
    final cancellation = Completer<void>();
    _cancelled = cancellation;
    final ids = bookIds.toSet().toList();
    final ordered = {for (final source in targets) source.identity: source}
        .values
        .toList();
    void check() {
      if (generation != _generation) throw _Cancelled();
      if (session != null) migration.checkSession(session);
    }

    Future<T> request<T>(Future<T> Function() call) async {
      check();
      final value = await Future.any<T>([
        call().timeout(timeout),
        cancellation.future.then<T>((_) => throw _Cancelled()),
      ]);
      check();
      return value;
    }

    try {
      session ??= await Future.any<SourceMigrationSession>([
        migration.beginSession(check: check),
        cancellation.future.then<SourceMigrationSession>(
          (_) => throw _Cancelled(),
        ),
      ]);
      check();
      final results = <BulkMigrationMatch>[];
      final used = {...usedTargetIds};
      for (final id in ids) {
        check();
        final book = session.books[id];
        if (book == null || book.engine == 'local') {
          throw StateError(
            'Truyện đã chọn không còn trong thư viện. Hãy chọn lại.',
          );
        }
        onProgress?.call(
          BulkMigrationProgress(results.length, ids.length, book.title),
        );
        SourceMigrationPreview? best;
        final problems = <String>[];
        var ambiguous = false;
        for (final source in ordered) {
          check();
          if (source.kind.name != book.kind ||
              source.identity == '${book.engine}:${book.sourceId}') {
            continue;
          }
          try {
            final exact = <String, CatalogueBook>{};
            var incomplete = false;
            final titles = [book.title, ...book.alternativeTitles];
            final normalized = titles
                .map(normalizeMigrationTitle)
                .where((s) => s.isNotEmpty)
                .toSet();
            for (final query
                in titles
                    .map((s) => s.trim())
                    .where((s) => s.isNotEmpty)
                    .toSet()) {
              for (var page = 1; page <= maxPages; page++) {
                final found = await request(
                  () => sources.search(source, query, page: page),
                );
                for (final candidate in found) {
                  if (candidate.engine != source.engine ||
                      candidate.sourceId != source.id ||
                      candidate.kind != source.kind) {
                    throw const FormatException(
                      'Nguồn trả về truyện có danh tính không khớp.',
                    );
                  }
                  if (normalized.contains(
                    normalizeMigrationTitle(candidate.title),
                  )) {
                    exact[candidate.identity] = candidate;
                  }
                }
                final more = found is CataloguePage
                    ? found.hasNextPage
                    : found.isNotEmpty;
                if (!more) break;
                if (page == maxPages) incomplete = true;
              }
              // A unique exact title is enough; aliases are fallback queries.
              if (exact.isNotEmpty) break;
            }
            if (exact.length > 1 || (incomplete && exact.isNotEmpty)) {
              ambiguous = true;
              continue;
            }
            if (exact.isEmpty) continue;
            final selected = exact.values.single;
            final detail = await request(() => sources.detail(selected));
            if (detail.identity != selected.identity ||
                detail.kind != selected.kind) {
              throw const FormatException(
                'Chi tiết truyện không khớp kết quả đã tìm.',
              );
            }
            final chapters = await request(() => sources.chapters(detail));
            final preview = await request(
              () => migration.preview(
                id,
                detail,
                chapters,
                sourceName: source.name,
                session: session,
                options: options,
              ),
            );
            if (best == null ||
                preview.replacement.chapters.length >
                    best.replacement.chapters.length) {
              best = preview;
            }
            if (strategy == BulkMigrationStrategy.firstMatch) break;
          } on _Cancelled {
            rethrow;
          } catch (error) {
            check(); // A restore invalidates the run rather than one source.
            problems.add('${source.name}: ${userFacingError(error)}');
          }
        }
        check();
        final BulkMigrationMatch result;
        if (best != null && !used.add(best.replacement.id)) {
          result = BulkMigrationMatch(
            id,
            BulkMatchState.duplicate,
            message:
                'Kết quả đích đã ghép cho truyện khác. Hãy chọn lại thủ công.',
          );
        } else if (best != null) {
          result = BulkMigrationMatch(
            id,
            BulkMatchState.matched,
            preview: best,
            message: problems.join('\n'),
          );
        } else {
          result = BulkMigrationMatch(
            id,
            ambiguous
                ? BulkMatchState.ambiguous
                : problems.isNotEmpty
                ? BulkMatchState.failed
                : BulkMatchState.notFound,
            message: ambiguous
                ? 'Có nhiều kết quả hoặc chưa tìm hết các trang. Hãy chọn thủ công.'
                : problems.isNotEmpty
                ? problems.join('\n')
                : 'Không tìm thấy tên trùng khớp. Hãy tìm lại thủ công.',
          );
        }
        results.add(result);
        onResult?.call(result);
        onProgress?.call(
          BulkMigrationProgress(results.length, ids.length, book.title),
        );
        await Future<void>.delayed(Duration.zero);
      }
      check();
      return results;
    } on _Cancelled {
      return null;
    } finally {
      if (identical(_cancelled, cancellation)) _cancelled = null;
    }
  }
}

String normalizeMigrationTitle(String title) => title
    .trim()
    .toLowerCase()
    .replaceAll(RegExp(r'[^\p{L}\p{N}]+', unicode: true), ' ')
    .trim();
