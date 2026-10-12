import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../settings/settings_controller.dart';

enum AutomaticBackupRunStage { idle, running, succeeded, failed, interrupted }

/// Device-local status excludes book names, account data and filesystem paths.
class AutomaticBackupRunStatus {
  const AutomaticBackupRunStatus({
    this.stage = AutomaticBackupRunStage.idle,
    this.startedAt,
    this.finishedAt,
    this.fileName,
    this.bytes,
    this.failure,
  });
  final AutomaticBackupRunStage stage;
  final DateTime? startedAt, finishedAt;
  final String? fileName, failure;
  final int? bytes;
  String encode() => jsonEncode({
    'version': 1,
    'stage': stage.name,
    'startedAt': startedAt?.toUtc().toIso8601String(),
    'finishedAt': finishedAt?.toUtc().toIso8601String(),
    'fileName': fileName,
    'bytes': bytes,
    'failure': failure,
  });
  factory AutomaticBackupRunStatus.decode(
    String? raw, {
    bool afterRestart = false,
  }) {
    if (raw == null) return const AutomaticBackupRunStatus();
    final value = jsonDecode(raw);
    if (value is! Map || value['version'] != 1) {
      throw const FormatException('Trạng thái sao lưu không hợp lệ.');
    }
    var stage = AutomaticBackupRunStage.values.byName(value['stage'] as String);
    if (afterRestart && stage == AutomaticBackupRunStage.running) {
      stage = AutomaticBackupRunStage.interrupted;
    }
    return AutomaticBackupRunStatus(
      stage: stage,
      startedAt: value['startedAt'] == null
          ? null
          : DateTime.parse(value['startedAt'] as String),
      finishedAt: value['finishedAt'] == null
          ? null
          : DateTime.parse(value['finishedAt'] as String),
      fileName: value['fileName'] as String?,
      bytes: value['bytes'] as int?,
      failure: value['failure'] as String?,
    );
  }
}

final automaticBackupStatusProvider =
    NotifierProvider<AutomaticBackupStatusController, AutomaticBackupRunStatus>(
      AutomaticBackupStatusController.new,
    );

class AutomaticBackupStatusController
    extends Notifier<AutomaticBackupRunStatus> {
  static const key = 'automaticBackupStatusV1';
  @override
  AutomaticBackupRunStatus build() {
    try {
      return AutomaticBackupRunStatus.decode(
        ref.watch(preferencesProvider).getString(key),
        afterRestart: true,
      );
    } catch (_) {
      return const AutomaticBackupRunStatus();
    }
  }

  Future<void> record(AutomaticBackupRunStatus value) async {
    if (!await ref.read(preferencesProvider).setString(key, value.encode())) {
      throw StateError('Không lưu được trạng thái sao lưu trên thiết bị.');
    }
    if (ref.mounted) {
      state = value;
    }
  }
}

String automaticBackupFailure(Object error, {bool fileCreated = false}) {
  if (fileCreated) {
    return 'Bản sao lưu đã được tạo nhưng chưa lưu được thông tin hoàn tất. Kiểm tra các bản đã lưu bên dưới.';
  }
  if (error is FileSystemException) {
    return 'Không ghi được bản sao lưu. Kiểm tra dung lượng trống và thử lại.';
  }
  if (error is FormatException) {
    return 'Dữ liệu sao lưu không hợp lệ hoặc vượt giới hạn lưu trữ. Mở Chẩn đoán thư viện để kiểm tra.';
  }
  return 'Sao lưu chưa hoàn tất. Dữ liệu hiện tại và các bản đã lưu vẫn được giữ. Hãy thử lại.';
}
