import 'dart:convert';
import 'dart:typed_data';

class AttachmentStore {
  static Future<AttachmentStore> open(String directory) async =>
      AttachmentStore();
  Future<String> store(
    String bookId,
    Uint8List bytes,
    String mediaType,
  ) async => 'data:$mediaType;base64,${base64Encode(bytes)}';
  Future<String> resolve(String reference) async => reference;
  Future<void> removeBook(String bookId) async {}
  Future<void> clear() async {}
}
