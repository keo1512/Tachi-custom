import 'dart:convert';
import 'dart:typed_data';

import '../../library/data/backup_service.dart';
import '../../sources/domain/extension_backup.dart';
import '../domain/sync_engine.dart';
import 'sync_link_store.dart';

class BackupSyncLocal implements SyncLocal, SyncIncomingNormalizer {
  BackupSyncLocal({
    required this.backup,
    required this.links,
    this.beforeSnapshot,
    this.beforeCapture,
  });
  final BackupService backup;
  final SyncLinkStore links;
  final Future<void> Function()? beforeSnapshot;
  final void Function()? beforeCapture;

  @override
  SyncLink? get link => links.read();
  @override
  Future<void> saveLink(SyncLink link) => links.save(link);
  @override
  Future<Uint8List> snapshot() async {
    await beforeSnapshot?.call();
    return backup.export(beforeCapture: beforeCapture);
  }

  @override
  void validate(Uint8List bytes) => backup.validate(bytes);
  @override
  String fingerprint(Uint8List bytes) => backup.fingerprint(bytes);
  @override
  Uint8List normalizeIncoming(
    Uint8List incoming, {
    required Uint8List current,
  }) {
    final next = jsonDecode(utf8.decode(incoming)) as Map<String, dynamic>,
        before = jsonDecode(utf8.decode(current)) as Map<String, dynamic>;
    // Backup replacement keeps configuration when an older snapshot omits it.
    // Publish that applied image so its cloud/link fingerprint stays truthful.
    if (!next.containsKey('configuration') &&
        before.containsKey('configuration')) {
      next['configuration'] = before['configuration'];
    }
    if (before['extensions'] != null) {
      final retained = ExtensionBackup.fromJson(before['extensions']);
      final selected = next['extensions'] == null
          ? ExtensionBackup(const [])
          : ExtensionBackup.fromJson(next['extensions']);
      next['extensions'] = ExtensionBackup(
        {
          for (final package in retained.packages) package.identity: package,
          // An explicit incoming package replaces the same installed identity;
          // packages absent from the incoming image are never uninstalled.
          for (final package in selected.packages) package.identity: package,
        }.values,
      ).toJson();
    }
    return Uint8List.fromList(utf8.encode(jsonEncode(next)));
  }

  @override
  Future<void> replace(
    Uint8List bytes, {
    required String expectedFingerprint,
  }) async {
    await backup.replace(bytes, expectedFingerprint: expectedFingerprint);
  }
}
