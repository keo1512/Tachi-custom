import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:html/parser.dart' as html_parser;

import '../domain/library_book.dart';
import 'backup_configuration.dart';
import '../../sources/domain/extension_backup.dart';

/// A consistent library image. Attachment references must already be hydrated.
class LibrarySnapshot {
  LibrarySnapshot(
    Iterable<LibrarySnapshotEntry> entries, {
    this.configuration,
    this.extensions,
  }) : entries = List.unmodifiable(entries);
  final List<LibrarySnapshotEntry> entries;
  final BackupConfiguration? configuration;
  final ExtensionBackup? extensions;
  static const maxBytes = 128 * 1024 * 1024;

  Map<String, dynamic> _metadata({required bool canonicalMedia}) => {
    'schema': 'tachi-books-backup',
    'version': 1,
    if (configuration != null)
      'configuration': configuration!.toJson(canonical: canonicalMedia),
    if (extensions != null) 'extensions': extensions!.toJson(),
  };

  List<LibrarySnapshotEntry> _orderedEntries() =>
      entries.toList()..sort((a, b) => a.book.id.compareTo(b.book.id));

  Map<String, dynamic> toJson({bool canonicalMedia = false}) {
    return {
      ..._metadata(canonicalMedia: canonicalMedia),
      'entries': _orderedEntries()
          .map((entry) => entry.toJson(canonicalMedia: canonicalMedia))
          .toList(),
    };
  }

  Uint8List encode({bool canonicalMedia = false}) {
    final bytes = BytesBuilder(copy: false);
    _writeEncoded(bytes.add, canonicalMedia: canonicalMedia);
    return bytes.takeBytes();
  }

  /// Checks the complete envelope without keeping a second copy of the library.
  void checkEncodedSize() => _writeEncoded((_) {});

  String get fingerprint {
    final result = _DigestSink();
    final sink = sha256.startChunkedConversion(result);
    _writeEncoded(sink.add, canonicalMedia: true);
    sink.close();
    return result.digest!.toString();
  }

  void _writeEncoded(
    void Function(List<int>) add, {
    bool canonicalMedia = false,
  }) {
    var size = 0;
    void write(String value) {
      final bytes = utf8.encode(value);
      size += bytes.length;
      if (size > maxBytes) {
        throw const FormatException('Bản sao lưu vượt giới hạn 128 MB.');
      }
      add(bytes);
    }

    // Preserve the exact v1 canonical bytes, including root-key order. Encode
    // one book at a time instead of constructing/copying every chapter's JSON.
    final root = _metadata(canonicalMedia: canonicalMedia)..['entries'] = null;
    final keys = root.keys.toList()..sort();
    write('{');
    for (var i = 0; i < keys.length; i++) {
      if (i > 0) write(',');
      final key = keys[i];
      write('${jsonEncode(key)}:');
      if (key == 'entries') {
        write('[');
        var first = true;
        for (final entry in _orderedEntries()) {
          if (!first) write(',');
          first = false;
          write(
            jsonEncode(
              _canonical(entry.toJson(canonicalMedia: canonicalMedia)),
            ),
          );
        }
        write(']');
      } else {
        write(jsonEncode(_canonical(root[key])));
      }
    }
    write('}');
  }
}

class _DigestSink implements Sink<Digest> {
  Digest? digest;
  @override
  void add(Digest data) => digest = data;
  @override
  void close() {}
}

class LibrarySnapshotEntry {
  LibrarySnapshotEntry(this.book, Map<int, ReaderContent> contents)
    : contents = Map.unmodifiable(contents);
  final LibraryBook book;
  final Map<int, ReaderContent> contents;

  Map<String, dynamic> toJson({bool canonicalMedia = false}) => {
    'book': {
      ...book.toJson(),
      if (canonicalMedia) 'cover': _image(book.cover),
      if (canonicalMedia && book.originalCover.isNotEmpty)
        'originalCover': _image(book.originalCover),
    },
    'contents': contents.map(
      (index, content) => MapEntry('$index', {
        ...content.toJson(),
        if (canonicalMedia) 'html': _html(content.html),
        if (canonicalMedia) 'images': content.images.map(_image).toList(),
      }),
    ),
  };
}

// Match native attachment hydration without changing the backup envelope.
String _image(String value) {
  if (!value.startsWith('data:image/')) return value;
  final data = UriData.parse(value);
  return 'data:${data.mimeType};base64,${base64Encode(data.contentAsBytes())}';
}

String _html(String value) {
  if (!value.contains('data:image/')) return value;
  final fragment = html_parser.parseFragment(value);
  for (final image in fragment.querySelectorAll('img[src]')) {
    image.attributes['src'] = _image(image.attributes['src']!);
  }
  return fragment.outerHtml;
}

Object? _canonical(Object? value) {
  if (value is Map) {
    final keys = value.keys.cast<String>().toList()..sort();
    return {for (final key in keys) key: _canonical(value[key])};
  }
  if (value is List) return value.map(_canonical).toList();
  return value;
}
