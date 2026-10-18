import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/format/error_messages.dart';
import '../../library/application/reading_statistics_controller.dart';
import '../../library/domain/book_reading_times.dart';
import 'reading_statistics_charts.dart';
import 'settings_widgets.dart';

class BookReadingTimeScreen extends ConsumerStatefulWidget {
  const BookReadingTimeScreen({
    super.key,
    required this.bookId,
    required this.title,
  });
  final String bookId, title;
  @override
  ConsumerState<BookReadingTimeScreen> createState() => _BookReadingTimeState();
}

class _BookReadingTimeState extends ConsumerState<BookReadingTimeScreen> {
  int days = 7;
  @override
  Widget build(BuildContext context) {
    final statistics = ref.watch(readingStatisticsProvider);
    final now = ref.read(readingStatisticsClockProvider)();
    return SettingsPage(
      title: 'Thời gian từng ngày',
      children: [
        SettingsRow(title: widget.title, icon: CupertinoIcons.book),
        ...statistics.when<List<Widget>>(
          loading: () => [
            const Padding(
              padding: EdgeInsets.all(24),
              child: CupertinoActivityIndicator(),
            ),
          ],
          error: (error, _) => [
            SettingsNote(userFacingError(error)),
            SettingsRow(
              title: 'Thử lại',
              icon: CupertinoIcons.refresh,
              onTap: () => ref.invalidate(readingStatisticsProvider),
            ),
          ],
          data: (stats) {
            final time = stats.timeByDay(widget.bookId, now: now);
            return [
              SettingsRow(
                title: 'Tổng thời lượng đã ghi',
                trailing: Text(
                  readingDurationLabel(stats.readingTimes.of(widget.bookId)),
                ),
              ),
              SettingsRow(
                title: 'Có ngày đọc cụ thể',
                trailing: Text(readingDurationLabel(time.totalSeconds)),
              ),
              Padding(
                padding: const EdgeInsets.all(16),
                child: CupertinoSlidingSegmentedControl<int>(
                  key: const ValueKey('book-time-range'),
                  groupValue: days,
                  children: const {7: Text('7 ngày'), 30: Text('30 ngày')},
                  onValueChanged: (value) {
                    if (value != null) setState(() => days = value);
                  },
                ),
              ),
              SettingsRow(
                title: '$days ngày qua',
                trailing: Text(readingDurationLabel(time.recentSeconds(days))),
              ),
              ReadingTimeChart(time: time, days: days),
              if (time.recentSeconds(days) == 0)
                const SettingsNote(
                  'Chưa có thời lượng đọc theo ngày trong khoảng này.',
                ),
              const SettingsNote(
                'Chỉ tính các phiên đọc được ghi cùng mã truyện và ngày cụ thể. Tổng thời lượng cũ hoặc tổng theo ngày của thư viện không được tự phân bổ vào truyện này.',
              ),
              for (final day in time.daysBack(days).reversed)
                if (time.onDay(day) > 0)
                  SettingsRow(
                    title: '${day.day}/${day.month}/${day.year}',
                    trailing: Text(readingDurationLabel(time.onDay(day))),
                  ),
            ];
          },
        ),
      ],
    );
  }
}
