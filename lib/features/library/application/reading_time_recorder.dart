import 'package:shared_preferences/shared_preferences.dart';

import '../data/backup_configuration.dart';
import '../data/coordinated_preferences.dart';
import '../domain/book_daily_reading_times.dart';
import '../domain/book_reading_times.dart';

/// Called inside the existing LibraryPreferenceWrites session queue. All three
/// duration indexes are one coordinated portable update, never inferred history.
Future<void> recordReadingTime(
  SharedPreferences preferences, {
  required String bookId,
  required DateTime start,
  required DateTime end,
  required bool Function() isCurrent,
}) async {
  if (!isCurrent() || end.difference(start).inSeconds <= 0) return;
  Map<String, Object> changes(Map<String, Object> previous) {
    final seconds = end.difference(start).inSeconds;
    final totals = BookReadingTimes.decode(
      previous[BookReadingTimes.preferenceKey] as String?,
    );
    final days = BookDailyReadingTimes.decode(
      previous[BookDailyReadingTimes.preferenceKey] as String?,
    );
    final patch = <String, Object>{
      BookReadingTimes.preferenceKey: BookReadingTimes.decode(
        BookReadingTimes({
          ...totals.seconds,
          bookId: totals.of(bookId) + seconds,
        }).encode(),
      ).encode(),
      BookDailyReadingTimes.preferenceKey: days
          .record(bookId, start, end)
          .encode(),
    };
    for (final entry in BookDailyReadingTimes.sessionDays(start, end).entries) {
      final day = DateTime.parse(entry.key);
      final key = 'readSeconds:${day.year}-${day.month}-${day.day}';
      patch[key] = (previous[key] as int? ?? 0) + entry.value;
    }
    return patch;
  }

  if (preferences is CoordinatedPreferences) {
    final saved = await preferences.updatePortableValuesIfCurrent(
      (current) => changes(current.values),
      isCurrent,
    );
    if (!saved) throw StateError('Không lưu được thời lượng đọc.');
    return;
  }
  // Legacy/plain stores keep the public SharedPreferences contract. Production
  // uses CoordinatedPreferences; this fallback still rolls failed setters back.
  final current = BackupConfiguration.capture(preferences);
  final patch = changes(current.values);
  BackupConfiguration.fromJson({
    'version': 1,
    'preferences': {...current.values, ...patch},
  });
  final before = {for (final key in patch.keys) key: preferences.get(key)};
  final attempted = <String>[];
  try {
    for (final entry in patch.entries) {
      if (!isCurrent()) {
        throw StateError('Phiên đọc đã thay đổi trong khi lưu.');
      }
      attempted.add(entry.key);
      final saved = entry.value is String
          ? await preferences.setString(entry.key, entry.value as String)
          : await preferences.setInt(entry.key, entry.value as int);
      if (!saved) throw StateError('Không lưu được thời lượng đọc.');
    }
    if (!isCurrent()) throw StateError('Phiên đọc đã thay đổi trong khi lưu.');
  } catch (_) {
    for (final key in attempted.reversed) {
      final value = before[key];
      // A changed value belongs to a newer writer; never restore over it.
      if (preferences.get(key) != patch[key]) continue;
      final restored = value == null
          ? await preferences.remove(key)
          : value is String
          ? await preferences.setString(key, value)
          : await preferences.setInt(key, value as int);
      if (!restored) {
        throw StateError('Cần mở lại ứng dụng để kiểm tra thời lượng đọc.');
      }
    }
    rethrow;
  }
}
