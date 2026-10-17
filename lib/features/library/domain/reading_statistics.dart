import 'dart:convert';

import '../data/backup_compatibility/mihon_tracking.dart';
import '../data/backup_compatibility/protobuf_reader.dart';
import 'library_book.dart';
import 'library_reading.dart';
import 'book_reading_times.dart';

class ReadingStatistics {
  ReadingStatistics(
    Iterable<LibraryBook> values, {
    Map<String, Set<int>>? cachedChapters,
    BookReadingTimes? readingTimes,
  }) : books = List.unmodifiable(values),
       readingTimes = readingTimes ?? BookReadingTimes(),
       cachedChapters = cachedChapters == null
           ? null
           : Map.unmodifiable(
               cachedChapters.map(
                 (id, chapters) =>
                     MapEntry(id, Set<int>.unmodifiable(chapters)),
               ),
             );
  final List<LibraryBook> books;
  final BookReadingTimes readingTimes;
  int readingSecondsOf(LibraryBook book) => readingTimes.of(book.id);
  List<LibraryBook> get longestReadBooks =>
      sortedBooks(ReadingStatisticsOrder.duration)
          .where((book) => readingSecondsOf(book) > 0)
          .take(20)
          .toList();

  List<LibraryBook> sortedBooks(ReadingStatisticsOrder order) {
    final result = books.toList()
      ..sort((a, b) {
        final compared = switch (order) {
          ReadingStatisticsOrder.duration => readingSecondsOf(
            b,
          ).compareTo(readingSecondsOf(a)),
          ReadingStatisticsOrder.title => a.title.toLowerCase().compareTo(
            b.title.toLowerCase(),
          ),
          ReadingStatisticsOrder.chapters => readChapterCount(
            b,
          ).compareTo(readChapterCount(a)),
          ReadingStatisticsOrder.recent =>
            (b.lastRead ?? DateTime(0)).compareTo(a.lastRead ?? DateTime(0)),
        };
        if (compared != 0) return compared;
        final title = a.title.toLowerCase().compareTo(b.title.toLowerCase());
        return title != 0 ? title : a.id.compareTo(b.id);
      });
    return List.unmodifiable(result);
  }

  /// Null preserves the legacy metadata-only counter. Screens supply verified
  /// cached contents, so a downloaded flag alone cannot claim offline access.
  final Map<String, Set<int>>? cachedChapters;
  bool get cacheVerified => cachedChapters != null;
  int get chapters => books.fold(0, (sum, book) => sum + book.chapters.length);
  int get read => books.fold(0, (sum, book) => sum + readChapterCount(book));
  int get unread => chapters - read;
  int get downloaded =>
      books.fold(0, (sum, book) => sum + downloadedChapterCount(book));
  int downloadedChapterCount(LibraryBook book) => cachedChapters == null
      ? book.chapters.where((chapter) => chapter.downloaded).length
      : (cachedChapters![book.id] ?? const <int>{})
            .where((index) => index >= 0 && index < book.chapters.length)
            .length;
  int get offlineBooks =>
      books.where((book) => downloadedChapterCount(book) > 0).length;
  int get completed => _stateCount('completed');
  int get inProgress => _stateCount('reading');
  int get paused => _stateCount('paused');
  int get planned => _stateCount('planned');
  int get notStarted => planned;
  int _stateCount(String state) =>
      books.where((book) => readingStateOf(book) == state).length;
  int get favorites => books.where((book) => book.favorite).length;
  int get bookmarks =>
      books.fold(0, (sum, book) => sum + book.bookmarks.length);
  double get progress => chapters == 0 ? 0 : read / chapters;
  double progressOf(LibraryBook book) =>
      book.chapters.isEmpty ? 0 : readChapterCount(book) / book.chapters.length;
  Map<String, int> get readingStates => {
    'Dự định đọc': planned,
    'Đang đọc': inProgress,
    'Tạm dừng': paused,
    'Đã hoàn thành': completed,
  };
  Map<String, int> get progressGroups => {
    'Chưa đọc chương nào': books.where((book) => progressOf(book) == 0).length,
    'Dưới 50%': books
        .where((book) => progressOf(book) > 0 && progressOf(book) < .5)
        .length,
    'Từ 50% đến dưới 100%': books
        .where((book) => progressOf(book) >= .5 && progressOf(book) < 1)
        .length,
    'Đã đọc tất cả chương': books
        .where((book) => book.chapters.isNotEmpty && progressOf(book) == 1)
        .length,
  };
  int get ratedBooks => _ratings.length;
  List<double> get _ratings => books
      .map((book) => book.rating)
      .whereType<double>()
      .where((score) => score.isFinite && score >= 0 && score <= 10)
      .toList();
  double? get averageRating {
    final values = _ratings;
    return values.isEmpty
        ? null
        : values.reduce((left, right) => left + right) / values.length;
  }

  List<LibraryBook> recentBooks(DateTime now, {int limit = 20}) {
    final values =
        books
            .where(
              (book) => book.lastRead != null && !book.lastRead!.isAfter(now),
            )
            .toList()
          ..sort((left, right) {
            final date = right.lastRead!.compareTo(left.lastRead!);
            return date == 0 ? left.id.compareTo(right.id) : date;
          });
    return List.unmodifiable(values.take(limit));
  }

  List<LibraryBook> get mostReadBooks {
    final values = books.where((book) => readChapterCount(book) > 0).toList()
      ..sort((left, right) {
        final count = readChapterCount(right).compareTo(readChapterCount(left));
        return count == 0 ? left.id.compareTo(right.id) : count;
      });
    return List.unmodifiable(values.take(20));
  }

