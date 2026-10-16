import '../domain/library_book.dart';

String librarySourceLabel(LibraryBook book) => sourceDisplayLabel(
  engine: book.engine,
  sourceName: book.sourceName,
  sourceRef: book.sourceRef,
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
