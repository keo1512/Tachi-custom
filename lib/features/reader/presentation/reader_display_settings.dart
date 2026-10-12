import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../domain/reader_options.dart';

class ReaderDisplaySettings extends StatelessWidget {
  const ReaderDisplaySettings({
    super.key,
    required this.options,
    required this.change,
  });
  final ReaderOptions options;
  final void Function(Map<String, dynamic>) change;
  @override
  Widget build(BuildContext context) {
    Widget flag(String title, String key, bool value) =>
        SwitchListTile.adaptive(
          title: Text(title),
          value: value,
          onChanged: (value) => change({key: value}),
        );
    Widget margin(String title, String key, double? value) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: Text('$title: ${(value ?? options.margin).round()} px'),
        ),
        Slider(
          value: value ?? options.margin,
          min: 0,
          max: 64,
          onChanged: (value) => change({key: value}),
        ),
      ],
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        flag('Toàn màn hình', 'fullScreen', options.fullScreen),
        flag('Ẩn thanh trạng thái', 'hideStatusBar', options.hideStatusBar),
        flag(
          'Tắt vuốt quay lại khi đọc',
          'disableBackSwipe',
          options.disableBackSwipe,
        ),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 16),
          child: Text(
            'Khi tắt vuốt quay lại, nút Quay lại trên thanh đọc vẫn hoạt động.',
          ),
        ),
        flag(
          'Lề riêng cho màn hình dọc / ngang',
          'orientationMargins',
          options.orientationMargins,
        ),
        if (options.orientationMargins) ...[
          margin('Dọc — lề trái', 'portraitLeft', options.portraitLeft),
          margin('Dọc — lề phải', 'portraitRight', options.portraitRight),
          margin('Ngang — lề trái', 'landscapeLeft', options.landscapeLeft),
          margin('Ngang — lề phải', 'landscapeRight', options.landscapeRight),
          TextButton(
            onPressed: () => change({
              'portraitLeft': null,
              'portraitRight': null,
              'landscapeLeft': null,
              'landscapeRight': null,
            }),
            child: const Text('Dùng lại lề chung cho cả hai hướng'),
          ),
        ],
        Padding(
          padding: const EdgeInsets.all(16),
          child: DropdownButtonFormField<String>(
            key: ValueKey('reader-background-${options.backgroundMode}'),
            initialValue: options.backgroundMode,
            isExpanded: true,
            isDense: false,
            itemHeight: null,
            decoration: const InputDecoration(labelText: 'Nền trang đọc'),
            items: const [
              DropdownMenuItem(
                value: 'system',
                child: Text('Theo giao diện ứng dụng'),
              ),
              DropdownMenuItem(value: 'light', child: Text('Sáng')),
              DropdownMenuItem(value: 'dark', child: Text('Tối')),
              DropdownMenuItem(value: 'custom', child: Text('Màu tùy chọn')),
            ],
            onChanged: (value) {
              if (value != null) change({'backgroundMode': value});
            },
          ),
        ),
        if (options.backgroundMode == 'custom')
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Column(
              children: [
                TextFormField(
                  key: ValueKey('reader-rgb-${options.backgroundColor}'),
                  initialValue: (options.backgroundColor & 0xffffff)
                      .toRadixString(16)
                      .padLeft(6, '0')
                      .toUpperCase(),
                  decoration: const InputDecoration(
                    labelText: 'Mã màu RGB',
                    prefixText: '#',
                    helperText: 'Nhập 6 ký tự rồi bấm Xong.',
                  ),
                  inputFormatters: [
                    FilteringTextInputFormatter.allow(RegExp('[0-9a-fA-F]')),
                    LengthLimitingTextInputFormatter(6),
                  ],
                  textInputAction: TextInputAction.done,
                  onFieldSubmitted: (value) {
                    if (value.length == 6) {
                      change({
                        'backgroundColor':
                            0xff000000 | int.parse(value, radix: 16),
                      });
                    }
                  },
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  children: [
                    for (final entry in const {
                      'Đen': 0xff000000,
                      'Trắng': 0xffffffff,
                      'Nâu giấy': 0xfff5ebdc,
                      'Xám tối': 0xff161616,
                    }.entries)
                      ActionChip(
                        label: Text(entry.key),
                        avatar: Icon(Icons.circle, color: Color(entry.value)),
                        onPressed: () =>
                            change({'backgroundColor': entry.value}),
                      ),
                  ],
                ),
              ],
            ),
          ),
      ],
    );
  }
}
