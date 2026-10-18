import 'dart:convert';

import 'package:flutter/services.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../sources/domain/catalogue.dart';
import '../../sources/presentation/extension_catalogue_controller.dart';
import '../domain/library_book.dart';
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

/// Public source identity metadata is bundled for offline backup restores.
/// Looking up a display name never installs or runs an extension.
final bundledSourceNamesProvider = FutureProvider<Map<String, String>>((
  ref,
) async {
  final raw = await rootBundle.loadString(
    'assets/source_catalogue/keiyoushi_names.json',
  );
  final value = jsonDecode(raw) as Map;
  if (value['version'] != 1 || value['names'] is! Map) {
    throw const FormatException('Danh mục tên nguồn không hợp lệ.');
  }
  return {
    for (final entry in (value['names'] as Map).entries)
      'tachimanga:${entry.key}': entry.value as String,
  };
});

final resolvedSourceNamesProvider = Provider<Map<String, String>>(
  (ref) => {
    ...?ref.watch(bundledSourceNamesProvider).value,
    for (final index in ref.watch(extensionCatalogueProvider).value ?? [])
      for (final extension in index.entries)
        for (final source in extension.sources) source.identity: source.name,
    ...?ref.watch(librarySourceNamesProvider).value,
  },
);

String resolvedLibrarySourceLabel(WidgetRef ref, LibraryBook book) {
  if (book.engine == 'local') return 'Trong thiết bị';
  return librarySourceLabel(
    book,
    names: ref.watch(resolvedSourceNamesProvider),
  );
}

String librarySourceLabel(
  LibraryBook book, {
  Map<String, String> names = const {},
}) => sourceDisplayLabel(
  engine: book.engine,
  sourceName: _isSourceName(book.sourceName)
      ? book.sourceName
      : names['${book.engine}:${book.sourceId}'] ?? '',
  sourceRef: RegExp(r'^\d+$').hasMatch(book.sourceRef)
      ? book.chapters
                .map((c) => c.id)
                .where(
                  (id) => id.startsWith('https://') || id.startsWith('http://'),
                )
                .firstOrNull ??
            book.sourceRef
      : book.sourceRef,
  sourceId: book.sourceId,
);

bool _isSourceName(String value) {
  final name = value.trim();
  return name.isNotEmpty &&
      !RegExp(r'^-?\d+$').hasMatch(name) &&
      !{'nguồn tachimanga', 'nguồn vbook'}.contains(name.toLowerCase());
}

/// Source IDs remain data identities, rather than names presented to readers.
String sourceDisplayLabel({
  required String engine,
  String sourceName = '',
  String sourceRef = '',
  String sourceId = '',
}) {
  if (engine == 'local') return 'Trong thiết bị';
  final name = sourceName.trim();
  if (_isSourceName(name)) return name;
  final url = Uri.tryParse(sourceRef);
  if (url != null &&
      (url.scheme == 'https' || url.scheme == 'http') &&
      url.host.isNotEmpty) {
    return url.host;
  }
  return sourceId.isEmpty
      ? 'Chưa xác định tên nguồn'
      : 'Nguồn chưa xác định · $sourceId';
}
