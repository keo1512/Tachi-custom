import 'dart:typed_data';

class SyncFailure implements Exception {
  const SyncFailure(this.message);
  final String message;
  @override
  String toString() => message;
}

class SyncHead {
  const SyncHead({
    required this.id,
    required this.parts,
    required this.digest,
    required this.bytes,
  });
  final String id, digest;
  final int parts, bytes;

  Map<String, Object> toJson() => {
    'id': id,
    'parts': parts,
    'digest': digest,
    'bytes': bytes,
  };
}

class SyncLink {
  const SyncLink({
    required this.uid,
    this.headId,
    this.fingerprint,
    this.enabled = false,
    this.lastSyncedAt,
  });
  final String uid;
  final String? headId, fingerprint;
  final bool enabled;
  final DateTime? lastSyncedAt;
}

abstract interface class SyncRemote {
  Future<SyncHead?> head();
  Future<Uint8List> download(SyncHead head);
  Future<SyncHead> publish(Uint8List bytes, {required String? expectedHead});
}

abstract interface class SyncLocal {
  SyncLink? get link;
  Future<void> saveLink(SyncLink link);
  Future<Uint8List> snapshot();
  void validate(Uint8List bytes);
  String fingerprint(Uint8List bytes);
  Future<void> replace(Uint8List bytes, {required String expectedFingerprint});
}

enum SyncOutcome { current, uploaded, downloaded, conflict, paused }

class SyncConflict {
  SyncConflict({
    required Uint8List local,
    required Uint8List remote,
    required this.head,
  }) : local = Uint8List.fromList(local),
       remote = Uint8List.fromList(remote);
  final Uint8List local, remote;
  final SyncHead head;
}

/// A snapshot is published before the head moves. Both head and local replacements
/// use compare-and-swap; a stale conflict decision never overwrites newer data.
class SyncEngine {
  SyncEngine({required this.uid, required this.local, required this.remote});
  final String uid;
  final SyncLocal local;
  final SyncRemote remote;
  SyncConflict? conflict;
  bool _busy = false;

  void _checkOwner() {
    final link = local.link;
    if (link != null && link.uid != uid) {
      throw const SyncFailure(
        'Thư viện này đã liên kết với tài khoản Google khác. Hãy đăng nhập tài khoản đã liên kết để bảo toàn dữ liệu.',
      );
    }
  }

  Future<T> _exclusive<T>(Future<T> Function() action) async {
    if (_busy) throw const SyncFailure('Đang đồng bộ, vui lòng chờ.');
    _busy = true;
    try {
      _checkOwner();
      return await action();
    } finally {
      _busy = false;
    }
  }

  Future<void> pause() => _exclusive(() async {
    final link = local.link;
    if (link != null) {
      await local.saveLink(
        SyncLink(
          uid: uid,
          headId: link.headId,
          fingerprint: link.fingerprint,
          enabled: false,
          lastSyncedAt: link.lastSyncedAt,
        ),
      );
    }
    conflict = null;
  });

  Future<void> _remember(SyncHead head, String fingerprint) => local.saveLink(
    SyncLink(
      uid: uid,
      headId: head.id,
      fingerprint: fingerprint,
      enabled: true,
      lastSyncedAt: DateTime.now().toUtc(),
    ),
  );

  Future<SyncOutcome> run({bool enable = false}) => _exclusive(() async {
    final before = local.link;
    if (!enable && before?.enabled != true) return SyncOutcome.paused;
    // Pin the owner before any network request; a failed first upload must not
    // permit a different account to publish this same local library.
    await local.saveLink(
      SyncLink(
        uid: uid,
        headId: before?.headId,
        fingerprint: before?.fingerprint,
        enabled: true,
        lastSyncedAt: before?.lastSyncedAt,
      ),
    );
    conflict = null;
    final source = await local.snapshot();
    local.validate(source);
    final fingerprint = local.fingerprint(source);
    final head = await remote.head();
    final localChanged = before?.fingerprint != fingerprint;
    if (head == null) {
      if (before?.headId != null) {
        throw const SyncFailure(
          'Không tìm thấy bản đã đồng bộ trên cloud. Dữ liệu trên máy được giữ nguyên.',
        );
      }
      final published = await remote.publish(source, expectedHead: null);
      await _remember(published, fingerprint);
      return SyncOutcome.uploaded;
    }
    if (head.id == before?.headId) {
      if (localChanged) {
        final published = await remote.publish(source, expectedHead: head.id);
        await _remember(published, fingerprint);
        return SyncOutcome.uploaded;
      }
      await _remember(head, fingerprint);
      return SyncOutcome.current;
    }
    final downloaded = await remote.download(head);
    local.validate(downloaded);
    final remoteFingerprint = local.fingerprint(downloaded);
    if (fingerprint == remoteFingerprint) {
      await _remember(head, fingerprint);
      return SyncOutcome.current;
    }
    if (localChanged) {
      conflict = SyncConflict(local: source, remote: downloaded, head: head);
      return SyncOutcome.conflict;
    }
    // Re-check the head after all chunks have arrived, before local mutation.
    if ((await remote.head())?.id != head.id) {
      throw const SyncFailure(
        'Bản cloud vừa thay đổi. Hãy đồng bộ lại để lấy bản mới nhất.',
      );
    }
    await local.replace(downloaded, expectedFingerprint: fingerprint);
    await _remember(head, remoteFingerprint);
    return SyncOutcome.downloaded;
  });

  Future<SyncOutcome> resolve({required bool keepLocal}) =>
      _exclusive(() async {
        final pending = conflict;
        if (pending == null) {
          throw const SyncFailure('Không còn xung đột cần giải quyết.');
        }
        final current = await local.snapshot();
        final originalFingerprint = local.fingerprint(pending.local);
        if (local.fingerprint(current) != originalFingerprint ||
            (await remote.head())?.id != pending.head.id) {
          conflict = null;
          throw const SyncFailure(
            'Dữ liệu đã thay đổi sau khi mở lựa chọn. Hãy đồng bộ lại trước khi chọn bản muốn giữ.',
          );
        }
        if (keepLocal) {
          final published = await remote.publish(
            current,
            expectedHead: pending.head.id,
          );
          await _remember(published, originalFingerprint);
          conflict = null;
          return SyncOutcome.uploaded;
        }
        local.validate(pending.remote);
        await local.replace(
          pending.remote,
          expectedFingerprint: originalFingerprint,
        );
        await _remember(pending.head, local.fingerprint(pending.remote));
        conflict = null;
        return SyncOutcome.downloaded;
      });
}
