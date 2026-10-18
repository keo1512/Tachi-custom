import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/widgets/feedback.dart';
import '../../../core/widgets/book_cover.dart';
import '../../library/application/reading_statistics_controller.dart';
import '../../library/domain/library_book.dart';
import '../../library/domain/library_reading.dart';
import '../../library/domain/reading_statistics.dart';
import '../../library/domain/book_reading_times.dart';
import '../../sources/presentation/source_cover_image.dart';
import '../settings_controller.dart';
import 'reading_statistics_book_list.dart';
import 'reading_statistics_charts.dart';
import 'settings_widgets.dart';

class ReadingInfoScreen extends ConsumerStatefulWidget {
  const ReadingInfoScreen({super.key, this.title = 'Thông tin Đọc'});
  final String title;
  @override
  ConsumerState<ReadingInfoScreen> createState() => _ReadingInfoState();
}

class _ReadingInfoState extends ConsumerState<ReadingInfoScreen> {
  late int goal;
  int chartDays = 7;
  @override
  void initState() {
    super.initState();
    goal = (ref.read(preferencesProvider).getInt('readingGoalMinutes') ?? 20)
        .clamp(5, 120);
  }

  Future<void> saveGoal(double value) => perform(context, () async {
    final saved = await ref
        .read(preferencesProvider)
        .setInt('readingGoalMinutes', value.round());
    if (!saved) throw StateError('Không lưu được mục tiêu đọc.');
  });

