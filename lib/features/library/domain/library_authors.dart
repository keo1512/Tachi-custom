/// Author names come from stored metadata. Do not infer them from a title or
/// merge names that only share a substring (for example, Ann and Anna).
String libraryAuthorKey(String name) =>
    name.trim().replaceAll(RegExp(r'\s+'), ' ').toLowerCase();

Map<String, String> libraryAuthorNames(String authors) {
  final names = <String, String>{};
  for (final raw in authors.split(RegExp(r'[,;\n\r|]'))) {
    final name = raw.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (name.isNotEmpty) names.putIfAbsent(libraryAuthorKey(name), () => name);
  }
  return names;
}
