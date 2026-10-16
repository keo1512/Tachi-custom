import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../domain/library_book.dart';
import '../domain/release_prediction.dart';
import 'library_view_model.dart';
import 'library_locations.dart';

class UpcomingScreen extends ConsumerStatefulWidget {
  const UpcomingScreen({super.key});
  @override
  ConsumerState<UpcomingScreen> createState() => _UpcomingState();
}

class _UpcomingState extends ConsumerState<UpcomingScreen> {
  DateTime month = DateTime(DateTime.now().year, DateTime.now().month),
      selected = DateTime.now();
  String? category;
  bool sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;
  @override
  Widget build(BuildContext context) {
    final books = ref.watch(libraryProvider).value ?? <LibraryBook>[];
    final predictions = {
      for (final b in books)
        if (category == null || b.categories.contains(category))
          b: ReleasePrediction.forBook(b),
    };
    final days = DateTime(month.year, month.month + 1, 0).day;
    final offset = (month.weekday - 1) % 7;
    final selectedBooks = predictions.entries
        .where((e) => e.value != null && sameDay(e.value!.next, selected))
        .toList();
    return Scaffold(
      appBar: AppBar(title: const Text('Lịch chương dự kiến')),
      body: ListView(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: DropdownButtonFormField<String>(
              initialValue: category ?? '',
              decoration: const InputDecoration(labelText: 'Danh mục'),
              items: [
                const DropdownMenuItem(value: '', child: Text('Tất cả')),
                for (final name
                    in (books.expand((b) => b.categories).toSet().toList()
                      ..sort()))
                  DropdownMenuItem(value: name, child: Text(name)),
              ],
              onChanged: (value) =>
                  setState(() => category = value == '' ? null : value),
            ),
          ),
          Row(
            children: [
              IconButton(
                tooltip: 'Tháng trước',
                onPressed: () => setState(
                  () => month = DateTime(month.year, month.month - 1),
                ),
                icon: const Icon(CupertinoIcons.chevron_left),
              ),
              Expanded(
                child: Text(
                  '${month.month}/${month.year}',
                  textAlign: TextAlign.center,
                ),
              ),
              IconButton(
                tooltip: 'Tháng sau',
                onPressed: () => setState(
                  () => month = DateTime(month.year, month.month + 1),
                ),
                icon: const Icon(CupertinoIcons.chevron_right),
              ),
            ],
          ),
          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: offset + days,
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 7,
            ),
            itemBuilder: (context, i) {
              if (i < offset) return const SizedBox();
              final day = DateTime(month.year, month.month, i - offset + 1);
              final count = predictions.values
                  .where((p) => p != null && sameDay(p.next, day))
                  .length;
              return TextButton(
                onPressed: () => setState(() => selected = day),
                style: TextButton.styleFrom(
                  backgroundColor: sameDay(day, selected)
                      ? Theme.of(context).colorScheme.primary
                            .withValues(alpha: .2)
                      : null,
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text('${day.day}'),
                    if (count > 0)
                      Text(
                        '$count truyện',
                        style: const TextStyle(fontSize: 10),
                      ),
                  ],
                ),
              );
            },
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              '${selected.day}/${selected.month}/${selected.year}: ${selectedBooks.length} truyện dự kiến',
            ),
          ),
          for (final entry in selectedBooks)
            ListTile(
              title: Text(entry.key.title),
              subtitle: Text(
                'Khoảng ${entry.value!.intervalDays} ngày/chương · ${entry.value!.samples} khoảng phát hành',
              ),
              onTap: () => context.push(libraryBookLocation(entry.key.id)),
            ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              '${predictions.values.where((p) => p == null).length} truyện chưa đủ dữ liệu để dự đoán. Đây là ước lượng từ ngày chương của nguồn, không phải lịch phát hành chính thức.',
            ),
          ),
        ],
      ),
    );
  }
}
