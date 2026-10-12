import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../library/data/backup_restore_progress.dart';
import '../../library/data/backup_service.dart';

Future<int?> showBackupRestoreProgress(
  BuildContext context,
  BackupService service,
  BackupPreview preview, {
  required bool restoreConfiguration,
}) async {
  final result = await showCupertinoDialog<_RestoreResult>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _RestoreProgressDialog(
      service: service,
      preview: preview,
      restoreConfiguration: restoreConfiguration,
    ),
  );
  if (result?.error case final error?) throw error;
  return result?.count;
}

class _RestoreResult {
  const _RestoreResult({this.count, this.error});
  final int? count;
  final Object? error;
}

class _RestoreProgressDialog extends StatefulWidget {
  const _RestoreProgressDialog({
    required this.service,
    required this.preview,
    required this.restoreConfiguration,
  });
  final BackupService service;
  final BackupPreview preview;
  final bool restoreConfiguration;
  @override
  State<_RestoreProgressDialog> createState() => _RestoreProgressState();
}

class _RestoreProgressState extends State<_RestoreProgressDialog> {
  final cancellation = BackupRestoreCancellation();
  var progress = const BackupRestoreProgress(BackupRestoreStage.validating);
  bool cancelling = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => run());
  }

  Future<void> run() async {
    _RestoreResult result;
    try {
      final count = await widget.service.mergePreview(
        widget.preview,
        restoreConfiguration: widget.restoreConfiguration,
        cancellation: cancellation,
        onProgress: (value) {
          if (mounted) setState(() => progress = value);
        },
      );
      result = _RestoreResult(count: count);
    } on BackupRestoreCancelled {
      result = const _RestoreResult();
    } catch (error) {
      result = _RestoreResult(error: error);
    }
    if (mounted) Navigator.of(context).pop(result);
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: false,
    child: CupertinoAlertDialog(
      title: const Text('Khôi phục bản sao lưu'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 14),
          const CupertinoActivityIndicator(),
          const SizedBox(height: 12),
          Text(cancelling ? 'Đang hủy…' : progress.label),
          if (progress.stage == BackupRestoreStage.preparing &&
              progress.fraction != null) ...[
            const SizedBox(height: 12),
            LinearProgressIndicator(value: progress.fraction),
          ],
          const SizedBox(height: 10),
          Text(
            progress.canCancel
                ? 'Có thể hủy trong lúc chuẩn bị. Thư viện chỉ được ghi khi toàn bộ dữ liệu đã được kiểm tra.'
                : 'Đang lưu nguyên tử. Hãy chờ thao tác hoàn tất.',
          ),
        ],
      ),
      actions: [
        if (progress.canCancel)
          CupertinoDialogAction(
            onPressed: cancelling
                ? null
                : () {
                    cancellation.cancel();
                    setState(() => cancelling = true);
                  },
            child: const Text('Hủy khôi phục'),
          ),
      ],
    ),
  );
}
