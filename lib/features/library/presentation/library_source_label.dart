import '../domain/library_book.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../sources/domain/catalogue.dart';
import 'library_view_model.dart';

/// Look up identities in loaded sources, including libraries imported before
/// source names were preserved. Failure of one engine does not hide the other.
final librarySourceNamesProvider =
    FutureProvider.autoDispose<Map<String, String>>((ref) async {
      final repository = ref.watch(sourceRepositoryProvider);
      final groups = await Future.wait([
        for (final engine in SourceEngine.values)
          repository
              .listSources(engine)
              .catchError((Object _) => <CatalogueSource>[]),
      ]);
      return {
        for (final source in groups.expand((s) => s))
          '${source.engine.name}:${source.id}': source.name,
      };
    });

String resolvedLibrarySourceLabel(WidgetRef ref, LibraryBook book) {
  if (book.engine == 'local') return 'Trong thiết bị';
  final names = ref.watch(librarySourceNamesProvider).value;
  return librarySourceLabel(
    book.copyWith(
      sourceName: names?['${book.engine}:${book.sourceId}'] ?? book.sourceName,
    ),
  );
}

String librarySourceLabel(LibraryBook book) => sourceDisplayLabel(
  engine: book.engine,
  sourceName: book.sourceName,
  sourceRef: RegExp(r'^\d+$').hasMatch(book.sourceRef)
      ? book.chapters
                .map((c) => c.id)
                .where(
                  (id) => id.startsWith('https://') || id.startsWith('http://'),
                )
                .firstOrNull ??
            book.sourceRef
      : book.sourceRef,
);

/// Source IDs remain data identities, rather than names presented to readers.
String sourceDisplayLabel({
  required String engine,
  String sourceName = '',
  String sourceRef = '',
}) {
  if (engine == 'local') return 'Trong thiết bị';
  final name = sourceName.trim();
  if (name.isNotEmpty && !RegExp(r'^-?\d+$').hasMatch(name)) return name;
  final url = Uri.tryParse(sourceRef);
  if (url != null &&
      (url.scheme == 'https' || url.scheme == 'http') &&
      url.host.isNotEmpty) {
    return url.host;
  }
  return engine == 'vbook' ? 'Nguồn vBook' : 'Nguồn Tachimanga';
}
