import 'dart:convert';

import 'package:flutter/material.dart';

import '../../../core/format/vietnamese_format.dart';
import '../../settings/presentation/settings_widgets.dart';

/// A bounded preview of public, validated portable configuration. Decoding is
/// cached independently of merge choices; this widget never changes values.
class SyncSettingComparison extends StatefulWidget {
  const SyncSettingComparison({
    super.key,
    required this.settingKey,
    required this.label,
    required this.local,
    required this.remote,
  });
  final String settingKey, label;
  final Object? local, remote;

  @override
  State<SyncSettingComparison> createState() => _SyncSettingComparisonState();
}

class _SyncSettingComparisonState extends State<SyncSettingComparison> {
  late Object? local, remote;

  @override
  void initState() {
    super.initState();
    _decode();
  }

  @override
  void didUpdateWidget(SyncSettingComparison oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.settingKey != widget.settingKey ||
        oldWidget.local != widget.local ||
        oldWidget.remote != widget.remote) {
      _decode();
    }
  }

  void _decode() {
    Object? decode(Object? value) {
      if (!widget.settingKey.endsWith('V1') || value is! String) return value;
      // Scalar V1 preferences (appearance/layout) remain ordinary strings.
      final trimmed = value.trimLeft();
      if (!trimmed.startsWith('{') && !trimmed.startsWith('[')) return value;
      return jsonDecode(value);
    }

    local = decode(widget.local);
    remote = decode(widget.remote);
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text('Trên máy: ${_summary(widget.settingKey, local)}'),
      Text('Trên cloud: ${_summary(widget.settingKey, remote)}'),
      if (_hasDetails(local) || _hasDetails(remote))
        TextButton(
          onPressed: () => openSettingsPage(
            context,
            _SettingDetails(
              title: widget.label,
              fieldKey: widget.settingKey,
              local: local,
              remote: remote,
            ),
          ),
          child: const Text('Xem đầy đủ'),
        ),
    ],
  );
}

bool _hasDetails(Object? value) =>
    value is Map || value is List || value is String && value.length > 120;

String _clip(String text, [int length = 120]) {
  if (text.length <= length) return text;
  final last = text.codeUnitAt(length - 1);
  final end = last >= 0xd800 && last <= 0xdbff ? length + 1 : length;
  return '${text.substring(0, end)}…';
}

String _summary(String key, Object? value) {
  if (value == null) return 'Không có thiết lập này';
  if (value is Map) {
    if (value.isEmpty) return 'Không có mục thiết lập';
    final preview = value.entries
        .take(3)
        .map(
          (entry) =>
              '${_fieldLabel(entry.key.toString())}: ${_shortValue(entry.value, entry.key.toString())}',
        );
    return _clip('${value.length} mục thiết lập · ${preview.join(' · ')}', 220);
  }
  if (value is List) {
    if (value.isEmpty) return 'Danh sách trống';
    return _clip(
      '${value.length} mục · ${value.take(3).map((item) => _shortValue(item)).join(', ')}',
      220,
    );
  }
  if (value is bool) return value ? 'Bật' : 'Tắt';
  if (value is num) {
    final number = vietnameseNumber(
      value.toDouble(),
      decimals: value % 1 == 0 ? 0 : 2,
    );
    if (key == 'readingGoalMinutes') return '$number phút';
    if (key.startsWith('readSeconds:')) return '$number giây';
    if (key == 'libraryColumns') return '$number cột';
    if (key == 'downloadConcurrency' || key == 'downloadAhead') {
      return '$number chương';
    }
    if (key == 'hours') return value == 0 ? 'Tắt lịch tự động' : '$number giờ';
    if (key == 'keep') return '$number bản sao lưu';
    return number;
  }
  return _clip(switch (value) {
    'system' => 'Theo hệ thống',
    'dark' => 'Tối',
    'light' => 'Sáng',
    'vertical' => 'Cuộn dọc',
    'grid' => 'Lưới',
    'list' => 'Danh sách',
    'paged' => 'Từng trang',
    'rtl' => 'Từ phải sang trái',
    'paper' => 'Giấy',
    'sepia' => 'Nâu vàng',
    'night' => 'Ban đêm',
    'inherit' => 'Theo mặc định',
    'include' => 'Cho phép',
    'exclude' => 'Loại trừ',
    '' => 'Trống',
    _ => value.toString(),
  });
}

String _shortValue(Object? value, [String key = '']) => value is Map
    ? '${value.length} trường'
    : value is List
    ? '${value.length} mục'
    : _clip(_summary(key, value), 44);

String _fieldLabel(String key) =>
    const {
      'hours': 'Chu kỳ tự động',
      'keep': 'Số bản giữ lại',
      'downloadAhead': 'Tải trước',
      'downloadNew': 'Tải chương mới',
      'wifiOnly': 'Chỉ Wi-Fi',
      'chargingOnly': 'Chỉ khi sạc',
      'skipCompleted': 'Bỏ qua truyện hoàn thành',
      'skipUnstarted': 'Bỏ qua truyện chưa đọc',
      'skipUnread': 'Bỏ qua khi còn chương chưa đọc',
      'afterReading': 'Xóa sau khi đọc',
      'afterManualRead': 'Xóa khi đánh dấu đã đọc',
      'protectBookmarks': 'Giữ chương có dấu trang',
      'categories': 'Danh mục',
      'defaultCategories': 'Danh mục mặc định',
      'name': 'Tên',
      'update': 'Cập nhật',
      'download': 'Tải xuống',
      'url': 'Địa chỉ',
      'engine': 'Loại nguồn',
      'filter': 'Bộ lọc',
      'filters': 'Các bộ lọc',
      'sorts': 'Sắp xếp',
      'presets': 'Bộ lọc đã lưu',
      'order': 'Thứ tự tab',
      'start': 'Tab khi mở',
      'showLabels': 'Hiện tên tab',
      'rememberSelected': 'Nhớ tab đã chọn',
      'enabled': 'Bật',
      'margin': 'Lề',
      'gap': 'Khoảng cách trang',
      'brightness': 'Độ sáng',
      'grayscale': 'Ảnh xám',
      'inverted': 'Đảo màu',
      'showPageNumber': 'Hiện số trang',
      'keepAwake': 'Giữ màn hình sáng',
      'orientation': 'Hướng màn hình',
      'skipRead': 'Bỏ qua chương đã đọc',
      'zoom': 'Thu phóng',
      'autoScroll': 'Tự cuộn',
    }[key] ??
    key;

