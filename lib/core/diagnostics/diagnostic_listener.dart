import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/downloads/presentation/download_queue_controller.dart';
import '../../features/library/application/automatic_backup_status.dart';
import '../../features/library/application/library_update_report.dart';
import '../../features/tasks/data/task_platform.dart';
import 'diagnostic_log.dart';

class DiagnosticListener extends ConsumerWidget {
  const DiagnosticListener({super.key, required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(diagnosticListenerProvider);
    return child;
  }
}

/// Process diagnostics belong to the application container, including scheduled
/// work before its first frame. The UI and background owner share one sink.
final diagnosticListenerProvider = Provider<void>((ref) {
  final store = ref.read(diagnosticLogProvider);
  final Future<void> Function(DiagnosticEvent) sink = store.record;
  DiagnosticLogs.writer = sink;
  final expiration = ref.read(taskPlatformProvider).backgroundExpired.listen((
    _,
  ) {
    unawaited(
      store
          .record(
            DiagnosticEvent(
              'background',
              'background_paused',
              DiagnosticEvent.safeMessage('background_paused'),
              DateTime.now(),
            ),
          )
          .catchError((Object _) {}),
    );
  });
  ref.onDispose(() {
    if (identical(DiagnosticLogs.writer, sink)) DiagnosticLogs.writer = null;
    unawaited(expiration.cancel());
  });
  ref.listen(downloadQueueProvider, (old, next) {
    for (final job in next.tasks) {
      if (job.error != null &&
          !(old?.tasks.any(
                (v) => v.identity == job.identity && v.error == job.error,
              ) ??
              false)) {
        DiagnosticLogs.error('download', StateError(job.error!));
      }
    }
  });
  ref.listen(libraryUpdateReportProvider, (old, next) {
    if (next != null && !identical(old, next)) {
      for (final failure in next.failures) {
        DiagnosticLogs.error('source', StateError(failure.message));
      }
    }
  });
  ref.listen(automaticBackupStatusProvider, (old, next) {
    if (next.failure != null && next.failure != old?.failure) {
      DiagnosticLogs.error('backup', StateError(next.failure!));
    }
  });
});
