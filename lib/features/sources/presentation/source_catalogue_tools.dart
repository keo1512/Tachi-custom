import '../../library/domain/library_book.dart';
import '../domain/catalogue.dart';

Map<String, LibraryBook> catalogueLibraryIndex(Iterable<LibraryBook> books) => {
  for (final book in books)
    if (book.engine != 'local')
      '${book.engine}:${book.sourceId}:${book.sourceRef}': book,
};

bool sameExtension(CatalogueExtension a, CatalogueExtension b) =>
    a.engine == b.engine &&
    (a.id == b.id || (a.packageUrl.isNotEmpty && a.packageUrl == b.packageUrl));

/// Only comparable numerical release versions are treated as upgrades.
int? compareExtensionVersions(String a, String b) {
  List<int>? parse(String value) {
    if (!RegExp(r'^\d+(\.\d+)*$').hasMatch(value)) return null;
    return value.split('.').map(int.parse).toList();
  }

  final left = parse(a), right = parse(b);
  if (left == null || right == null) return null;
  for (var i = 0; i < left.length || i < right.length; i++) {
    final result = (i < left.length ? left[i] : 0).compareTo(
      i < right.length ? right[i] : 0,
    );
    if (result != 0) return result;
  }
  return 0;
}

List<CatalogueExtension> availableExtensionUpdates(
  Iterable<CatalogueExtension> catalogue,
  Iterable<CatalogueExtension> installed,
) {
  final found = <String, CatalogueExtension>{};
  for (final candidate in catalogue) {
    final current = installed
        .where((item) => item.installed && sameExtension(item, candidate))
        .firstOrNull;
    if (current == null ||
        (compareExtensionVersions(candidate.version, current.version) ?? 0) <=
            0) {
      continue;
    }
    final key = '${current.engine.name}:${current.id}';
    final previous = found[key];
    if (previous == null ||
        (compareExtensionVersions(candidate.version, previous.version) ?? 0) >
            0) {
      found[key] = candidate;
    }
  }
  return found.values.toList(growable: false);
}
