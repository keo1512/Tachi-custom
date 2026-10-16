import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../../core/format/vietnamese_format.dart';
import '../application/sync_controller.dart';
import '../domain/sync_engine.dart';

class SyncStatusPanel extends StatelessWidget {
  const SyncStatusPanel({super.key, required this.state});
  final SyncState state;

  @override
  Widget build(BuildContext context) {
    final transfer = state.progress;
    final title = switch (state) {
      SyncState(busy: true) =>
        transfer == null
            ? 'Đang kiểm tra dữ liệu…'
            : transfer.direction == SyncTransferDirection.upload
            ? 'Đang tải lên…'
            : 'Đang tải về…',
      SyncState(conflict: true) => 'Cần chọn cách hợp nhất',
      SyncState(error: true) => 'Đồng bộ chưa hoàn tất',
      SyncState(user: null) => 'Chưa đăng nhập',
      SyncState(enabled: false) => 'Đã tắt đồng bộ tự động',
      SyncState(lastSyncedAt: null) => 'Sẵn sàng đồng bộ',
      _ => 'Đồng bộ tự động đang bật',
    };
    final ratio = transfer == null || transfer.total <= 0
        ? null
        : (transfer.completed / transfer.total).clamp(0.0, 1.0);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      child: Semantics(
        container: true,
        liveRegion: true,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (state.busy)
                  const CupertinoActivityIndicator()
                else
                  Icon(
                    state.error || state.conflict
                        ? CupertinoIcons.exclamationmark_circle
                        : CupertinoIcons.cloud,
                    size: 22,
                    color: state.error
                        ? Theme.of(context).colorScheme.error
                        : Theme.of(context).colorScheme.primary,
                  ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    title,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
            if (state.message?.isNotEmpty == true) ...[
              const SizedBox(height: 10),
              Text(state.message!),
            ],
            if (transfer != null) ...[
              const SizedBox(height: 12),
              // A stopped or failed transfer must not appear to keep running.
              if (state.busy)
                LinearProgressIndicator(
                  value: ratio,
                  semanticsLabel: 'Tiến độ đồng bộ',
                  semanticsValue: ratio == null
                      ? null
                      : '${(ratio * 100).floor()}%',
                ),
              const SizedBox(height: 8),
              Text(
                '${transfer.direction == SyncTransferDirection.upload ? 'Tải lên' : 'Tải về'}: '
                '${ratio == null ? 0 : (ratio * 100).floor()}% · '
                '${vietnameseNumber(transfer.completed / 1048576, decimals: 2)} / '
                '${vietnameseNumber(transfer.total / 1048576, decimals: 2)} MiB'
                '${transfer.reused == 0 ? '' : ' · Dùng lại ${vietnameseNumber(transfer.reused / 1048576, decimals: 2)} MiB'}',
              ),
            ],
          ],
        ),
      ),
    );
  }
}
