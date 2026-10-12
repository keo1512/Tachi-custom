import 'dart:convert';

import 'library_mutation.dart';
import 'library_snapshot.dart';

class LibraryCacheMaintenanceResult {
  const LibraryCacheMaintenanceResult({
    this.removedChapters = 0,
    this.removedFiles = 0,
    this.reclaimedBytes = 0,
  });
  final int removedChapters, removedFiles, reclaimedBytes;
}

class LibraryStorageReport {
  const LibraryStorageReport({
    required this.fingerprint,
    required this.revision,
    required this.transientChapters,
    required this.offlineChapters,
    required this.localBooks,
    this.downloadedBytes,
    this.unusedAttachmentFiles = 0,
    this.unusedAttachmentBytes = 0,
  });
  final String fingerprint;
  final int revision, transientChapters, offlineChapters, localBooks;

  /// Native stored text bytes plus unique referenced attachment file bytes.
  /// Null when the storage implementation cannot measure its actual bytes.
  final int? downloadedBytes;
  final int unusedAttachmentFiles, unusedAttachmentBytes;
}

List<({String bookId, int index})> transientChapterKeys(
  LibrarySnapshot image,
) => [
  for (final entry in image.entries)
    if (entry.book.engine != 'local')
      for (final content in entry.contents.entries)
        if (content.key >= 0 &&
            content.key < entry.book.chapters.length &&
            !entry.book.chapters[content.key].downloaded &&
            !chapterIsOffline(content.value))
          (bookId: entry.book.id, index: content.key),
];

LibraryStorageReport snapshotStorageReport(
  LibrarySnapshot image,
  int revision, {
  int? downloadedBytes,
  int unusedAttachmentFiles = 0,
  int unusedAttachmentBytes = 0,
}) => LibraryStorageReport(
  fingerprint: image.fingerprint,
  revision: revision,
  transientChapters: transientChapterKeys(image).length,
  offlineChapters: image.entries.fold(
    0,
    (count, entry) =>
        count + entry.contents.values.where(chapterIsOffline).length,
  ),
  localBooks: image.entries
      .where((entry) => entry.book.engine == 'local')
      .length,
  downloadedBytes: downloadedBytes,
  unusedAttachmentFiles: unusedAttachmentFiles,
  unusedAttachmentBytes: unusedAttachmentBytes,
);

/// Collect references from every parsed raw value, including unknown metadata.
/// It is intentionally conservative: an unrecognized reference blocks cleanup.
Set<String> rawAttachmentKeys(Object? value) {
  final keys = <String>{};
  void visit(Object? item) {
    if (item is Map) {
      for (final entry in item.entries) {
        visit(entry.key);
        visit(entry.value);
      }
    } else if (item is List) {
      for (final value in item) {
        visit(value);
      }
    } else if (item is String && item.contains('tachi-asset://')) {
      if (item.trimLeft().startsWith('{') || item.trimLeft().startsWith('[')) {
        try {
          visit(jsonDecode(item));
          return;
        } on FormatException {
          // Retain the conservative URI scan for opaque non-JSON text.
        }
      }
      final matches = RegExp(r'''tachi-asset://[^\s"'<>]+''').allMatches(item);
      for (final match in matches) {
        var source = match.group(0)!;
        // Raw headers may contain a URI surrounded by punctuation. Never
        // loosen the host/path allowlist or traverse a decoded URI path.
        final uri = Uri.tryParse(source);
        if (uri == null ||
            uri.scheme != 'tachi-asset' ||
            !RegExp(r'^[a-f0-9]{64}$').hasMatch(uri.host) ||
            !RegExp(r'^/[a-f0-9]{64}$').hasMatch(uri.path) ||
            uri.userInfo.isNotEmpty ||
            uri.port != 0 ||
            uri.fragment.isNotEmpty) {
          throw const FormatException(
            'Có tham chiếu tệp chưa nhận diện; chưa dọn dữ liệu.',
          );
        }
        keys.add('${uri.host}${uri.path}');
      }
      if (matches.isEmpty) {
        throw const FormatException(
          'Có tham chiếu tệp chưa nhận diện; chưa dọn dữ liệu.',
        );
      }
    }
  }

  visit(value);
  return keys;
}

int utf8Bytes(String value) => utf8.encode(value).length;
