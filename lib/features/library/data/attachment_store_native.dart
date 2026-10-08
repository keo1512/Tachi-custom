import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

class AttachmentStore {
  AttachmentStore._(this._directory);
  final Directory _directory;
  static Future<AttachmentStore> open(String directory) async {
    final target = Directory('$directory/attachments');
    await target.create(recursive: true);
    return AttachmentStore._(target);
  }

  String _bookFolder(String id) => sha256.convert(utf8.encode(id)).toString();
  Future<String> store(String bookId, Uint8List bytes, String mediaType) async {
    final folder = _bookFolder(bookId);
    final digest = sha256.convert(bytes).toString();
    final directory = Directory('${_directory.path}/$folder');
    await directory.create(recursive: true);
    final file = File('${directory.path}/$digest');
    if (!await file.exists()) await file.writeAsBytes(bytes, flush: true);
    return 'tachi-asset://$folder/$digest?type=${Uri.encodeComponent(mediaType)}';
  }

  Future<String> resolve(String reference) async {
    if (!reference.startsWith('tachi-asset://')) return reference;
    final uri = Uri.parse(reference);
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(uri.host) ||
        !RegExp(r'^/[a-f0-9]{64}$').hasMatch(uri.path)) {
      throw const FormatException('Tham chiếu tệp thư viện không hợp lệ.');
    }
    final bytes = await File('${_directory.path}/${uri.host}${uri.path}')
        .readAsBytes();
    return 'data:${uri.queryParameters['type'] ?? 'application/octet-stream'};base64,${base64Encode(bytes)}';
  }

  Future<void> removeBook(String bookId) async {
    final directory = Directory('${_directory.path}/${_bookFolder(bookId)}');
    if (await directory.exists()) await directory.delete(recursive: true);
  }

  Future<void> clear() async {
    if (await _directory.exists()) await _directory.delete(recursive: true);
    await _directory.create(recursive: true);
  }
}
