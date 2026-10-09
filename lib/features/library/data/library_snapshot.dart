import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:html/parser.dart' as html_parser;

import '../domain/library_book.dart';

/// A consistent library image. Attachment references must already be hydrated.
class LibrarySnapshot {
  LibrarySnapshot(Iterable<LibrarySnapshotEntry> entries)
    : entries = List.unmodifiable(entries);
  final List<LibrarySnapshotEntry> entries;
  static const maxBytes = 128 * 1024 * 1024;

  Map<String, dynamic> toJson({bool canonicalMedia = false}) {
    final ordered = entries.toList()
      ..sort((a, b) => a.book.id.compareTo(b.book.id));
    return {
      'schema': 'tachi-books-backup',
      'version': 1,
      'entries': ordered
          .map((entry) => entry.toJson(canonicalMedia: canonicalMedia))
          .toList(),
    };
  }

  Uint8List encode({bool canonicalMedia = false}) {
    final bytes = Uint8List.fromList(
      utf8.encode(
        jsonEncode(_canonical(toJson(canonicalMedia: canonicalMedia))),
      ),
    );
    if (bytes.length > maxBytes) {
      throw const FormatException('Bản sao lưu vượt giới hạn 128 MB.');
    }
    return bytes;
  }

  String get fingerprint =>
      sha256.convert(encode(canonicalMedia: true)).toString();
}

class LibrarySnapshotEntry {
  LibrarySnapshotEntry(this.book, Map<int, ReaderContent> contents)
    : contents = Map.unmodifiable(contents);
  final LibraryBook book;
  final Map<int, ReaderContent> contents;

  Map<String, dynamic> toJson({bool canonicalMedia = false}) => {
    'book': {...book.toJson(), if (canonicalMedia) 'cover': _image(book.cover)},
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
