import 'dart:convert';

class BookReadingTimes {
  BookReadingTimes([Map<String, int> seconds = const {}])
    : seconds = Map.unmodifiable(seconds);
  static const preferenceKey = 'bookReadingTimesV1';
  final Map<String, int> seconds;

  factory BookReadingTimes.decode(String? raw) {
    if (raw == null) return BookReadingTimes();
    final data = jsonDecode(raw);
    if (data is! Map<String, dynamic> ||
        data.length > 10000 ||
        data.entries.any(
          (entry) =>
              entry.key.isEmpty ||
              entry.key.length > 4096 ||
              entry.value is! int ||
              entry.value < 0 ||
              entry.value > 9007199254740991,
        )) {
      throw const FormatException('Thời gian đọc từng truyện không hợp lệ.');
    }
    return BookReadingTimes(data.cast<String, int>());
  }

  int of(String bookId) => seconds[bookId] ?? 0;
  String encode() => jsonEncode(seconds);
}

String readingDurationLabel(int seconds) {
  if (seconds <= 0) return 'Chưa ghi nhận';
  if (seconds < 60) return '$seconds giây';
  final minutes = seconds ~/ 60;
  if (minutes < 60) return '$minutes phút';
  return '${minutes ~/ 60} giờ ${minutes % 60} phút';
}
