import 'library_book.dart';
import 'library_reading.dart';

enum ChapterSort { source, number, title }

/// Presentation never changes the canonical chapter indices or identities.
class ChapterListOptions {
  const ChapterListOptions({
    this.read = 'all',
    this.download = 'all',
    this.bookmarked = 'all',
    this.sort = ChapterSort.source,
    this.descending = false,
    this.hideDuplicates = false,
    this.preferredScanlator = '',
    this.excludedScanlators = const [],
    this.scanlator = '',
  });
  final String read, download, bookmarked, preferredScanlator, scanlator;
  final ChapterSort sort;
  final bool descending, hideDuplicates;
  final List<String> excludedScanlators;

  /// Backup input is untrusted; do not silently coerce invalid choices.
  static void validateJson(Object? value) {
    if (value is! Map || value.keys.any((key) => key is! String)) {
      throw const FormatException(
        'Thiết lập danh sách chương phải là object JSON.',
      );
    }
    const choices = {
      'read': ['all', 'read', 'unread'],
      'download': ['all', 'downloaded', 'online'],
      'bookmarked': ['all', 'yes', 'no'],
      'sort': ['source', 'number', 'title'],
    };
    for (final entry in choices.entries) {
      if (value.containsKey(entry.key) &&
          !entry.value.contains(value[entry.key])) {
        throw const FormatException('Bộ lọc hoặc thứ tự chương không hợp lệ.');
      }
    }
    for (final key in ['descending', 'hideDuplicates']) {
      if (value.containsKey(key) && value[key] is! bool) {
        throw const FormatException(
          'Thiết lập thứ tự chương phải là true hoặc false.',
        );
      }
    }
    for (final key in ['preferredScanlator', 'scanlator']) {
      if (value.containsKey(key) &&
          (value[key] is! String || (value[key] as String).length > 4096)) {
        throw const FormatException('Tên nhóm dịch không hợp lệ.');
      }
    }
    if (value.containsKey('excludedScanlators')) {
      final excluded = value['excludedScanlators'];
      if (excluded is! List ||
          excluded.length > 10000 ||
          excluded.any((item) => item is! String || item.length > 4096)) {
        throw const FormatException(
          'Danh sách nhóm dịch bị loại trừ không hợp lệ.',
        );
      }
    }
  }

  factory ChapterListOptions.fromJson(Map<String, dynamic> value) =>
      ChapterListOptions(
        read: _choice(value['read'], ['all', 'read', 'unread']),
        download: _choice(value['download'], ['all', 'downloaded', 'online']),
        bookmarked: _choice(value['bookmarked'], ['all', 'yes', 'no']),
        sort:
            ChapterSort.values
                .where((v) => v.name == value['sort'])
                .firstOrNull ??
            ChapterSort.source,
        descending: value['descending'] == true,
        hideDuplicates: value['hideDuplicates'] == true,
        preferredScanlator: value['preferredScanlator'] as String? ?? '',
        scanlator: value['scanlator'] as String? ?? '',
        excludedScanlators: (value['excludedScanlators'] as List? ?? [])
            .whereType<String>()
            .toList(),
      );

  Map<String, dynamic> toJson() => {
    'read': read,
    'download': download,
    'bookmarked': bookmarked,
    'sort': sort.name,
    'descending': descending,
    'hideDuplicates': hideDuplicates,
    'preferredScanlator': preferredScanlator,
    'scanlator': scanlator,
    'excludedScanlators': excludedScanlators,
  };

  ChapterListOptions patch(Map<String, dynamic> changes) =>
      ChapterListOptions.fromJson({...toJson(), ...changes});

  List<int> indices(LibraryBook book, {String query = ''}) {
    final q = query.trim().toLowerCase();
    var result = [
      for (var i = 0; i < book.chapters.length; i++)
        if ((q.isEmpty || book.chapters[i].title.toLowerCase().contains(q)) &&
            (read == 'all' || (read == 'read') == chapterIsRead(book, i)) &&
            (download == 'all' ||
                (download == 'downloaded') == book.chapters[i].downloaded) &&
            (bookmarked == 'all' ||
                (bookmarked == 'yes') == chapterHasBookmark(book, i)) &&
            (scanlator.isEmpty || book.chapters[i].scanlator == scanlator) &&
            !excludedScanlators.contains(book.chapters[i].scanlator))
          i,
    ];
    if (hideDuplicates) {
      final groups = <String, List<int>>{};
      for (final i in result) {
        // Missing/negative/NaN numbers are kept individually; never guess from titles.
        final number = validChapterNumber(book.chapters[i]);
        final key = number == null
            ? 'id:${book.chapters[i].id}:$i'
            : 'number:$number';
        (groups[key] ??= []).add(i);
      }
      result = [for (final group in groups.values) _preferred(book, group)];
    }
    result.sort((a, b) {
      int comparison;
      switch (sort) {
        case ChapterSort.source:
          comparison = a.compareTo(b);
        case ChapterSort.title:
          comparison = book.chapters[a].title.toLowerCase().compareTo(
            book.chapters[b].title.toLowerCase(),
          );
        case ChapterSort.number:
          final an = validChapterNumber(book.chapters[a]),
              bn = validChapterNumber(book.chapters[b]);
          // Unknown chapter numbers stay at the end in both directions.
          if (an == null || bn == null) {
            return an == bn ? a.compareTo(b) : (an == null ? 1 : -1);
          }
          comparison = an.compareTo(bn);
      }
      if (comparison == 0) comparison = a.compareTo(b);
      return descending ? -comparison : comparison;
    });
    return result;
  }

  int _preferred(LibraryBook book, List<int> indices) {
    final ordered = [...indices]
      ..sort((a, b) {
        final ap =
            preferredScanlator.isNotEmpty &&
            book.chapters[a].scanlator == preferredScanlator;
        final bp =
            preferredScanlator.isNotEmpty &&
            book.chapters[b].scanlator == preferredScanlator;
        if (ap != bp) return ap ? -1 : 1;
        if (book.chapters[a].downloaded != book.chapters[b].downloaded) {
          return book.chapters[a].downloaded ? -1 : 1;
        }
        if (chapterHasBookmark(book, a) != chapterHasBookmark(book, b)) {
          return chapterHasBookmark(book, a) ? -1 : 1;
        }
        return a.compareTo(b);
      });
    return ordered.first;
  }
}

String _choice(Object? value, List<String> values) =>
    values.contains(value) ? value as String : values.first;
double? validChapterNumber(BookChapter chapter) =>
    chapter.number != null && chapter.number!.isFinite && chapter.number! >= 0
    ? chapter.number
    : null;
bool chapterHasBookmark(LibraryBook book, int index) =>
    book.bookmarks.any((mark) => int.tryParse(mark.split(':').first) == index);

Set<int> duplicateChapterIndices(LibraryBook book) {
  final groups = <double, List<int>>{};
  for (final (i, chapter) in book.chapters.indexed) {
    final number = validChapterNumber(chapter);
    if (number != null) (groups[number] ??= []).add(i);
  }
  return {
    for (final group in groups.values)
      if (group.length > 1) ...group,
  };
}
