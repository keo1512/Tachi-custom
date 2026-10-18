import 'dart:convert';

/// Recorded local calendar dates -> book ID -> measured seconds. This never
/// derives per-book history from older aggregate day/book totals.
class BookDailyReadingTimes {
  BookDailyReadingTimes([Map<String, Map<String, int>> days = const {}])
    : days = Map.unmodifiable({
        for (final entry in days.entries)
          entry.key: Map<String, int>.unmodifiable(entry.value),
      });
  static const preferenceKey = 'bookDailyReadingTimesV1';
  final Map<String, Map<String, int>> days;

  static String dayKey(DateTime date) =>
      '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';

  factory BookDailyReadingTimes.decode(String? raw) {
    if (raw == null) return BookDailyReadingTimes();
    if (utf8.encode(raw).length > 2 * 1024 * 1024) {
      throw const FormatException('Thời lượng đọc theo ngày vượt giới hạn.');
    }
    final value = jsonDecode(raw);
    if (value is! Map<String, dynamic> || value.length > 10000) {
      throw const FormatException('Thời lượng đọc theo ngày không hợp lệ.');
    }
    final days = <String, Map<String, int>>{};
    var count = 0;
    for (final entry in value.entries) {
      final date = DateTime.tryParse(entry.key);
      if (date == null ||
          dayKey(date) != entry.key ||
          entry.value is! Map<String, dynamic>) {
        throw const FormatException('Ngày đọc truyện không hợp lệ.');
      }
      final books = <String, int>{};
      for (final book in (entry.value as Map<String, dynamic>).entries) {
        if (book.key.isEmpty ||
            book.key.length > 4096 ||
            book.value is! int ||
            book.value < 0 ||
            book.value > 9007199254740991 ||
            ++count > 100000) {
          throw const FormatException(
            'Thời lượng đọc theo truyện không hợp lệ.',
          );
        }
        books[book.key] = book.value as int;
      }
      days[entry.key] = books;
    }
    return BookDailyReadingTimes(days);
  }

  String encode() => jsonEncode(days);
  int onDay(String bookId, DateTime day) => days[dayKey(day)]?[bookId] ?? 0;
  int totalOf(String bookId, {DateTime? through}) => days.entries
      .where(
        (entry) =>
            through == null ||
            !DateTime.parse(entry.key)
                .isAfter(DateTime(through.year, through.month, through.day)),
      )
      .fold(0, (sum, entry) => sum + (entry.value[bookId] ?? 0));

  static Map<String, int> sessionDays(DateTime start, DateTime end) {
    final total = end.difference(start).inSeconds;
    if (total <= 0) return {};
    final result = <String, int>{};
    var cursor = start, assigned = 0;
    var dayCount = 0;
    while (cursor.isBefore(end)) {
      if (++dayCount > 10000) {
        throw const FormatException('Phiên đọc vượt giới hạn số ngày.');
      }
      final midnight = cursor.isUtc
          ? DateTime.utc(cursor.year, cursor.month, cursor.day + 1)
          : DateTime(cursor.year, cursor.month, cursor.day + 1);
      final until = end.isBefore(midnight) ? end : midnight;
      // Keep the total of integer seconds identical across the three indexes,
      // including a session with fractional seconds around midnight.
      final seconds = until == end
          ? total - assigned
          : until.difference(cursor).inSeconds;
      if (seconds > 0) result[dayKey(cursor)] = seconds;
      assigned += seconds;
      cursor = until;
    }
    return result;
  }

  BookDailyReadingTimes record(String bookId, DateTime start, DateTime end) {
    final next = {
      for (final entry in days.entries) entry.key: {...entry.value},
    };
    for (final entry in sessionDays(start, end).entries) {
      final books = next.putIfAbsent(entry.key, () => {});
      books[bookId] = (books[bookId] ?? 0) + entry.value;
    }
    return BookDailyReadingTimes.decode(BookDailyReadingTimes(next).encode());
  }

  BookDailyReadingTimes migrateBookIds(
    Map<String, String> ids, {
    required bool replaceOld,
  }) {
    if (!replaceOld) return this;
    final next = <String, Map<String, int>>{};
    for (final day in days.entries) {
      final books = {...day.value};
      for (final entry in ids.entries) {
        if (entry.key == entry.value || !day.value.containsKey(entry.key)) {
          continue;
        }
        books[entry.value] = (books[entry.value] ?? 0) + day.value[entry.key]!;
        books.remove(entry.key);
      }
      next[day.key] = books;
    }
    return BookDailyReadingTimes.decode(BookDailyReadingTimes(next).encode());
  }
}
