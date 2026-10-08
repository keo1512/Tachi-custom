import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../settings/settings_controller.dart';

Future<void> showReaderSettings(
  BuildContext context, {
  required bool manga,
}) => showModalBottomSheet(
  context: context,
  isScrollControlled: true,
  backgroundColor: Theme.of(context).scaffoldBackgroundColor,
  shape: const RoundedRectangleBorder(
    borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
  ),
  builder: (context) => Consumer(
    builder: (context, ref, _) {
      final s = ref.watch(settingsProvider);
      final update = ref.read(settingsProvider.notifier);
      final divider = CupertinoDynamicColor.resolve(
        CupertinoColors.separator,
        context,
      );
      final secondary = CupertinoDynamicColor.resolve(
        CupertinoColors.secondaryLabel,
        context,
      );
      Widget section(String title, Widget child) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: TextStyle(fontSize: 13, color: secondary)),
            const SizedBox(height: 10),
            child,
          ],
        ),
      );
      return SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * .8,
          ),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  height: 44,
                  child: Row(
                    children: [
                      const SizedBox(width: 16),
                      const Expanded(
                        child: Text(
                          'Giao diện đọc',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      CupertinoButton(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        onPressed: () => Navigator.pop(context),
                        child: const Text(
                          'Xong',
                          style: TextStyle(fontSize: 17),
                        ),
                      ),
                    ],
                  ),
                ),
                Divider(height: .5, thickness: .5, color: divider),
                if (manga)
                  section(
                    'Hướng đọc',
                    SizedBox(
                      width: double.infinity,
                      child: CupertinoSlidingSegmentedControl<String>(
                        groupValue: s.mangaMode,
                        children: const {
                          'vertical': Text('Cuộn dọc'),
                          'paged': Text('Lật trang'),
                          'rtl': Text('Phải → trái'),
                        },
                        onValueChanged: (value) {
                          if (value != null) update.update(mangaMode: value);
                        },
                      ),
                    ),
                  )
                else ...[
                  section(
                    'Cỡ chữ',
                    Row(
                      children: [
                        const Text('A', style: TextStyle(fontSize: 14)),
                        Expanded(
                          child: CupertinoSlider(
                            value: s.fontSize.clamp(14, 32),
                            min: 14,
                            max: 32,
                            divisions: 18,
                            onChanged: (value) =>
                                update.update(fontSize: value),
                          ),
                        ),
                        const Text('A', style: TextStyle(fontSize: 24)),
                        const SizedBox(width: 12),
                        SizedBox(
                          width: 25,
                          child: Text(
                            '${s.fontSize.round()}',
                            textAlign: TextAlign.right,
                            style: TextStyle(fontSize: 13, color: secondary),
                          ),
                        ),
                      ],
                    ),
                  ),
                  Divider(
                    height: .5,
                    thickness: .5,
                    color: divider,
                    indent: 16,
                  ),
                  section(
                    'Khoảng cách dòng',
                    Row(
                      children: [
                        const Icon(CupertinoIcons.text_alignleft, size: 18),
                        Expanded(
                          child: CupertinoSlider(
                            value: s.lineHeight.clamp(1.2, 2.4),
                            min: 1.2,
                            max: 2.4,
                            divisions: 12,
                            onChanged: (value) =>
                                update.update(lineHeight: value),
                          ),
                        ),
                        Text(
                          s.lineHeight.toStringAsFixed(1),
                          style: TextStyle(fontSize: 13, color: secondary),
                        ),
                      ],
                    ),
                  ),
                  Divider(
                    height: .5,
                    thickness: .5,
                    color: divider,
                    indent: 16,
                  ),
                  section(
                    'Phông chữ',
                    SizedBox(
                      width: double.infinity,
                      child: CupertinoSlidingSegmentedControl<String>(
                        groupValue: s.font == 'Arial' || s.font == 'NotoSans'
                            ? 'NotoSans'
                            : 'NotoSerif',
                        children: const {
                          'NotoSerif': Text('Noto Serif'),
                          'NotoSans': Text('Noto Sans'),
                        },
                        onValueChanged: (value) {
                          if (value != null) update.update(font: value);
                        },
                      ),
                    ),
                  ),
                ],
                Divider(height: .5, thickness: .5, color: divider, indent: 16),
                section(
                  'Nền trang',
                  SizedBox(
                    width: double.infinity,
                    child: CupertinoSlidingSegmentedControl<String>(
                      groupValue: s.readerTheme,
                      children: const {
                        'paper': Text('Sáng'),
                        'sepia': Text('Giấy'),
                        'night': Text('Tối'),
                      },
                      onValueChanged: (value) {
                        if (value != null) update.update(readerTheme: value);
                      },
                    ),
                  ),
                ),
                const SizedBox(height: 10),
              ],
            ),
          ),
        ),
      );
    },
  ),
);
