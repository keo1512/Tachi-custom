import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/widgets/feedback.dart';
import '../../library/domain/library_book.dart';
import '../../library/presentation/library_view_model.dart';
import '../../library/data/coordinated_preferences.dart';
import '../../settings/settings_controller.dart';
import '../domain/reader_options.dart';
import 'reader_options_controller.dart';
import 'reader_tap_zones.dart';
import 'reader_display_settings.dart';

Future<void> showAdvancedReaderSettings(
  BuildContext context, {
  LibraryBook? book,
  int? expectedRevision,
}) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  backgroundColor: Theme.of(context).scaffoldBackgroundColor,
  builder: (_) =>
      _ReaderPreferencesSheet(book: book, revision: expectedRevision),
);

class _ReaderPreferencesSheet extends ConsumerStatefulWidget {
  const _ReaderPreferencesSheet({this.book, this.revision});
  final LibraryBook? book;
  final int? revision;
  @override
  ConsumerState<_ReaderPreferencesSheet> createState() =>
      _ReaderPreferencesState();
}

class _ReaderPreferencesState extends ConsumerState<_ReaderPreferencesSheet> {
  late final int? configurationGeneration = switch (ref.read(
    preferencesProvider,
  )) {
    final CoordinatedPreferences preferences => preferences.mutationGeneration,
    _ => null,
  };
  late bool perTitle = widget.book?.readerPreferences.isNotEmpty ?? false;
  late ReaderOptions local = ReaderOptions.fromJson({
    ...ref.read(readerOptionsProvider).toJson(),
    ...?widget.book?.readerPreferences,
  });
  void change(Map<String, dynamic> patch) {
    final next = (perTitle ? local : ref.read(readerOptionsProvider)).patch(
      patch,
    );
    setState(() => local = next);
    perform(context, () async {
      if (perTitle && widget.book != null) {
        await ref
            .read(libraryProvider.notifier)
            .updateReaderPreferences(
              widget.book!.id,
              next.toJson(),
              expectedRevision: widget.revision,
            );
      } else {
        await ref
            .read(readerOptionsProvider.notifier)
            .patch(patch, expectedGeneration: configurationGeneration);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final options = perTitle ? local : ref.watch(readerOptionsProvider);
    Widget flag(String label, bool value, String key) =>
        SwitchListTile.adaptive(
          title: Text(label),
          value: value,
          onChanged: (v) => change({key: v}),
        );
    Widget slider(
      String title,
      String key,
      double value,
      double max, {
      double min = 0,
    }) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: Text('$title: ${value.toStringAsFixed(max <= 1 ? 2 : 0)}'),
        ),
        Slider(
          value: value,
          min: min,
          max: max,
          onChanged: (v) => change({key: v}),
        ),
      ],
    );
    return SafeArea(
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * .8,
        child: ListView(
          children: [
            ListTile(
              title: const Text('Thiết lập đọc nâng cao'),
              trailing: IconButton(
                tooltip: 'Đóng',
                icon: const Icon(CupertinoIcons.xmark),
                onPressed: () => Navigator.pop(context),
              ),
            ),
            if (widget.book != null)
              SwitchListTile.adaptive(
                title: const Text('Dùng riêng cho truyện này'),
                value: perTitle,
                onChanged: (v) => perform(context, () async {
                  await ref
                      .read(libraryProvider.notifier)
                      .updateReaderPreferences(
                        widget.book!.id,
                        v ? local.toJson() : {},
                        expectedRevision: widget.revision,
                      );
                  if (mounted) setState(() => perTitle = v);
                }),
              ),
            flag('Phóng to bằng hai ngón / chạm đúp', options.zoom, 'zoom'),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: DropdownButtonFormField<String>(
                key: ValueKey('manga-layout-${options.mangaLayout}'),
                initialValue: options.mangaLayout,
                isExpanded: true,
                isDense: false,
                itemHeight: null,
                decoration: const InputDecoration(
                  labelText: 'Chế độ đọc truyện tranh',
                ),
                items: const [
                  DropdownMenuItem(
                    value: 'continuous',
                    child: Text('Cuộn dọc liên tục'),
                  ),
                  DropdownMenuItem(
                    value: 'leftToRight',
                    child: Text('Lật trang từ trái sang phải'),
                  ),
                  DropdownMenuItem(
                    value: 'rightToLeft',
                    child: Text('Lật trang từ phải sang trái'),
                  ),
                  DropdownMenuItem(
                    value: 'verticalPages',
                    child: Text('Lật trang theo chiều dọc'),
                  ),
                  DropdownMenuItem(
                    value: 'doublePage',
                    child: Text('Hai trang cạnh nhau'),
                  ),
                ],
                onChanged: (value) {
                  if (value != null) change({'mangaLayout': value});
                },
              ),
            ),
            if (options.mangaLayout == 'doublePage')
              flag(
                'Đảo vị trí hai trang',
                options.invertDoublePages,
                'invertDoublePages',
              ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: DropdownButtonFormField<String>(
                isExpanded: true,
                isDense: false,
                itemHeight: null,
                key: ValueKey('image-scale-${options.imageScale}'),
                initialValue: options.imageScale,
                decoration: const InputDecoration(labelText: 'Tỷ lệ trang ảnh'),
                items: const [
                  DropdownMenuItem(
                    value: 'width',
                    child: Text('Vừa chiều ngang'),
                  ),
                  DropdownMenuItem(
                    value: 'height',
                    child: Text('Vừa chiều dọc'),
                  ),
                  DropdownMenuItem(
                    value: 'screen',
                    child: Text('Vừa màn hình'),
                  ),
                  DropdownMenuItem(
                    value: 'original',
                    child: Text('100% kích thước ảnh'),
                  ),
                ],
                onChanged: (v) {
                  if (v != null) change({'imageScale': v});
                },
              ),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: Text(
                'Cuộn dọc hỗ trợ tỷ lệ ảnh phía trên. Chế độ lật trang hiển thị trọn ảnh; dùng hai ngón hoặc chạm đúp để phóng to.',
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: DropdownButtonFormField<String>(
                isExpanded: true,
                isDense: false,
                itemHeight: null,
                key: ValueKey(
                  'tap-zones-${options.mangaLayout}-${options.activeTapZones}',
                ),
                initialValue: options.activeTapZones,
                decoration: const InputDecoration(
                  labelText: 'Vùng chạm để cuộn',
                ),
                items: const [
                  DropdownMenuItem(value: 'off', child: Text('Tắt')),
                  DropdownMenuItem(
                    value: 'horizontal',
                    child: Text('Trái / giữa / phải'),
                  ),
                  DropdownMenuItem(
                    value: 'vertical',
                    child: Text('Trên / giữa / dưới'),
                  ),
                  DropdownMenuItem(
                    value: 'edges',
                    child: Text('Cạnh màn hình'),
                  ),
                  DropdownMenuItem(value: 'kindle', child: Text('Kiểu Kindle')),
                  DropdownMenuItem(value: 'lShape', child: Text('Hình chữ L')),
                ],
                onChanged: (v) {
                  if (v != null) {
                    change({options.isPaged ? 'pagedTapZones' : 'tapZones': v});
                  }
                },
              ),
            ),
            if (options.activeTapZones != 'off')
              flag(
                'Đảo hướng vùng chạm',
                options.invertTapZones,
                'invertTapZones',
              ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: ReaderTapZoneDiagram(
                layout: options.activeTapZones,
                inverted: options.invertTapZones,
              ),
            ),
            flag('Tự cuộn liên tục', options.autoScroll, 'autoScroll'),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: DropdownButtonFormField<String>(
                isExpanded: true,
                isDense: false,
                itemHeight: null,
                initialValue: options.autoScrollMode,
                decoration: const InputDecoration(labelText: 'Cách tự cuộn'),
                items: const [
                  DropdownMenuItem(
                    value: 'continuous',
                    child: Text('Cuộn liên tục'),
                  ),
                  DropdownMenuItem(
                    value: 'page',
                    child: Text('Cuộn tới trang kế theo thời gian'),
                  ),
                ],
                onChanged: (v) {
                  if (v != null) change({'autoScrollMode': v});
                },
              ),
            ),
            slider(
              'Thời gian mỗi trang (giây)',
              'autoPageSeconds',
              options.autoPageSeconds,
              120,
              min: 2,
            ),
            flag('Nhấn giữ trang để cuộn', options.holdScroll, 'holdScroll'),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                'Khi bật nhấn giữ, kéo lên để tăng tốc, kéo xuống để giảm; nhấc tay để dừng. Thao tác lưu, chia sẻ và OCR nằm ở nút ảnh trên thanh đọc.',
              ),
            ),
            slider(
              'Tốc độ tự cuộn (px/giây)',
              'autoScrollSpeed',
              options.autoScrollSpeed,
              200,
              min: 10,
            ),
            flag(
              'Hiển thị số trang khi ẩn điều khiển',
              options.showPageNumber,
              'showPageNumber',
            ),
            flag(
              'Giữ màn hình sáng khi đang đọc',
              options.keepAwake,
              'keepAwake',
            ),
            slider('Lề hai bên (px)', 'margin', options.margin, 64),
            ReaderDisplaySettings(options: options, change: change),
            slider('Khoảng cách giữa trang (px)', 'gap', options.gap, 32),
            slider('Độ sáng ảnh', 'brightness', options.brightness, 1, min: .1),
            flag('Thang xám', options.grayscale, 'grayscale'),
            flag('Đảo màu', options.inverted, 'inverted'),
            slider(
              'Độ đậm lớp lọc màu',
              'tintOpacity',
              options.tintOpacity,
              .8,
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Wrap(
                spacing: 8,
                children: [
                  for (final color in const [
                    0xffffffff,
                    0xffffc87c,
                    0xffb8d2ff,
                    0xffffb8c5,
                    0xffb8ffce,
                  ])
                    IconButton(
                      tooltip: 'Màu lọc ${color.toRadixString(16)}',
                      onPressed: () => change({'tint': color}),
                      icon: Icon(
                        options.tint == color
                            ? Icons.check_circle
                            : Icons.circle,
                        color: Color(color),
                      ),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: DropdownButtonFormField<String>(
                isExpanded: true,
                isDense: false,
                itemHeight: null,
                initialValue: options.blend,
                decoration: const InputDecoration(labelText: 'Pha trộn màu'),
                items: [
                  for (final pair in const {
                    'multiply': 'Nhân màu',
                    'screen': 'Làm sáng',
                    'overlay': 'Phủ màu',
                    'darken': 'Giữ màu tối hơn',
                    'lighten': 'Giữ màu sáng hơn',
                  }.entries)
                    DropdownMenuItem(value: pair.key, child: Text(pair.value)),
                ],
                onChanged: (v) {
                  if (v != null) change({'blend': v});
                },
              ),
            ),
            const SizedBox(height: 16),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: DropdownButtonFormField<String>(
                isExpanded: true,
                isDense: false,
                itemHeight: null,
                initialValue: options.orientation,
                decoration: const InputDecoration(labelText: 'Hướng màn hình'),
                items: [
                  for (final pair in const {
                    'free': 'Tự động',
                    'portrait': 'Dọc',
                    'landscape': 'Ngang',
                    'reversePortrait': 'Dọc ngược',
                  }.entries)
                    DropdownMenuItem(value: pair.key, child: Text(pair.value)),
                ],
                onChanged: (v) {
                  if (v != null) change({'orientation': v});
                },
              ),
            ),
            flag(
              'Bỏ qua chương đã đọc khi chuyển chương',
              options.skipRead,
              'skipRead',
            ),
            flag(
              'Bỏ qua chương trùng tên khi chuyển chương',
              options.skipDuplicates,
              'skipDuplicates',
            ),
            TextButton(
              onPressed: () => change(const ReaderOptions().toJson()),
              child: const Text('Đặt lại thiết lập đang chọn'),
            ),
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text(
                'Trang truyện vẫn cuộn dọc. Nền đọc áp dụng theo lựa chọn ở trên; bộ lọc chỉ tác động ảnh. Thiết lập riêng được lưu cùng sách trong sao lưu và đồng bộ.',
              ),
            ),
          ],
        ),
      ),
    );
  }
}
