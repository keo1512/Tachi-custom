import 'library_book.dart';

class ReleasePrediction {
  const ReleasePrediction({
    required this.next,
    required this.intervalDays,
    required this.samples,
  });
  final DateTime next;
  final int intervalDays, samples;
  static ReleasePrediction? forBook(LibraryBook book) {
    if (book.engine == 'local' || [2, 4, 5].contains(book.status)) return null;
    final dates =
        book.chapters
            .where((c) => c.uploadedAt != null)
            .map((c) {
              final date = c.uploadedAt!.toLocal();
              return DateTime.utc(date.year, date.month, date.day);
            })
            .toSet()
            .toList()
          ..sort();
    if (dates.length < 3) return null;
    final recent = dates
        .skip((dates.length - 7).clamp(0, dates.length))
        .toList();
    final intervals = <int>[];
    for (var i = 1; i < recent.length; i++) {
      final gap = recent[i].difference(recent[i - 1]).inDays;
      if (gap > 90) return null;
      if (gap > 0) intervals.add(gap);
    }
    if (intervals.length < 2) return null;
    intervals.sort();
    final interval = intervals[(intervals.length - 1) ~/ 2];
    // Do not project an apparently irregular or stale series as a precise date.
    if (intervals.last > interval * 3) return null;
    final utc = dates.last.add(Duration(days: interval));
    return ReleasePrediction(
      next: DateTime(utc.year, utc.month, utc.day),
      intervalDays: interval,
      samples: intervals.length,
    );
  }
}
