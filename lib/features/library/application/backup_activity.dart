import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../settings/settings_controller.dart';
import 'backup_service_provider.dart';

typedef BackupFileWriter = Future<String?> Function(
  String name,
  Uint8List bytes,
);
final backupFileWriterProvider = Provider<BackupFileWriter>(
  (ref) =>
      (name, bytes) async => (await FilePicker.saveFile(
        fileName: name,
        bytes: bytes,
        mimeType: 'application/json',
        dialogTitle: 'Lưu bản sao lưu TachiBooks',
      ))?.toString(),
);

/// Device-local evidence of successful operations. It is not restored from a
/// backup: opening another device must not imply a Files export happened there.
class BackupActivity {
  const BackupActivity({this.exportedAt, this.restoredAt});
  final DateTime? exportedAt, restoredAt;
  factory BackupActivity.decode(String? raw) {
    if (raw == null) return const BackupActivity();
    final value = jsonDecode(raw);
    if (value is! Map || value['version'] != 1) {
      throw const FormatException('Thông tin lần sao lưu không hợp lệ.');
    }
    DateTime? date(String key) =>
        value[key] == null ? null : DateTime.parse(value[key] as String);
    return BackupActivity(
      exportedAt: date('exportedAt'),
      restoredAt: date('restoredAt'),
    );
  }
  String encode() => jsonEncode({
    'version': 1,
    'exportedAt': exportedAt?.toUtc().toIso8601String(),
    'restoredAt': restoredAt?.toUtc().toIso8601String(),
  });
}

final backupActivityProvider =
    NotifierProvider<BackupActivityController, BackupActivity>(
      BackupActivityController.new,
    );

class BackupActivityController extends Notifier<BackupActivity> {
  static const key = 'backupActivityV1';
  Future<void> _pending = Future<void>.value();
  @override
  BackupActivity build() {
    try {
      return BackupActivity.decode(
        ref.watch(preferencesProvider).getString(key),
      );
    } catch (_) {
      return const BackupActivity();
    }
  }

  Future<void> restored({DateTime? at}) => _record(
    ref.read(preferencesProvider),
    export: false,
    at: at ?? DateTime.now(),
  );

  Future<bool> exportBackup({DateTime? at}) async {
    final preferences = ref.read(preferencesProvider);
    final service = ref.read(backupServiceProvider);
    final writer = ref.read(backupFileWriterProvider);
    final now = at ?? DateTime.now();
    final bytes = await service.export();
    final result = await writer(
      'tachibooks-${now.toIso8601String().substring(0, 10)}.json',
      bytes,
    );
    if (result == null) return false;
    await _record(preferences, export: true, at: now);
    return true;
  }

  Future<void> _record(
    SharedPreferences preferences, {
    required bool export,
    required DateTime at,
  }) {
    final next = _pending.then((_) async {
      final current = BackupActivity.decode(preferences.getString(key));
      final saved = BackupActivity(
        exportedAt: export ? at : current.exportedAt,
        restoredAt: export ? current.restoredAt : at,
      );
      if (!await preferences.setString(key, saved.encode())) {
        throw StateError(
          'Đã hoàn tất thao tác nhưng chưa lưu được thời điểm trên thiết bị.',
        );
      }
      if (ref.mounted) state = saved;
    });
    _pending = next.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return next;
  }
}
