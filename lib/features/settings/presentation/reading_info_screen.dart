import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/widgets/feedback.dart';
import '../../library/presentation/library_view_model.dart';
import '../settings_controller.dart';
import 'settings_widgets.dart';

class ReadingInfoScreen extends ConsumerStatefulWidget {
  const ReadingInfoScreen({super.key});

  @override
  ConsumerState<ReadingInfoScreen> createState() => _ReadingInfoState();
}

class _ReadingInfoState extends ConsumerState<ReadingInfoScreen> {
  late int goal;

  @override
  void initState() {
    super.initState();
    goal = (ref.read(preferencesProvider).getInt('readingGoalMinutes') ?? 20)
        .clamp(5, 120);
  }

  int secondsOn(DateTime day) =>
      ref
          .read(preferencesProvider)
          .getInt('readSeconds:${day.year}-${day.month}-${day.day}') ??
      0;

  Future<void> saveGoal(double value) => perform(context, () async {
    final saved = await ref
        .read(preferencesProvider)
        .setInt('readingGoalMinutes', value.round());
    if (!saved) throw StateError('Không lưu được mục tiêu đọc.');
  });

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final todaySeconds = secondsOn(today);
    var weekSeconds = 0;
    for (var index = 0; index < 7; index++) {
      weekSeconds += secondsOn(today.subtract(Duration(days: index)));
    }
    final preferences = ref.read(preferencesProvider);
    final totalSeconds = preferences
        .getKeys()
        .where((key) => key.startsWith('readSeconds:'))
        .fold<int>(0, (sum, key) => sum + (preferences.getInt(key) ?? 0));
    final books = ref.watch(libraryProvider);
    return SettingsPage(
      title: 'Thông tin Đọc',
      children: [
        const SettingsHeading('Thời gian đọc'),
        SettingsRow(
          title: 'Hôm nay',
          icon: CupertinoIcons.clock,
          trailing: Text('${todaySeconds ~/ 60} phút'),
        ),
        SettingsRow(
          title: '7 ngày qua',
          trailing: Text('${weekSeconds ~/ 60} phút'),
        ),
        SettingsRow(
          title: 'Tổng thời gian',
          trailing: Text('${totalSeconds ~/ 60} phút'),
        ),
        const SettingsNote(
          'Thời gian được ghi khi reader đang ở màn hình trước. Dữ liệu này nằm trên thiết bị và không được đồng bộ tài khoản.',
        ),
        const Divider(height: 24, thickness: .5),
        const SettingsHeading('Mục tiêu đọc mỗi ngày'),
        SettingsRow(
          title: '$goal phút',
          icon: CupertinoIcons.flag,
          trailing: Text(
            '${(todaySeconds / (goal * 60) * 100).clamp(0, 100).round()}%',
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: LinearProgressIndicator(
            value: (todaySeconds / (goal * 60)).clamp(0, 1),
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
        const SettingsNote(
          'Mục tiêu từ 5 đến 120 phút, được lưu trên thiết bị.',
        ),
        const Divider(height: 24, thickness: .5),
        const SettingsHeading('Thư viện'),
        books.when(
          loading: () => const Padding(
            padding: EdgeInsets.all(16),
            child: CupertinoActivityIndicator(),
          ),
          error: (error, _) => SettingsNote('$error'),
          data: (values) => Column(
            children: [
              SettingsRow(
                title: 'Sách và truyện',
                trailing: Text('${values.length}'),
              ),
              SettingsRow(
                title: 'Đã hoàn thành',
                trailing: Text(
                  '${values.where((book) => book.completed).length}',
                ),
              ),
              SettingsRow(
                title: 'Dấu trang',
                trailing: Text(
                  '${values.fold<int>(0, (sum, book) => sum + book.bookmarks.length)}',
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
