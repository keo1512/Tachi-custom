import 'package:flutter/material.dart';

import '../../library/domain/reading_statistics.dart';

class ReadingCountChart extends StatelessWidget {
  const ReadingCountChart({super.key, required this.values});
  final Map<String, int> values;

  @override
  Widget build(BuildContext context) {
    final total = values.values.fold<int>(0, (sum, count) => sum + count);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Column(
        children: [
          for (final entry in values.entries)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Semantics(
                label: '${entry.key}: ${entry.value} truyện',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('${entry.key} · ${entry.value}'),
                    const SizedBox(height: 5),
                    LinearProgressIndicator(
                      value: total == 0 ? 0 : entry.value / total,
                      minHeight: 6,
                      borderRadius: BorderRadius.circular(3),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class ReadingTimeChart extends StatelessWidget {
  const ReadingTimeChart({super.key, required this.time, required this.days});
  final RecordedReadingTime time;
  final int days;

  @override
  Widget build(BuildContext context) {
    final dates = time.daysBack(days);
    final seconds = dates.map(time.onDay).toList();
    final maximum = seconds.fold<int>(
      60,
      (value, next) => next > value ? next : value,
    );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: SizedBox(
        height: 135 + MediaQuery.textScalerOf(context).scale(14) * 2,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            for (var index = 0; index < dates.length; index++)
              Expanded(
                child: Tooltip(
                  message:
                      '${dates[index].day}/${dates[index].month}: ${seconds[index]} giây',
                  child: Semantics(
                    label:
                        '${dates[index].day}/${dates[index].month}: ${seconds[index]} giây đọc',
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        if (days == 7)
                          Text(
                            '${seconds[index] ~/ 60}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 11),
                          ),
                        SizedBox(
                          height: 90,
                          child: Align(
                            alignment: Alignment.bottomCenter,
                            child: FractionallySizedBox(
                              widthFactor: .68,
                              child: Container(
                                height: seconds[index] / maximum * 90,
                                decoration: BoxDecoration(
                                  color: Theme.of(context).colorScheme.primary,
                                  borderRadius: const BorderRadius.vertical(
                                    top: Radius.circular(3),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 5),
                        SizedBox(
                          height: 24,
                          child:
                              days == 7 ||
                                  index % 5 == 0 ||
                                  index == dates.length - 1
                              ? Text(
                                  '${dates[index].day}',
                                  style: const TextStyle(fontSize: 10),
                                )
                              : null,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
