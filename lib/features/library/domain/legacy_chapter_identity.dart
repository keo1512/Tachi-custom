import 'library_book.dart';

/// Migrates only legacy ordinals still verifiable against the same source's
/// stable title URL and an unambiguous chapter title/number at that ordinal.
/// A changed order or an unverified numeric manga reference stays untouched.
Map<String, String> verifiedLegacyChapterIds(
  LibraryBook book,
  List<BookChapter> incoming,
) {
  final numeric = RegExp(r'^\d+$');
  final legacy = book.chapters.where((c) => numeric.hasMatch(c.id)).toList();
  if (legacy.isEmpty) return {};
  bool stable(String value) {
    final uri = Uri.tryParse(value);
    return (value.startsWith('/') && !value.startsWith('//')) ||
        (uri != null &&
            ['https', 'http'].contains(uri.scheme) &&
            uri.hasAuthority);
  }

  final source = BigInt.tryParse(book.sourceId);
  if (book.engine != 'tachimanga' ||
      source == null ||
      source.toString() != book.sourceId ||
      !stable(book.sourceRef)) {
    return {};
  }
  String name(BookChapter c) =>
      c.title.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
  final namesBefore = <String, int>{}, namesAfter = <String, int>{};
  final numbersBefore = <double, int>{}, numbersAfter = <double, int>{};
  double? number(BookChapter c) =>
      c.number != null && c.number!.isFinite && c.number! >= 0
      ? c.number
      : null;
  for (final c in book.chapters) {
    namesBefore.update(name(c), (n) => n + 1, ifAbsent: () => 1);
    final n = number(c);
    if (n != null) numbersBefore.update(n, (n) => n + 1, ifAbsent: () => 1);
  }
  for (final c in incoming) {
    namesAfter.update(name(c), (n) => n + 1, ifAbsent: () => 1);
    final n = number(c);
    if (n != null) numbersAfter.update(n, (n) => n + 1, ifAbsent: () => 1);
  }
  final result = <String, String>{};
  for (final old in legacy) {
    final ordinal = int.tryParse(old.id);
    if (ordinal != old.index || ordinal == null || ordinal >= incoming.length) {
      return {};
    }
    final next = incoming[ordinal];
    final key = name(old), oldNumber = number(old), nextNumber = number(next);
    if (book.chapters.any((c) => c.id == next.id && c.id != old.id) ||
        !stable(next.id) ||
        next.index != ordinal ||
        key.isEmpty ||
        key != name(next) ||
        namesBefore[key] != 1 ||
        namesAfter[key] != 1 ||
        (oldNumber != null && nextNumber != null && oldNumber != nextNumber) ||
        (oldNumber != null && numbersBefore[oldNumber] != 1) ||
        (nextNumber != null && numbersAfter[nextNumber] != 1)) {
      return {};
    }
    result[old.id] = next.id;
  }
  return result;
}
