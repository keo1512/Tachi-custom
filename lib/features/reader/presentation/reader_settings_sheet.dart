import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../settings/settings_controller.dart';

Future<void> showReaderSettings(
  BuildContext context, {
  required bool manga,
}) => showModalBottomSheet(
  context: context,
  showDragHandle: true,
  isScrollControlled: true,
  builder: (context) => Consumer(
    builder: (context, ref, _) {
      final s = ref.watch(settingsProvider);
      final update = ref.read(settingsProvider.notifier);
      return SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Giao diện đọc',
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 20),
              if (manga) ...[
                const Text('Hướng đọc'),
                const SizedBox(height: 8),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: SegmentedButton<String>(
                    segments: const [
                      ButtonSegment(value: 'vertical', label: Text('Cuộn dọc')),
                      ButtonSegment(value: 'paged', label: Text('Lật trang')),
                      ButtonSegment(value: 'rtl', label: Text('Phải → trái')),
                    ],
                    selected: {s.mangaMode},
                    onSelectionChanged: (v) =>
                        update.update(mangaMode: v.first),
                  ),
                ),
              ] else ...[
                Row(
                  children: [
                    const Text('Cỡ chữ'),
                    const Spacer(),
                    Text('${s.fontSize.round()}'),
                  ],
                ),
                Slider(
                  value: s.fontSize.clamp(14, 32),
                  min: 14,
                  max: 32,
                  divisions: 18,
                  onChanged: (v) => update.update(fontSize: v),
                ),
                Row(
                  children: [
                    const Text('Khoảng cách dòng'),
                    const Spacer(),
                    Text(s.lineHeight.toStringAsFixed(1)),
                  ],
                ),
                Slider(
                  value: s.lineHeight.clamp(1.2, 2.4),
                  min: 1.2,
                  max: 2.4,
                  divisions: 12,
                  onChanged: (v) => update.update(lineHeight: v),
                ),
                DropdownButtonFormField<String>(
                  initialValue: s.font == 'Arial' || s.font == 'NotoSans'
                      ? 'NotoSans'
                      : 'NotoSerif',
                  decoration: const InputDecoration(labelText: 'Phông chữ'),
                  items: const [
                    DropdownMenuItem(
                      value: 'NotoSerif',
                      child: Text('Có chân · Noto Serif'),
                    ),
                    DropdownMenuItem(
                      value: 'NotoSans',
                      child: Text('Không chân · Noto Sans'),
                    ),
                  ],
                  onChanged: (v) => update.update(font: v),
                ),
              ],
              const SizedBox(height: 20),
              const Text('Nền trang'),
              const SizedBox(height: 10),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(value: 'paper', label: Text('Sáng')),
                    ButtonSegment(value: 'sepia', label: Text('Giấy')),
                    ButtonSegment(value: 'night', label: Text('Tối')),
                  ],
                  selected: {s.readerTheme},
                  onSelectionChanged: (v) =>
                      update.update(readerTheme: v.first),
                ),
              ),
            ],
          ),
        ),
      );
    },
  ),
);
