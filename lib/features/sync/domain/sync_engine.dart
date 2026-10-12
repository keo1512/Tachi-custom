import 'dart:typed_data';

import 'sync_merge_plan.dart';

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
    this.format = 1,
  });
  final String id, digest;
  final int parts, bytes, format;

  Map<String, Object> toJson() => {
    'id': id,
    'parts': parts,
    'digest': digest,
    'bytes': bytes,
    if (format != 1) 'format': format,
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

abstract interface class SyncHistoryRemote {
  Future<Uint8List?> baseline(String headId);
}

enum SyncTransferDirection { upload, download }

class SyncTransferProgress {
  const SyncTransferProgress(
    this.direction,
    this.completed,
    this.total, {
    this.reused = 0,
  });
  final SyncTransferDirection direction;
  final int completed, total, reused;
}

abstract interface class SyncProgressRemote {
  set onProgress(void Function(SyncTransferProgress progress)? callback);
}

abstract interface class SyncLocal {
  SyncLink? get link;
  Future<void> saveLink(SyncLink link);
  Future<Uint8List> snapshot();
  void validate(Uint8List bytes);
  String fingerprint(Uint8List bytes);
  Future<void> replace(Uint8List bytes, {required String expectedFingerprint});
}

/// Projects an incoming snapshot to the image replacement will actually retain.
/// Inputs are validated snapshots. This must be pure and use the pinned current
/// bytes, so replacement still checks the original fingerprint with CAS.
abstract interface class SyncIncomingNormalizer {
  Uint8List normalizeIncoming(Uint8List incoming, {required Uint8List current});
}

enum SyncOutcome { current, uploaded, downloaded, conflict, paused }

class SyncConflict {
  SyncConflict({
    required Uint8List local,
    required Uint8List remote,
    required this.head,
    this.mergePlan,
  }) : local = Uint8List.fromList(local),
       remote = Uint8List.fromList(remote);
  final Uint8List local, remote;
  final SyncHead head;
  final SyncMergePlan? mergePlan;
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

  Uint8List _normalizeIncoming(Uint8List incoming, Uint8List current) {
    final result = local is SyncIncomingNormalizer
        ? (local as SyncIncomingNormalizer).normalizeIncoming(
            incoming,
            current: current,
          )
        : incoming;
    local.validate(result);
    return result;
  }

  Future<SyncOutcome> _receive(
    Uint8List incoming, {
    required Uint8List current,
    required String expectedFingerprint,
    required SyncHead head,
  }) async {
    final applied = _normalizeIncoming(incoming, current);
    final appliedFingerprint = local.fingerprint(applied);
    // Additive replacement can retain installed packages or omitted settings.
    // Publish the same applied image before CAS replacement, otherwise the link
    // would claim a cloud baseline different from the resulting local snapshot.
    final appliedHead = appliedFingerprint == local.fingerprint(incoming)
        ? head
        : await remote.publish(applied, expectedHead: head.id);
    if (appliedFingerprint != expectedFingerprint) {
      await local.replace(applied, expectedFingerprint: expectedFingerprint);
    }
    await _remember(appliedHead, appliedFingerprint);
    return SyncOutcome.downloaded;
  }

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
      Uint8List? baseline;
      if (before?.headId != null && remote is SyncHistoryRemote) {
        baseline = await (remote as SyncHistoryRemote).baseline(
          before!.headId!,
        );
        if (baseline != null) {
          local.validate(baseline);
          if (local.fingerprint(baseline) != before.fingerprint) {
            throw const SyncFailure(
              'Bản gốc đồng bộ không khớp. Không tự hợp nhất.',
            );
          }
        }
      }
      conflict = SyncConflict(
        local: source,
        remote: downloaded,
        head: head,
        mergePlan: SyncMergePlan.tryBuild(
          source,
          downloaded,
          baseline: baseline,
        ),
      );
      return SyncOutcome.conflict;
    }
    // Re-check the head after all chunks have arrived, before local mutation.
    if ((await remote.head())?.id != head.id) {
      throw const SyncFailure(
        'Bản cloud vừa thay đổi. Hãy đồng bộ lại để lấy bản mới nhất.',
      );
    }
    return _receive(
      downloaded,
      current: source,
      expectedFingerprint: fingerprint,
      head: head,
    );
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
        final outcome = await _receive(
          pending.remote,
          current: current,
          expectedFingerprint: originalFingerprint,
          head: pending.head,
        );
        conflict = null;
        return outcome;
      });

  Future<SyncOutcome> resolveRecords(Map<String, bool> keepLocal) => _exclusive(
    () async {
      final pending = conflict;
      final plan = pending?.mergePlan;
      if (pending == null || plan == null) {
        throw const SyncFailure('Không có bản xem trước hợp nhất.');
      }
      final current = await local.snapshot();
      final expected = local.fingerprint(pending.local);
      if (local.fingerprint(current) != expected ||
          (await remote.head())?.id != pending.head.id) {
        conflict = null;
        throw const SyncFailure(
          'Dữ liệu vừa thay đổi. Hãy đồng bộ lại trước khi hợp nhất.',
        );
      }
      final merged = _normalizeIncoming(plan.encode(keepLocal), current);
      // Publish CAS first; a concurrent local edit is still protected by the
      // repository CAS and remains dirty if the local replacement is rejected.
      final published = await remote.publish(
        merged,
        expectedHead: pending.head.id,
      );
      await local.replace(merged, expectedFingerprint: expected);
      await _remember(published, local.fingerprint(merged));
      conflict = null;
      return SyncOutcome.downloaded;
    },
  );
}
