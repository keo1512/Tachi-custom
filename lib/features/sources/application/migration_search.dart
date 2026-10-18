import '../data/source_repository.dart';
import '../domain/catalogue.dart';

class MigrationSourceResult {
  MigrationSourceResult(
    this.source,
    List<CatalogueBook> books, {
    this.error = '',
    this.hasNextPage,
  }) : books = List.unmodifiable(books);
  final CatalogueSource source;
  final List<CatalogueBook> books;
  final String error;
  // Null keeps the nonempty-page fallback of older source adapters.
  final bool? hasNextPage;
}

class MigrationSearchProgress {
  MigrationSearchProgress(this.total, List<MigrationSourceResult> results)
    : results = List.unmodifiable(results);
  final int total;
  final List<MigrationSourceResult> results;
  int get completed => results.length;
  double get fraction => total == 0 ? 0 : completed / total;
}

/// A cancelled search never supplies late results or starts another source.
/// In-flight engine calls may finish; cancellation does not kill the native VM.
class MigrationSearch {
  MigrationSearch(
    this.repository, {
    this.timeout = const Duration(seconds: 30),
  });
  final SourceRepository repository;
  final Duration timeout;
  int _generation = 0;

  void cancel() => _generation++;

  Future<MigrationSearchProgress?> search(
    List<CatalogueSource> sources,
    String query, {
    int page = 1,
    void Function(MigrationSearchProgress)? onProgress,
  }) async {
    if (sources.isEmpty || sources.length > 50 || query.trim().isEmpty) {
      throw const FormatException('Chọn từ 1 đến 50 nguồn và nhập tên truyện.');
    }
    final unique = {for (final source in sources) source.identity: source};
    final selected = unique.values.toList(growable: false);
    final generation = ++_generation;
    final completed = <String, MigrationSourceResult>{};
    var next = 0;
    MigrationSearchProgress progress() =>
        MigrationSearchProgress(selected.length, [
          for (final source in selected)
            if (completed[source.identity] != null) completed[source.identity]!,
        ]);
    onProgress?.call(progress());
    Future<void> worker() async {
      while (generation == _generation && next < selected.length) {
        final source = selected[next++];
        MigrationSourceResult result;
        try {
          final books = await repository
              .search(source, query.trim(), page: page)
              .timeout(timeout);
          if (books.any(
            (book) =>
                book.engine != source.engine ||
                book.sourceId != source.id ||
                book.kind != source.kind,
          )) {
            throw const FormatException(
              'Nguồn trả kết quả có danh tính không khớp.',
            );
          }
          final identities = <String>{};
          result = MigrationSourceResult(
            source,
            books.where((book) => identities.add(book.identity)).toList(),
            hasNextPage: books is CataloguePage ? books.hasNextPage : null,
          );
        } catch (error) {
          result = MigrationSourceResult(source, const [], error: '$error');
        }
        if (generation != _generation) return;
        completed[source.identity] = result;
        onProgress?.call(progress());
      }
    }

    await Future.wait(
      List.generate(selected.length.clamp(1, 3), (_) => worker()),
    );
    return generation == _generation ? progress() : null;
  }
}