  Map<String, int> get trackers => _counts(trackerServicesOf);
  int get trackedBooks =>
      books.where((book) => trackerServicesOf(book).isNotEmpty).length;
  Map<String, int> get sources {
    final counts = <String, int>{};
    final names = <String, String>{};
    for (final book in books) {
      final identity = book.engine == 'local'
          ? 'local'
          : '${book.engine} · ${book.sourceId}';
      counts.update(identity, (value) => value + 1, ifAbsent: () => 1);
      final name = book.sourceName.trim();
      if (name.isNotEmpty &&
          (names[identity] == null || name.compareTo(names[identity]!) < 0)) {
        names[identity] = name;
      }
    }
    return _sortedCounts({
      for (final entry in counts.entries)
        entry.key == 'local'
                ? 'Truyện cục bộ'
                : names[entry.key] == null
                ? entry.key
                : '${names[entry.key]} · ${entry.key}':
            entry.value,
    });
  }

  Map<String, int> get categories => _counts(
    (book) => book.categories.isEmpty ? ['Chưa có danh mục'] : book.categories,
  );
  Map<String, int> _counts(Iterable<String> Function(LibraryBook) keys) {
    final result = <String, int>{};
    for (final book in books) {
      for (final key in keys(book).toSet()) {
        result.update(key, (count) => count + 1, ifAbsent: () => 1);
      }
    }
    return _sortedCounts(result);
  }

  Map<String, int> _sortedCounts(Map<String, int> result) {
    final entries = result.entries.toList()
      ..sort((a, b) {
        final count = b.value.compareTo(a.value);
        return count == 0 ? a.key.compareTo(b.key) : count;
      });
    return Map.fromEntries(entries);
  }
}

enum ReadingStatisticsOrder {
  duration('Thời lượng đọc nhiều nhất'),
  title('Tên truyện'),
  chapters('Số chương đã đọc nhiều nhất'),
  recent('Đọc gần đây');

  const ReadingStatisticsOrder(this.label);
  final String label;
}

String readingStateOf(LibraryBook book) {
  if (book.completed || book.readingState == 'completed') return 'completed';
  if (['planned', 'reading', 'paused'].contains(book.readingState)) {
    return book.readingState;
  }
  return bookHasReadingProgress(book) ? 'reading' : 'planned';
}

String readingStateLabel(String state) => switch (state) {
  'reading' => 'Đang đọc',
  'paused' => 'Tạm dừng',
  'completed' => 'Đã hoàn thành',
  _ => 'Dự định đọc',
};

/// Decode only the verified BackupTracking envelope. The opaque original bytes
/// stay unchanged and no tracker, credential, URL or source memo is executed.
Set<String> trackerServicesOf(LibraryBook book) {
  final result = <String>{};
  for (final encoded
      in book.externalBackupMetadata?.tracking ?? const <String>[]) {
    try {
      final bytes = base64Decode(encoded);
      validateMihonTracking(bytes);
      final id = ProtoMessage(bytes).integer(1, required: true).toInt();
      result.add(_trackerNames[id] ?? 'Dịch vụ #$id');
    } on FormatException {
      // Preserve and report imported opaque records that cannot be interpreted.
      result.add('Dịch vụ chưa nhận diện');
    }
  }
  return result;
}

// IDs from the pinned official Mihon v0.20.4 TrackerManager source.
const _trackerNames = {
  1: 'MyAnimeList',
  2: 'AniList',
  3: 'Kitsu',
  4: 'Shikimori',
  5: 'Bangumi',
  6: 'Komga',
  7: 'MangaUpdates',
  8: 'Kavita',
  9: 'Suwayomi',
  10: 'Hikka',
  11: 'MangaBaka',
};

class RecordedReadingTime {
  RecordedReadingTime(Map<String, Object?> preferences, {required DateTime now})
    : today = DateTime(now.year, now.month, now.day) {
    for (final entry in preferences.entries) {
      if (!entry.key.startsWith('readSeconds:')) continue;
      final match = RegExp(r'^readSeconds:(\d{4})-(\d{1,2})-(\d{1,2})$')
          .firstMatch(entry.key);
      if (match == null || entry.value is! int || (entry.value as int) < 0) {
        ignoredRecords++;
        continue;
      }
      final year = int.parse(match[1]!);
      final month = int.parse(match[2]!);
      final day = int.parse(match[3]!);
      final date = DateTime(year, month, day);
      if (date.year != year ||
          date.month != month ||
          date.day != day ||
          date.isAfter(today)) {
        ignoredRecords++;
        continue;
      }
      // A canonical and a zero-padded key can represent the same day. Add their
      // recorded durations; never replace one silently or manufacture a session.
      _seconds.update(
        date,
        (value) => value + (entry.value as int),
        ifAbsent: () => entry.value as int,
      );
    }
  }
  final DateTime today;
  final Map<DateTime, int> _seconds = {};
  int ignoredRecords = 0;
  int onDay(DateTime day) =>
      _seconds[DateTime(day.year, day.month, day.day)] ?? 0;
  int get totalSeconds => _seconds.values.fold(0, (sum, next) => sum + next);
  int get todaySeconds => onDay(today);
  int recentSeconds(int days) =>
      daysBack(days).fold(0, (sum, day) => sum + onDay(day));
  List<DateTime> daysBack(int days) => List.unmodifiable([
    for (var offset = days - 1; offset >= 0; offset--)
      DateTime(today.year, today.month, today.day - offset),
  ]);
}