const _scalar = Object();

/// Only the visible level is built. Large arrays and strings stay lazy instead
/// of laying out the entire (up to 2 MiB) configuration in the merge form.
class _SettingDetails extends StatefulWidget {
  const _SettingDetails({
    required this.title,
    required this.fieldKey,
    required this.local,
    required this.remote,
  });
  final String title, fieldKey;
  final Object? local, remote;
  @override
  State<_SettingDetails> createState() => _SettingDetailsState();
}

class _SettingDetailsState extends State<_SettingDetails> {
  String filter = '';
  late final keys = <Object>{
    ..._keys(widget.local),
    ..._keys(widget.remote),
  }.toList();

  Iterable<Object> _keys(Object? value) => value == null
      ? const []
      : value is Map
      ? value.keys.cast<String>()
      : value is List
      ? Iterable<int>.generate(value.length)
      : [_scalar];

  Object? _value(Object? value, Object key) => identical(key, _scalar)
      ? value is Map || value is List
            ? null
            : value
      : value is Map
      ? value[key]
      : value is List && key is int && key < value.length
      ? value[key]
      : null;

  String _label(Object key) => identical(key, _scalar)
      ? 'Giá trị'
      : key is int
      ? 'Mục ${key + 1}'
      : _fieldLabel(key as String);

  @override
  Widget build(BuildContext context) {
    final scalar = keys.length == 1 && identical(keys.single, _scalar);
    final visible = keys
        .where((key) => '${_label(key)} $key'.toLowerCase().contains(filter))
        .toList();
    final localText = widget.local == null
        ? 'Không có thiết lập này'
        : widget.local is String
        ? widget.local as String
        : _summary(widget.fieldKey, widget.local);
    final remoteText = widget.remote == null
        ? 'Không có thiết lập này'
        : widget.remote is String
        ? widget.remote as String
        : _summary(widget.fieldKey, widget.remote);
    final chunks = scalar
        ? ((localText.length > remoteText.length
                      ? localText.length
                      : remoteText.length) /
                  1024)
              .ceil()
        : 0;
    return Scaffold(
      appBar: AppBar(title: const Text('Chi tiết thiết lập')),
      body: SafeArea(
        top: false,
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: CustomScrollView(
              slivers: [
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(
                      widget.title,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                ),
                if (!scalar)
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                      child: TextField(
                        decoration: const InputDecoration(
                          labelText: 'Lọc theo tên mục',
                        ),
                        onChanged: (value) =>
                            setState(() => filter = value.trim().toLowerCase()),
                      ),
                    ),
                  ),
                SliverPadding(
                  padding: const EdgeInsets.only(bottom: 24),
                  sliver: SliverList.builder(
                    itemCount: scalar
                        ? chunks
                        : visible.isEmpty
                        ? 1
                        : visible.length,
                    itemBuilder: (context, index) {
                      if (!scalar && visible.isEmpty) {
                        return SettingsNote(
                          filter.isEmpty
                              ? 'Không có mục thiết lập.'
                              : 'Không có mục phù hợp.',
                        );
                      }
                      if (scalar) {
                        return Padding(
                          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              if (chunks > 1)
                                Text('Phần ${index + 1} / $chunks'),
                              const Text(
                                'Trên máy',
                                style: TextStyle(fontWeight: FontWeight.w600),
                              ),
                              SelectableText(_chunk(localText, index)),
                              const SizedBox(height: 12),
                              const Text(
                                'Trên cloud',
                                style: TextStyle(fontWeight: FontWeight.w600),
                              ),
                              SelectableText(_chunk(remoteText, index)),
                            ],
                          ),
                        );
                      }
                      final key = visible[index];
                      final local = _value(widget.local, key),
                          remote = _value(widget.remote, key);
                      final fieldKey = key is String ? key : '';
                      return Padding(
                        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            SelectableText(
                              _label(key),
                              style: const TextStyle(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            SelectableText(
                              'Trên máy: ${_summary(fieldKey, local)}',
                            ),
                            SelectableText(
                              'Trên cloud: ${_summary(fieldKey, remote)}',
                            ),
                            if (_hasDetails(local) || _hasDetails(remote))
                              TextButton(
                                onPressed: () => openSettingsPage(
                                  context,
                                  _SettingDetails(
                                    title: _label(key),
                                    fieldKey: fieldKey,
                                    local: local,
                                    remote: remote,
                                  ),
                                ),
                                child: const Text('Mở mục'),
                              ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

String _chunk(String text, int index) {
  // Keep surrogate pairs intact at chunk boundaries.
  int boundary(int offset) =>
      offset < text.length &&
          offset > 0 &&
          text.codeUnitAt(offset - 1) >= 0xd800 &&
          text.codeUnitAt(offset - 1) <= 0xdbff
      ? offset + 1
      : offset;
  final start = boundary(index * 1024);
  if (start >= text.length) return '';
  return text.substring(
    start,
    boundary(((index + 1) * 1024).clamp(0, text.length)),
  );
}
