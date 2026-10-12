import '../data/library_mutation.dart';
import '../data/library_repository.dart';
import '../../sources/data/source_repository.dart';
import '../../sources/domain/catalogue.dart';

class MetadataMaintenanceResult {
  const MetadataMaintenanceResult({
    required this.updated,
    required this.failed,
    required this.skipped,
  });
  final int updated, failed, skipped;
}

/// Writes only the requested fields to the latest book after the source response
/// and privacy/revision/identity checks. Local content never contacts a source.
class StorageMaintenance {
  StorageMaintenance(this.repository, this.source);
  final LibraryRepository repository;
  final SourceRepository source;

  Future<MetadataMaintenanceResult> refreshBooks(
    Iterable<String> ids, {
    required bool coversOnly,
    required int expectedRevision,
    required void Function() guard,
    void Function(int completed, int total)? onProgress,
  }) async {
    final selected = ids.toSet().toList();
    var updated = 0, failed = 0, skipped = 0;
    for (var index = 0; index < selected.length; index++) {
      guard();
      checkLibraryRevision(repository.replacementRevision, expectedRevision);
      final current = await repository.find(selected[index]);
      guard();
      if (current == null || current.engine == 'local') {
        skipped++;
        continue;
      }
      try {
        final incoming = await source.detail(
          CatalogueBook(
            ref: current.sourceRef,
            title: current.title,
            author: current.author,
            description: current.description,
            coverUrl: current.cover,
            sourceId: current.sourceId,
            kind: current.kind == 'manga'
                ? ContentKind.manga
                : ContentKind.novel,
            engine: current.engine == 'vbook'
                ? SourceEngine.vbook
                : SourceEngine.tachimanga,
          ),
        );
        guard();
        checkLibraryRevision(repository.replacementRevision, expectedRevision);
        final saved = await repository.mutateBook(current.id, (latest) {
          guard();
          if (bookSourceIdentity(latest) != bookSourceIdentity(current)) {
            throw StateError('Nguồn truyện đã thay đổi.');
          }
          final image = incoming.coverUrl.isEmpty
              ? latest.cover
              : incoming.coverUrl;
          return latest.copyWith(
            title: coversOnly ? null : incoming.title,
            author: coversOnly ? null : incoming.author,
            artist: coversOnly ? null : incoming.artist,
            description: coversOnly ? null : incoming.description,
            genres: coversOnly ? null : incoming.genres,
            status: coversOnly ? null : incoming.status,
            cover: latest.customCover ? latest.cover : image,
            originalCover: latest.customCover && incoming.coverUrl.isNotEmpty
                ? incoming.coverUrl
                : null,
          );
        }, expectedRevision: expectedRevision);
        if (saved == null) {
          skipped++;
        } else {
          updated++;
        }
      } catch (_) {
        // Cancellation, lock or replacement is not a recoverable per-source
        // failure: stop before scheduling another request or reporting success.
        guard();
        checkLibraryRevision(repository.replacementRevision, expectedRevision);
        failed++;
      }
      onProgress?.call(index + 1, selected.length);
    }
    return MetadataMaintenanceResult(
      updated: updated,
      failed: failed,
      skipped: skipped,
    );
  }
}
