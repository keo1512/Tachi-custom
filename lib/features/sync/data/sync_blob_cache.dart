import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';

import 'sync_chunk_plan.dart';

abstract interface class SyncBlobCache {
  Future<Uint8List?> read(String hash);
  Future<void> write(String hash, Uint8List bytes);
}

/// A disposable download cache, separate from library attachments and backups.
/// Every reuse checks the digest. Losing it only requires downloading again.
class FileSyncBlobCache implements SyncBlobCache {
  FileSyncBlobCache(this.uid, {this.directory});
  final String uid;
  final Directory? directory;
  Future<File> _file(String hash) async {
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(hash)) {
      throw const FormatException('Mã nội dung đồng bộ không hợp lệ.');
    }
    final root = directory ?? await getApplicationCacheDirectory();
    final owner = sha256.convert(utf8.encode(uid)).toString();
    final folder = Directory('${root.path}/sync-v2/$owner');
    await folder.create(recursive: true);
    return File('${folder.path}/$hash');
  }

  @override
  Future<Uint8List?> read(String hash) async {
    try {
      final file = await _file(hash);
      if (!await file.exists() ||
          await file.length() > SyncChunkPlan.chunkBytes) {
        return null;
      }
      final bytes = await file.readAsBytes();
      return sha256.convert(bytes).toString() == hash ? bytes : null;
    } on FileSystemException {
      return null;
    }
  }

  @override
  Future<void> write(String hash, Uint8List bytes) async {
    if (bytes.length > SyncChunkPlan.chunkBytes ||
        sha256.convert(bytes).toString() != hash) {
      throw const FormatException('Nội dung đồng bộ không khớp mã kiểm tra.');
    }
    try {
      final target = await _file(hash);
      if (await read(hash) != null) return;
      final temporary = File('${target.path}.pending');
      await temporary.writeAsBytes(bytes, flush: true);
      await temporary.rename(target.path);
    } on FileSystemException {
      // Cache writes must never turn a verified cloud/library operation into
      // failure. A later download will retry missing or invalid cached pieces.
    }
  }
}
