import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:crypto/crypto.dart';
import 'package:firebase_auth/firebase_auth.dart';

import '../../library/data/library_snapshot.dart';
import '../domain/sync_engine.dart';
import 'sync_blob_cache.dart';
import 'sync_chunk_plan.dart';
import 'sync_manifest_cache.dart';

/// A separate collection from every other application in the Firebase project.
/// Full backups, including cached chapter contents, are chunked below 1 MiB.
class FirestoreSyncRemote
    implements SyncRemote, SyncHistoryRemote, SyncProgressRemote {
  FirestoreSyncRemote({
    required this.uid,
    required this.db,
    required this.auth,
    SyncBlobCache? cache,
  }) : cache = cache ?? FileSyncBlobCache(uid);
  final String uid;
  final FirebaseFirestore db;
  final FirebaseAuth auth;
  final SyncBlobCache cache;
  @override
  void Function(SyncTransferProgress progress)? onProgress;
  static const namespace = 'tachiBooksUsers';
  static const schema = 'tachi-books-cloud-1';
  static const incrementalSchema = 'tachi-books-cloud-2';
  static const maxBytes = LibrarySnapshot.maxBytes;
  static const partLength = 700000;
  static const maxParts = 256;
  DocumentReference<Map<String, dynamic>> get _head =>
      db.doc('$namespace/$uid/sync/head');
  CollectionReference<Map<String, dynamic>> get _snapshots =>
      db.collection('$namespace/$uid/snapshots');
  CollectionReference<Map<String, dynamic>> get _blobs =>
      db.collection('$namespace/$uid/blobs');
  final _manifests = SyncManifestCache();

  void _checkSession() {
    if (auth.currentUser?.uid != uid) {
      throw const SyncFailure(
        'Tài khoản đã thay đổi. Hãy đăng nhập lại trước khi đồng bộ.',
      );
    }
  }

  static SyncHead parseHead(Map<String, dynamic> json) {
    if (json['id'] is! String ||
        !RegExp(r'^[a-f0-9]{32}$').hasMatch(json['id'] as String) ||
        json['digest'] is! String ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(json['digest'] as String) ||
        json['parts'] is! int ||
        (json['parts'] as int) < 1 ||
        (json['parts'] as int) > maxParts ||
        json['bytes'] is! int ||
        (json['bytes'] as int) < 1 ||
        (json['bytes'] as int) > maxBytes ||
        (json.containsKey('format') &&
            (json['format'] is! int ||
                (json['format'] != 1 && json['format'] != 2)))) {
      throw const SyncFailure(
        'Thông tin bản sao lưu cloud không hợp lệ. Dữ liệu trên máy được giữ nguyên.',
      );
    }
    final bytes = json['bytes'] as int;
    final base64Length = ((bytes + 2) ~/ 3) * 4;
    if (json['parts'] != (base64Length + partLength - 1) ~/ partLength) {
      throw const SyncFailure(
        'Số phần của bản sao lưu cloud không khớp kích thước.',
      );
    }
    return SyncHead(
      id: json['id'] as String,
      digest: json['digest'] as String,
      parts: json['parts'] as int,
      bytes: bytes,
      format: json['format'] as int? ?? 1,
    );
  }

  static List<SyncHead> _retained(Map<String, dynamic> json) {
    if (![schema, incrementalSchema].contains(json['schema']) ||
        json['retained'] is! List) {
      throw const SyncFailure(
        'Định dạng cloud chưa được hỗ trợ. Không ghi đè bản đã có.',
      );
    }
    final current = parseHead(json);
    final raw = json['retained'] as List;
    if (raw.isEmpty ||
        raw.length > 3 ||
        raw.any((item) => item is! Map<String, dynamic>)) {
      throw const SyncFailure('Danh sách bản sao lưu cloud không hợp lệ.');
    }
    final heads = raw
        .map((item) => parseHead(item as Map<String, dynamic>))
        .toList();
    if (heads.first.id != current.id ||
        heads.first.digest != current.digest ||
        heads.first.bytes != current.bytes ||
        heads.first.parts != current.parts ||
        heads.first.format != current.format ||
        (json['schema'] == incrementalSchema) != (current.format == 2) ||
        heads.map((head) => head.id).toSet().length != heads.length) {
      throw const SyncFailure(
        'Danh sách bản sao lưu cloud không khớp bản hiện tại.',
      );
    }
    return heads;
  }

  Future<Map<String, dynamic>?> _readHead() async {
    _checkSession();
    final result = await _head.get(const GetOptions(source: Source.server));
    _checkSession();
    final data = result.data();
    if (data != null) _retained(data);
    return data;
  }

  @override
  Future<SyncHead?> head() async {
    final data = await _readHead();
    return data == null ? null : parseHead(data);
  }

  @override
  Future<Uint8List> download(SyncHead head) async {
    final bytes = await _downloadManifest(head);
    if (head.format == 1) return bytes;
    final inventory = SyncChunkPlan.inventory(bytes);
    final chunks = <String, Uint8List>{};
    final total = inventory.values.fold<int>(0, (a, b) => a + b);
    var completed = 0, reused = 0;
    onProgress?.call(
      SyncTransferProgress(SyncTransferDirection.download, 0, total),
    );
    for (final entry in inventory.entries) {
      _checkSession();
      var chunk = await cache.read(entry.key);
      if (chunk == null || chunk.length != entry.value) {
        final doc = await _blobs
            .doc(entry.key)
            .get(const GetOptions(source: Source.server));
        _checkSession();
        final data = doc.data();
        if (data == null ||
            data['bytes'] != entry.value ||
            data['data'] is! String ||
            (data['data'] as String).length > 524288) {
          throw const SyncFailure(
            'Cloud thiếu phần nội dung. Dữ liệu trên máy được giữ nguyên.',
          );
        }
        try {
          chunk = base64Decode(data['data'] as String);
        } catch (_) {
          throw const SyncFailure('Phần nội dung cloud bị lỗi.');
        }
        if (chunk.length != entry.value ||
            sha256.convert(chunk).toString() != entry.key) {
          throw const SyncFailure(
            'Phần nội dung cloud không khớp mã kiểm tra.',
          );
        }
        await cache.write(entry.key, chunk);
      } else {
        reused += chunk.length;
      }
      chunks[entry.key] = chunk;
      completed += chunk.length;
      onProgress?.call(
        SyncTransferProgress(
          SyncTransferDirection.download,
          completed,
          total,
          reused: reused,
        ),
      );
    }
    return SyncChunkPlan.assemble(bytes, chunks);
  }

  @override
  Future<Uint8List?> baseline(String headId) async {
    if (!RegExp(r'^[a-f0-9]{32}$').hasMatch(headId)) return null;
    _checkSession();
    final data =
        (await _snapshots
                .doc(headId)
                .get(const GetOptions(source: Source.server)))
            .data();
    _checkSession();
    if (data == null) return null;
    return download(parseHead(data));
  }

  Future<Uint8List> _downloadManifest(SyncHead head) async {
    _checkSession();
    // Validate an injected or retained head as strictly as a server head.
    parseHead(head.toJson());
    if (head.format == 2) {
      final cached = _manifests.get(head.id);
      if (cached != null &&
          cached.length == head.bytes &&
          sha256.convert(cached).toString() == head.digest) {
        return cached;
      }
    }
    final encoded = StringBuffer();
    for (var index = 0; index < head.parts; index++) {
      _checkSession();
      final part = await _snapshots
          .doc(head.id)
          .collection('parts')
          .doc('$index')
          .get(const GetOptions(source: Source.server));
      _checkSession();
      final data = part.data()?['data'];
      if (data is! String ||
          data.isEmpty ||
          data.length > partLength ||
          (index < head.parts - 1 && data.length != partLength)) {
        throw const SyncFailure(
          'Bản sao lưu cloud thiếu phần hoặc bị lỗi. Dữ liệu trên máy được giữ nguyên.',
        );
      }
      encoded.write(data);
      if (head.format == 1) {
        onProgress?.call(
          SyncTransferProgress(
            SyncTransferDirection.download,
            min(((index + 1) * partLength * 3) ~/ 4, head.bytes),
            head.bytes,
          ),
        );
      }
    }
    Uint8List bytes;
    try {
      bytes = base64Decode(encoded.toString());
    } catch (_) {
      throw const SyncFailure('Nội dung bản sao lưu cloud bị lỗi.');
    }
    if (bytes.length != head.bytes ||
        sha256.convert(bytes).toString() != head.digest) {
      throw const SyncFailure(
        'Bản sao lưu cloud không khớp mã kiểm tra. Dữ liệu trên máy được giữ nguyên.',
      );
    }
    if (head.format == 2) {
      // Retain only the tiny immutable manifests, never unbounded media here.
      _manifests.put(head.id, bytes);
    }
    return bytes;
  }

  @override
  Future<SyncHead> publish(
    Uint8List bytes, {
    required String? expectedHead,
  }) async {
    _checkSession();
    if (bytes.isEmpty || bytes.length > maxBytes) {
      throw const SyncFailure(
        'Đồng bộ hỗ trợ bản sao lưu đầy đủ tối đa 128 MiB, cùng giới hạn xuất file. Thư viện lớn hơn vẫn được giữ trên máy; không tự bỏ nội dung để tải lên.',
      );
    }
    final plan = SyncChunkPlan.build(bytes);
    final existing = await head();
    if (existing?.id != expectedHead) {
      throw const SyncFailure('Cloud vừa thay đổi. Hãy đồng bộ lại.');
    }
    final known = existing?.format == 2
        ? SyncChunkPlan.inventory(await _downloadManifest(existing!)).keys
              .toSet()
        : <String>{};
    final total = plan.chunks.values.fold<int>(0, (a, b) => a + b.length);
    var completed = 0, reused = 0;
    onProgress?.call(
      SyncTransferProgress(SyncTransferDirection.upload, 0, total),
    );
    for (final entry in plan.chunks.entries) {
      _checkSession();
      if (!known.contains(entry.key)) {
        // Immutable blobs can already exist after an interrupted publish. A
        // transaction verifies them before reuse and never overwrites bytes.
        await db.runTransaction((tx) async {
          final doc = _blobs.doc(entry.key);
          final found = (await tx.get(doc)).data();
          _checkSession();
          final encoded = base64Encode(entry.value);
          if (found == null) {
            tx.set(doc, {'bytes': entry.value.length, 'data': encoded});
          } else if (found['bytes'] != entry.value.length ||
              found['data'] != encoded) {
            throw const SyncFailure(
              'Nội dung đã lưu trên cloud không khớp mã kiểm tra.',
            );
          }
        });
      } else {
        reused += entry.value.length;
      }
      await cache.write(entry.key, entry.value);
      completed += entry.value.length;
      onProgress?.call(
        SyncTransferProgress(
          SyncTransferDirection.upload,
          completed,
          total,
          reused: reused,
        ),
      );
    }
    // Schema 1 remains readable. New snapshots use an explicit schema 2 so old
    // apps reject an unfamiliar format instead of restoring incomplete media.
    bytes = plan.manifest;
    final random = Random.secure();
    final id = List.generate(
      16,
      (_) => random.nextInt(256),
    ).map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
    final encoded = base64Encode(bytes);
    final parts = (encoded.length + partLength - 1) ~/ partLength;
    final next = SyncHead(
      id: id,
      parts: parts,
      digest: sha256.convert(bytes).toString(),
      bytes: bytes.length,
      format: 2,
    );
    // All parts must reach the server before the compare-and-swap head commit.
    for (var start = 0; start < parts; start += 8) {
      _checkSession();
      final batch = db.batch();
      if (start == 0) {
        batch.set(_snapshots.doc(id), {
          ...next.toJson(),
          'schema': incrementalSchema,
          'createdAt': FieldValue.serverTimestamp(),
        });
      }
      for (var index = start; index < min(start + 8, parts); index++) {
        batch.set(_snapshots.doc(id).collection('parts').doc('$index'), {
          'data': encoded.substring(
            index * partLength,
            min((index + 1) * partLength, encoded.length),
          ),
        });
      }
      await batch.commit();
      _checkSession();
    }
    final dropped = await db.runTransaction<List<SyncHead>>((
      transaction,
    ) async {
      _checkSession();
      final existing = (await transaction.get(_head)).data();
      final retained = existing == null ? <SyncHead>[] : _retained(existing);
      if ((existing == null ? null : parseHead(existing).id) != expectedHead) {
        throw const SyncFailure(
          'Cloud vừa thay đổi trên thiết bị khác. Hãy đồng bộ lại trước khi tải lên.',
        );
      }
      final history = [next, ...retained];
      transaction.set(_head, {
        ...next.toJson(),
        'schema': incrementalSchema,
        'retained': history.take(3).map((head) => head.toJson()).toList(),
        'updatedAt': FieldValue.serverTimestamp(),
      });
      return history.skip(3).toList();
    });
    _checkSession();
    _manifests.put(next.id, bytes);
    // A cleanup failure cannot turn a committed upload into a failed sync. It
    // retains older bytes; unknown/orphan snapshots are not deleted automatically.
    // Never delete unknown IDs or a currently retained snapshot.
    for (final old in dropped) {
      try {
        await _prune(old);
      } catch (_) {
        /* Keep bytes if deletion is unproven. */
      }
    }
    return next;
  }

  Future<void> _prune(SyncHead old) async {
    final data = await _readHead();
    if (data == null || _retained(data).any((head) => head.id == old.id)) {
      return;
    }
    // IDs are immutable and never reused by this protocol. Once dropped from
    // the retained chain, a later publish cannot reintroduce this ID.
    _checkSession();
    for (var start = 0; start < old.parts; start += 8) {
      _checkSession();
      final batch = db.batch();
      for (var index = start; index < min(start + 8, old.parts); index++) {
        batch.delete(_snapshots.doc(old.id).collection('parts').doc('$index'));
      }
      await batch.commit();
      _checkSession();
    }
    // Delete the immutable manifest only after every bounded deletion batch.
    await _snapshots.doc(old.id).delete();
    _checkSession();
  }
}
