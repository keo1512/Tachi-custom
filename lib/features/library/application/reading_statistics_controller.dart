import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/library_mutation.dart';
import '../data/library_repository.dart';
import '../domain/reading_statistics.dart';
import '../domain/book_reading_times.dart';
import '../../settings/settings_controller.dart';
import 'backup_service_provider.dart';
import '../presentation/library_view_model.dart';

final readingStatisticsClockProvider = Provider<DateTime Function()>(
  (_) => DateTime.now,
);

final readingStatisticsProvider = FutureProvider.autoDispose<ReadingStatistics>((
  ref,
) async {
  // Library refreshes invalidate this view, including download, restore and
  // reading changes. One consistent snapshot supplies both metadata and cache.
  ref.watch(libraryProvider);
  ref.watch(configurationChangesProvider);
  final snapshot = await ref.read(libraryRepositoryProvider).snapshot();
  final cached = <String, Set<int>>{};
  for (final entry in snapshot.entries) {
    final available = <int>{};
    for (final content in entry.contents.entries) {
      try {
        checkChapterContent(entry.book, content.value);
        if (chapterIsOffline(content.value)) available.add(content.key);
      } on StateError {
        // Keep corrupt/partial content for diagnostics, but do not count it as
        // an available offline chapter just because its flag says downloaded.
      } on FormatException {
        // No metadata or stored bytes are changed by statistics.
      }
    }
    cached[entry.book.id] = available;
  }
  return ReadingStatistics(
    snapshot.entries.map((entry) => entry.book),
    cachedChapters: cached,
    readingTimes: BookReadingTimes.decode(
      ref.read(preferencesProvider).getString(BookReadingTimes.preferenceKey),
    ),
  );
});

class ReadingStatisticsEditor {
  ReadingStatisticsEditor(this.repository);
  final LibraryRepository repository;

  Future<void> setReadingState(
    String id,
    String state, {
    required int expectedRevision,
    void Function()? guard,
  }) async {
    if (!['planned', 'reading', 'paused', 'completed'].contains(state)) {
      throw const FormatException('Trạng thái đọc không hợp lệ.');
    }
    guard?.call();
    final saved = await repository.mutateBook(id, (latest) {
      guard?.call();
      return latest.copyWith(
        readingState: state,
        completed: state == 'completed',
      );
    }, expectedRevision: expectedRevision);
    if (saved == null) throw StateError('Truyện không còn trong thư viện.');
  }

  Future<void> setRating(
    String id,
    double? rating, {
    required int expectedRevision,
    void Function()? guard,
  }) async {
    if (rating != null && (!rating.isFinite || rating < 0 || rating > 10)) {
      throw const FormatException('Điểm đánh giá phải từ 0 đến 10.');
    }
    guard?.call();
    final saved = await repository.mutateBook(id, (latest) {
      guard?.call();
      return latest.copyWith(rating: rating, clearRating: rating == null);
    }, expectedRevision: expectedRevision);
    if (saved == null) throw StateError('Truyện không còn trong thư viện.');
  }
}
