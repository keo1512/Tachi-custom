import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../domain/sync_engine.dart';

class SyncLinkStore {
  SyncLinkStore(this.preferences);
  final SharedPreferences preferences;
  static const key = 'tachiBooksSyncLinkV1';

  SyncLink? read() {
    final source = preferences.getString(key);
    if (source == null) return null;
    try {
      final json = jsonDecode(source);
      if (json is! Map ||
          json['version'] != 1 ||
          json['uid'] is! String ||
          (json['uid'] as String).isEmpty ||
          json['enabled'] is! bool ||
          (json['headId'] != null &&
              (json['headId'] is! String ||
                  !RegExp(r'^[a-f0-9]{32}$')
                      .hasMatch(json['headId'] as String))) ||
          (json['fingerprint'] != null &&
              (json['fingerprint'] is! String ||
                  !RegExp(r'^[a-f0-9]{64}$')
                      .hasMatch(json['fingerprint'] as String))) ||
          (json['lastSyncedAt'] != null && json['lastSyncedAt'] is! String)) {
        throw const FormatException();
      }
      final last = json['lastSyncedAt'] as String?;
      return SyncLink(
        uid: json['uid'] as String,
        enabled: json['enabled'] as bool,
        headId: json['headId'] as String?,
        fingerprint: json['fingerprint'] as String?,
        lastSyncedAt: last == null ? null : DateTime.parse(last),
      );
    } catch (_) {
      throw const SyncFailure(
        'Thông tin liên kết cloud trên máy bị lỗi. Dữ liệu được giữ nguyên; không tự đặt lại liên kết.',
      );
    }
  }

  Future<void> save(SyncLink link) async {
    final saved = await preferences.setString(
      key,
      jsonEncode({
        'version': 1,
        'uid': link.uid,
        'headId': link.headId,
        'fingerprint': link.fingerprint,
        'enabled': link.enabled,
        'lastSyncedAt': link.lastSyncedAt?.toUtc().toIso8601String(),
      }),
    );
    if (!saved) {
      throw const SyncFailure('Không lưu được trạng thái liên kết cloud.');
    }
  }
}
