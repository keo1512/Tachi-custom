import '../../sources/domain/catalogue.dart';
import '../data/library_snapshot.dart';

enum BackupSourceStatus { available, missing, unverified }

class BackupSourceRequirement {
  BackupSourceRequirement({
    required this.engine,
    required this.sourceId,
    required Iterable<String> bookTitles,
    required this.status,
    this.sourceName = '',
  }) : bookTitles = List.unmodifiable(bookTitles);

  final String engine, sourceId, sourceName;
  final List<String> bookTitles;
  final BackupSourceStatus status;
  String get identity => '$engine:$sourceId';
  String get engineLabel => switch (engine) {
    'tachimanga' => 'Tachimanga',
    'vbook' => 'vBook',
    _ => engine,
  };
}

class BackupSourceAvailability {
  BackupSourceAvailability(Iterable<BackupSourceRequirement> sources)
    : sources = List.unmodifiable(sources);
  final List<BackupSourceRequirement> sources;
  List<BackupSourceRequirement> get missing => sources
      .where((source) => source.status == BackupSourceStatus.missing)
      .toList(growable: false);
  List<BackupSourceRequirement> get unverified => sources
      .where((source) => source.status == BackupSourceStatus.unverified)
      .toList(growable: false);
  int get availableCount => sources
      .where((source) => source.status == BackupSourceStatus.available)
      .length;
}

typedef BackupSourceAvailabilityChecker =
    Future<BackupSourceAvailability> Function(LibrarySnapshot snapshot);

/// A best-effort inventory check, independent of restore and cached contents.
/// Successful enumeration confirms presence only, never reading compatibility.
Future<BackupSourceAvailability> checkBackupSourceAvailability(
  LibrarySnapshot snapshot,
  Future<List<CatalogueSource>> Function(SourceEngine engine) listSources, {
  Duration timeout = const Duration(seconds: 10),
}) async {
  final groups = <String, ({String engine, String id, List<String> titles})>{};
  for (final entry in snapshot.entries) {
    final book = entry.book;
    if (book.engine == 'local') continue;
    final key = '${book.engine}:${book.sourceId}';
    final group = groups.putIfAbsent(
      key,
      () => (engine: book.engine, id: book.sourceId, titles: []),
    );
    group.titles.add(book.title);
  }
  final inventory = <SourceEngine, Map<String, CatalogueSource>?>{};
  await Future.wait([
    for (final engine in SourceEngine.values)
      if (groups.values.any((group) => group.engine == engine.name))
        (() async {
          try {
            final sources = await listSources(engine).timeout(timeout);
            inventory[engine] = {
              for (final source in sources)
                if (source.engine == engine) source.id: source,
            };
          } catch (_) {
            // A disconnected/failed engine is not evidence of missing sources.
            inventory[engine] = null;
          }
        })(),
  ]);
  return BackupSourceAvailability([
    for (final group in groups.values)
      (() {
        final engine = SourceEngine.values
            .where((engine) => engine.name == group.engine)
            .firstOrNull;
        final listed = inventory[engine];
        final found = listed?[group.id];
        return BackupSourceRequirement(
          engine: group.engine,
          sourceId: group.id,
          bookTitles: group.titles,
          status: listed == null || group.id.isEmpty
              ? BackupSourceStatus.unverified
              : found == null
              ? BackupSourceStatus.missing
              : BackupSourceStatus.available,
          sourceName: found?.name ?? '',
        );
      })(),
  ]);
}
