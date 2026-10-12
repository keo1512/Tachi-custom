import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

class AttachmentStore {
  AttachmentStore._(this._directory);
  final Directory _directory;
  Directory get directory => _directory;
  static const _maxImageBytes = 8 * 1024 * 1024;
  static Future<AttachmentStore> open(String directory) async {
    final target = Directory('$directory/attachments');
    await target.create(recursive: true);
    return AttachmentStore._(target);
  }

  String _bookFolder(String id) => sha256.convert(utf8.encode(id)).toString();
  Future<String> store(String bookId, Uint8List bytes, String mediaType) async {
    if (bytes.length > _maxImageBytes) {
      throw const FormatException('Ảnh vượt giới hạn 8 MB.');
    }
    // Keep the digest and the staged bytes consistent across asynchronous writes.
    final content = Uint8List.fromList(bytes);
    final folder = _bookFolder(bookId);
    final digest = sha256.convert(content).toString();
    final directory = Directory('${_directory.path}/$folder');
    await directory.create(recursive: true);
    final file = File('${directory.path}/$digest');
    if (!await _matches(file, digest, content.length)) {
      final pendingDirectory = await directory.createTemp('.pending-');
      try {
        final pending = File('${pendingDirectory.path}/$digest');
        await pending.writeAsBytes(content, flush: true);
        // Another store may have completed while this temporary file was written.
        if (!await _matches(file, digest, content.length)) {
          try {
            await pending.rename(file.path);
          } on FileSystemException {
            if (!await _matches(file, digest, content.length)) rethrow;
          }
        }
      } finally {
        if (await pendingDirectory.exists()) {
          await pendingDirectory.delete(recursive: true);
        }
      }
    }
    return 'tachi-asset://$folder/$digest?type=${Uri.encodeComponent(mediaType)}';
  }

  Future<bool> _matches(File file, String digest, int length) async {
    try {
      if (await file.length() != length) return false;
      await _verifiedBytes(file, digest);
      return true;
    } on FileSystemException {
      return false;
    } on FormatException {
      return false;
    }
  }

  Future<Uint8List> _verifiedBytes(File file, String digest) async {
    if (await file.length() > _maxImageBytes) {
      throw const FormatException('Tệp thư viện vượt giới hạn 8 MB.');
    }
    final result = BytesBuilder(copy: false);
    await for (final chunk in file.openRead()) {
      if (result.length + chunk.length > _maxImageBytes) {
        throw const FormatException('Tệp thư viện vượt giới hạn 8 MB.');
      }
      result.add(chunk);
    }
    final bytes = result.takeBytes();
    if (sha256.convert(bytes).toString() != digest) {
      throw const FormatException('Tệp thư viện bị hỏng hoặc không đầy đủ.');
    }
    return bytes;
  }

  Future<String> resolve(String reference) async {
    if (!reference.startsWith('tachi-asset://')) return reference;
    final uri = Uri.parse(reference);
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(uri.host) ||
        !RegExp(r'^/[a-f0-9]{64}$').hasMatch(uri.path)) {
      throw const FormatException('Tham chiếu tệp thư viện không hợp lệ.');
    }
    final bytes = await _verifiedBytes(
      File('${_directory.path}/${uri.host}${uri.path}'),
      uri.path.substring(1),
    );
    return 'data:${uri.queryParameters['type'] ?? 'application/octet-stream'};base64,${base64Encode(bytes)}';
  }

  Future<void> removeBook(String bookId) async {
    final directory = Directory('${_directory.path}/${_bookFolder(bookId)}');
    if (await directory.exists()) await directory.delete(recursive: true);
  }

  /// Removes only selected content hashes which no surviving chapter/cover
  /// references. Never traverses directories or accepts a different book path.
  Future<void> removeUnreferenced(
    String bookId,
    Iterable<String> candidates,
    Iterable<String> retained,
  ) async {
    final folder = _bookFolder(bookId);
    String fileKey(String reference) {
      final uri = Uri.parse(reference);
      if (uri.scheme != 'tachi-asset' ||
          uri.host != folder ||
          !RegExp(r'^/[a-f0-9]{64}$').hasMatch(uri.path)) {
        throw const FormatException(
          'Tham chiếu xóa tệp thư viện không hợp lệ.',
        );
      }
      return uri.path.substring(1);
    }

    final keep = retained.map(fileKey).toSet();
    final remove = candidates.map(fileKey).toSet().difference(keep);
    for (final digest in remove) {
      final file = File('${_directory.path}/$folder/$digest');
      if (await file.exists()) await file.delete();
    }
  }

  Future<void> clear() async {
    if (await _directory.exists()) await _directory.delete(recursive: true);
    await _directory.create(recursive: true);
  }
}
