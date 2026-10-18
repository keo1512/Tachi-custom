import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../settings/settings_controller.dart';
import '../../library/domain/library_book.dart';
import '../domain/reader_options.dart';
import 'reader_advanced_settings.dart';
import 'reader_options_controller.dart';

Future<void> showReaderSettings(
  BuildContext context, {
  required bool manga,
  LibraryBook? book,
  int? expectedRevision,
}) async {
  final advanced = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Theme.of(context).scaffoldBackgroundColor,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
    ),
    builder: (sheetContext) => Consumer(
      builder: (sheetContext, ref, _) {
        final s = ref.watch(settingsProvider);
        final update = ref.read(settingsProvider.notifier);
        final options = ReaderOptions.fromJson({
          ...ref.watch(readerOptionsProvider).toJson(),
          ...?book?.readerPreferences,
        });
        final backgroundLabel = switch (options.backgroundMode) {
          'light' => 'Nền sáng',
          'dark' => 'Nền tối',
          'custom' =>
            'Màu tùy chọn #${(options.backgroundColor & 0xffffff).toRadixString(16).padLeft(6, '0').toUpperCase()}',
          _ => 'Theo giao diện sáng hoặc tối của ứng dụng.',
        };
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
                      options.mangaLayoutLabel,
                      Text(
                        options.isPaged
                            ? 'Vuốt hoặc dùng vùng chạm để lật trang. Chọn chế độ đọc trong Thiết lập nâng cao.'
                            : 'Các trang ảnh nối liền theo thiết lập hiển thị. Chạm vào trang để ẩn hoặc hiện điều khiển.',
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
                  if (manga)
                    section('Nền đọc', Text(backgroundLabel))
                  else ...[
                    Divider(
                      height: .5,
                      thickness: .5,
                      color: divider,
                      indent: 16,
                    ),
                    section(
                      'Nền trang',
                      SizedBox(
                        width: double.infinity,
                        child: CupertinoSlidingSegmentedControl<String>(
                          groupValue: s.readerTheme,
                          children: const {
                            'system': Text('Theo app'),
                            'paper': Text('Sáng'),
                            'sepia': Text('Giấy'),
                            'night': Text('Tối'),
                          },
                          onValueChanged: (value) {
                            if (value != null) {
                              update.update(readerTheme: value);
                            }
                          },
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(height: 10),
                  ListTile(
                    title: const Text('Thiết lập nâng cao / riêng theo truyện'),
                    trailing: const Icon(CupertinoIcons.chevron_forward),
                    onTap: () {
                      Navigator.pop(sheetContext, true);
                    },
                  ),
                ],
              ),
            ),
          ),
        );
      },
    ),
  );
  if (advanced == true && context.mounted) {
    await showAdvancedReaderSettings(
      context,
      book: book,
      expectedRevision: expectedRevision,
    );
  }
}