  @override
  Widget build(BuildContext context) {
    final now = ref.read(readingStatisticsClockProvider)();
    final preferences = ref.read(preferencesProvider);
    final time = RecordedReadingTime({
      for (final key in preferences.getKeys()) key: preferences.get(key),
    }, now: now);
    final statistics = ref.watch(readingStatisticsProvider);
    return SettingsPage(
      title: widget.title,
      children: [
        SettingsRow(
          title: 'Làm mới thống kê',
          icon: CupertinoIcons.refresh,
          onTap: () {
            ref.invalidate(readingStatisticsProvider);
            setState(() {});
          },
        ),
        const SettingsHeading('Thời gian đọc'),
        _count('Hôm nay', '${time.todaySeconds ~/ 60} phút'),
        _count('7 ngày qua', '${time.recentSeconds(7) ~/ 60} phút'),
        _count('30 ngày qua', '${time.recentSeconds(30) ~/ 60} phút'),
        _count('Tổng thời gian', '${time.totalSeconds ~/ 60} phút'),
        const SettingsNote(
          'Chỉ tính thời gian reader đang ở màn hình trước và phiên đọc không ẩn danh. '
          'Mở thống kê từng truyện để xem các ngày đọc đã ghi cùng mã truyện. '
          'Số liệu lịch sử thiếu mã truyện không được tự phân bổ. '
          'Thời gian và mục tiêu được mang theo trong sao lưu/đồng bộ TachiBooks.',
        ),
        if (time.ignoredRecords > 0)
          SettingsNote(
            '${time.ignoredRecords} bản ghi thời gian không hợp lệ hoặc ở tương lai '
            'không được cộng vào thống kê; dữ liệu gốc được giữ nguyên.',
          ),
        const SettingsHeading('Biểu đồ thời gian đọc'),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: CupertinoSlidingSegmentedControl<int>(
            groupValue: chartDays,
            children: const {7: Text('7 ngày'), 30: Text('30 ngày')},
            onValueChanged: (value) {
              if (value != null) setState(() => chartDays = value);
            },
          ),
        ),
        ReadingTimeChart(time: time, days: chartDays),
        if (time.recentSeconds(chartDays) == 0)
          const SettingsNote(
            'Chưa có thời gian đọc được ghi nhận trong khoảng này.',
          ),
        const Divider(height: 24, thickness: .5),
        const SettingsHeading('Mục tiêu đọc mỗi ngày'),
        SettingsRow(
          title: '$goal phút',
          icon: CupertinoIcons.flag,
          trailing: Text(
            '${(time.todaySeconds / (goal * 60) * 100).clamp(0, 100).round()}%',
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: LinearProgressIndicator(
            value: (time.todaySeconds / (goal * 60)).clamp(0, 1),
            minHeight: 3,
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: CupertinoSlider(
            key: const ValueKey('reading-goal-slider'),
            value: goal.toDouble(),
            min: 5,
            max: 120,
            divisions: 23,
            onChanged: (value) => setState(() => goal = value.round()),
            onChangeEnd: saveGoal,
          ),
        ),
        const Divider(height: 24, thickness: .5),
        const SettingsHeading('Thư viện'),
        statistics.when(
          loading: () => const Padding(
            padding: EdgeInsets.all(16),
            child: CupertinoActivityIndicator(),
          ),
          error: (error, _) => SettingsNote(
            'Chưa đọc được dữ liệu thống kê: ${userFacingError(error)} '
            'Hãy kiểm tra thư viện trong Công cụ cơ sở dữ liệu. '
            'Không có dữ liệu nào bị thay đổi.',
          ),
          data: (stats) => _libraryStatistics(stats, now),
        ),
      ],
    );
  }

  Widget _count(String title, String value) =>
      SettingsRow(title: title, trailing: Text(value));

  Widget _libraryStatistics(ReadingStatistics stats, DateTime now) => Column(
    children: [
      _count('Sách và truyện', '${stats.books.length}'),
      _count('Tổng số chương', '${stats.chapters}'),
      _count('Chương đã đọc', '${stats.read}'),
      _count('Chương chưa đọc', '${stats.unread}'),
      _count('Đang đọc', '${stats.inProgress}'),
      _count('Đã hoàn thành', '${stats.completed}'),
      _count('Đang tạm dừng', '${stats.paused}'),
      _count('Dự định đọc', '${stats.planned}'),
      _count('Chương có nội dung offline', '${stats.downloaded}'),
      _count('Truyện có chương offline', '${stats.offlineBooks}'),
      _count('Yêu thích', '${stats.favorites}'),
      _count('Dấu trang', '${stats.bookmarks}'),
      _count('Tiến độ toàn thư viện', '${(stats.progress * 100).round()}%'),
      const SettingsNote(
        'Tiến độ tổng thể tính theo số chương đã đọc trên tổng số chương, '
        'không lấy trung bình các truyện dài/ngắn. Offline được kiểm tra từ nội '
        'dung lưu trên máy; cờ đã tải nhưng thiếu nội dung không được tính.',
      ),
      _count(
        'Điểm đánh giá trung bình',
        stats.averageRating == null
            ? 'Chưa có'
            : '${stats.averageRating!.toStringAsFixed(1)}/10',
      ),
      SettingsNote(
        'Tính từ ${stats.ratedBooks} đánh giá bạn đã lưu theo thang 0–10.',
      ),
      SettingsRow(
        key: const ValueKey('statistics-manage-books'),
        title: 'Trạng thái và đánh giá từng truyện',
        icon: CupertinoIcons.book,
        onTap: () => Navigator.of(context).push<void>(
          CupertinoPageRoute(builder: (_) => const ReadingStatisticsBookList()),
        ),
      ),
      const SettingsHeading('Theo trạng thái đọc'),
      ReadingCountChart(values: stats.readingStates),
      const SettingsHeading('Theo tiến độ chương'),
      ReadingCountChart(values: stats.progressGroups),
      ..._groups('Theo nguồn', stats.sources),
      ..._groups('Theo danh mục', stats.categories),
      const SettingsNote(
        'Một truyện thuộc nhiều danh mục được tính một lần trong từng danh mục.',
      ),
      const SettingsHeading('Thời lượng đọc theo truyện'),
      const SettingsNote(
        'Chỉ tính thời gian đã ghi nhận cho từng truyện. Thời gian tổng từ phiên bản cũ không được tự chia cho các truyện.',
      ),
      if (stats.longestReadBooks.isEmpty)
        const SettingsNote(
          'Chưa có thời lượng theo truyện. Mở và đọc truyện để bắt đầu ghi nhận.',
        ),
      for (final book in stats.longestReadBooks)
        _bookCount(
          book,
          '${stats.longestReadBooks.indexOf(book) + 1}. ${readingDurationLabel(stats.readingSecondsOf(book))}',
        ),
      const SettingsHeading('Đọc nhiều chương nhất'),
      if (stats.mostReadBooks.isEmpty)
        const SettingsNote('Chưa có chương được ghi nhận đã đọc.'),
      for (final book in stats.mostReadBooks)
        _bookCount(
          book,
          '${readChapterCount(book)}/${book.chapters.length} chương đã đọc',
        ),
      const SettingsHeading('Truyện đọc gần đây'),
      if (stats.recentBooks(now).isEmpty)
        const SettingsNote('Chưa có phiên đọc được ghi nhận.'),
      for (final book in stats.recentBooks(now))
        _bookCount(
          book,
          'Đọc gần nhất: ${book.lastRead!.day}/${book.lastRead!.month}/${book.lastRead!.year} '
          '· ${readChapterCount(book)}/${book.chapters.length} chương',
        ),
    ],
  );

  Widget _bookCount(LibraryBook book, String subtitle) => ListTile(
    leading: SizedBox(
      width: 40,
      height: 56,
      child: BookCover(
        title: book.title,
        cover: book.cover,
        kind: book.kind,
        showTitle: false,
        imageProvider: libraryCoverImage(ref, book),
      ),
    ),
    title: Text(book.title),
    subtitle: Text(subtitle),
    trailing: const Icon(CupertinoIcons.chevron_right, size: 16),
    onTap: () => Navigator.of(context).push<void>(
      CupertinoPageRoute(
        builder: (_) => ReadingStatisticsBookList(initialBookId: book.id),
      ),
    ),
  );

  List<Widget> _groups(String title, Map<String, int> values) => [
    SettingsHeading(title),
    if (values.isEmpty) const SettingsNote('Chưa có dữ liệu.'),
    for (final entry in values.entries.take(10))
      _count(entry.key, '${entry.value} truyện'),
    if (values.length > 10)
      SettingsRow(
        title: 'Xem tất cả ${values.length} nhóm',
        onTap: () => Navigator.of(context).push<void>(
          CupertinoPageRoute(
            builder: (_) => Scaffold(
              appBar: AppBar(title: Text(title)),
              body: ListView.builder(
                itemCount: values.length,
                itemBuilder: (_, index) {
                  final entry = values.entries.elementAt(index);
                  return _count(entry.key, '${entry.value} truyện');
                },
              ),
            ),
          ),
        ),
      ),
  ];
}
