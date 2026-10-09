import 'dart:typed_data';

import '../../library/data/backup_service.dart';
import '../domain/sync_engine.dart';
import 'sync_link_store.dart';

class BackupSyncLocal implements SyncLocal {
  BackupSyncLocal({required this.backup, required this.links});
  final BackupService backup;
  final SyncLinkStore links;

  @override
  SyncLink? get link => links.read();
  @override
  Future<void> saveLink(SyncLink link) => links.save(link);
  @override
  Future<Uint8List> snapshot() => backup.export();
  @override
  void validate(Uint8List bytes) => backup.validate(bytes);
  @override
  String fingerprint(Uint8List bytes) => backup.fingerprint(bytes);
  @override
  Future<void> replace(
    Uint8List bytes, {
    required String expectedFingerprint,
  }) async {
    await backup.replace(bytes, expectedFingerprint: expectedFingerprint);
  }
}
