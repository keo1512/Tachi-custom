import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../settings/presentation/settings_widgets.dart';
import '../application/sync_controller.dart';
import '../domain/sync_engine.dart';
import '../../../core/format/vietnamese_format.dart';
import '../../library/domain/library_book.dart';
import '../../library/domain/library_reading.dart';

class SyncMergeScreen extends ConsumerStatefulWidget {
  const SyncMergeScreen({super.key, required this.conflict});
  final SyncConflict conflict;
  @override
  ConsumerState<SyncMergeScreen> createState() => _SyncMergeScreenState();
}

class _SyncMergeScreenState extends ConsumerState<SyncMergeScreen> {
  final choices = <String, bool>{};
  Future<void> apply() async {
    final controller = ref.read(syncProvider.notifier);
    if (!identical(controller.pendingConflict, widget.conflict)) return;
    final accepted = await showCupertinoDialog<bool>(
      context: context,
      builder: (context) => CupertinoAlertDialog(
        title: const Text('Hợp nhất hai thiết bị?'),
        content: const Text(
          'Giữ các thay đổi độc lập và áp dụng lựa chọn cho từng mục xung đột. Bản trên máy được lưu làm bản phục hồi trước khi thay.',
        ),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Hủy'),
          ),
          CupertinoDialogAction(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Hợp nhất'),
          ),
        ],
      ),
    );
    if (!mounted || accepted != true) return;
    await controller.resolveRecords(Map.unmodifiable(choices));
    if (!mounted) return;
    if (!ref.read(syncProvider).error) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(syncProvider);
    final plan = widget.conflict.mergePlan!;
    final stale = !identical(
      ref.read(syncProvider.notifier).pendingConflict,
      widget.conflict,
    );
    return SettingsPage(
      title: 'Hợp nhất dữ liệu',
      children: [
        SettingsNote(
          plan.hasBaseline
              ? 'Các thay đổi chỉ có ở một thiết bị được giữ tự động. Chọn bản muốn giữ cho từng truyện hoặc thiết lập bị sửa ở cả hai thiết bị.'
              : 'Không còn bản gốc chung để đối chiếu. Giữ các truyện chỉ có trên một máy; các mục khác nhau cần bạn chọn. Không tự suy đoán dữ liệu đã bị xóa.',
        ),
        if (stale)
          const SettingsNote(
            'Dữ liệu xung đột đã thay đổi. Đóng màn này và đồng bộ lại.',
          ),
        if (plan.conflicts.isEmpty)
          const SettingsNote(
            'Không có mục phải chọn. Các thay đổi độc lập có thể hợp nhất.',
          ),
        for (final item in plan.conflicts)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.key.startsWith('setting:')
                      ? 'Thiết lập: ${_settingLabel(item.key.substring(8))}'
                      : item.title,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 8),
                if (item.key.startsWith('book:')) ...[
                  Text('Trên máy: ${_bookSummary(item.local)}'),
                  Text('Trên cloud: ${_bookSummary(item.remote)}'),
                  const SizedBox(height: 8),
                ],
                if (item.key.startsWith('extension:')) ...[
                  Text('Trên máy: ${_extensionSummary(item.local)}'),
                  Text('Trên cloud: ${_extensionSummary(item.remote)}'),
                  const SizedBox(height: 8),
                ],
                Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  children: [
                    ChoiceChip(
                      label: Text(
                        item.localDeleted ? 'Máy: đã xóa' : 'Giữ trên máy',
                      ),
                      selected: choices[item.key] == true,
                      onSelected: state.busy || stale
                          ? null
                          : (_) => setState(() => choices[item.key] = true),
                    ),
                    ChoiceChip(
                      label: Text(
                        item.remoteDeleted ? 'Cloud: đã xóa' : 'Giữ trên cloud',
                      ),
                      selected: choices[item.key] == false,
                      onSelected: state.busy || stale
                          ? null
                          : (_) => setState(() => choices[item.key] = false),
                    ),
                  ],
                ),
              ],
            ),
          ),
        SettingsRow(
          title: 'Hợp nhất và đồng bộ',
          icon: CupertinoIcons.arrow_merge,
          trailing: state.busy ? const CupertinoActivityIndicator() : null,
          onTap: stale || state.busy || choices.length != plan.conflicts.length
              ? null
              : apply,
        ),
        if (state.message?.isNotEmpty == true) SettingsNote(state.message!),
      ],
    );
  }
}

String _bookSummary(Object? value) {
  if (value == null) return 'Đã xóa truyện';
  final book = LibraryBook.fromJson(
    Map<String, dynamic>.from((value as Map)['book'] as Map),
  );
  return '${readChapterCount(book)}/${book.chapters.length} chương đã đọc · ${(book.progress * 100).round()}%'
      '${book.lastRead == null ? '' : '\nĐọc gần nhất: ${vietnameseDateTime(book.lastRead!)}'}';
}

String _extensionSummary(Object? value) {
  if (value == null) return 'Không có gói trong bản này';
  // The merge plan already validated the bundle. Avoid decoding/copying large
  // base64 packages every time a selection rebuilds this screen.
  final package = value as Map;
  final version = package['version'] as String;
  final encoded = package['data'] as String;
  final padding = encoded.endsWith('==')
      ? 2
      : encoded.endsWith('=')
      ? 1
      : 0;
  final bytes = encoded.length ~/ 4 * 3 - padding;
  return 'Phiên bản ${version.isEmpty ? 'chưa rõ' : version}'
      ' · ${(package['sourceIds'] as List).length} nguồn'
      ' · ${vietnameseNumber(bytes / 1048576, decimals: 2)} MiB'
      '\nMã kiểm tra ${(package['sha256'] as String).substring(0, 12)}';
}

String _settingLabel(String key) =>
    const {
      'dark': 'Giao diện tối',
      'appearanceV1': 'Giao diện sáng / tối',
      'libraryColumns': 'Số cột thư viện',
      'downloadConcurrency': 'Tải đồng thời',
      'fontSize': 'Cỡ chữ',
      'lineHeight': 'Khoảng cách dòng',
      'font': 'Phông chữ',
      'readerTheme': 'Nền trang chữ',
      'mangaMode': 'Chế độ đọc truyện',
      'pinnedSources': 'Nguồn đã ghim',
      'recentSources': 'Nguồn gần đây',
      'readingGoalMinutes': 'Mục tiêu đọc',
      'sourceCatalogueLayoutV1': 'Bố cục nguồn',
      'libraryGrouping': 'Nhóm thư viện',
      'taskNotificationsEnabledV1': 'Thông báo tác vụ',
      'extensionRepositoriesV1': 'Kho tiện ích mở rộng',
      'libraryCategoriesV1': 'Danh mục truyện',
      'libraryGroupOrderV1': 'Thứ tự nhóm truyện',
      'libraryFilterV1': 'Bộ lọc thư viện',
      'readerOptionsV1': 'Tùy chọn trình đọc',
      'libraryUpdatePolicyV1': 'Cập nhật thư viện',
      'downloadDeletionPolicyV1': 'Dọn chương đã tải',
      'automaticBackupPolicyV1': 'Sao lưu tự động',
      'savedSourceFiltersV1': 'Bộ lọc nguồn đã lưu',
      'navigationPreferencesV1': 'Thanh điều hướng',
      'sourceLanguagesV1': 'Ngôn ngữ nguồn',
    }[key] ??
    (key.startsWith('readSeconds:')
        ? 'Thời gian đọc theo ngày'
        : 'Tùy chọn đã lưu');
