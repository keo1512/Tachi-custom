import 'dart:convert';
import 'dart:typed_data';

import '../domain/library_book.dart';

/// The legacy details.json fields used by local Tachiyomi/Mihon titles.
/// Unknown fields stay unused; malformed known fields fail before insertion.
class LocalComicMetadata {
  LocalComicMetadata._(this.values);
  final Map<String, dynamic> values;
  factory LocalComicMetadata.decode(Uint8List bytes) {
    if (bytes.length > 64 * 1024) {
      throw const FormatException('details.json vượt giới hạn 64 KB.');
    }
    final value = jsonDecode(utf8.decode(bytes));
    if (value is! Map<String, dynamic>) {
      throw const FormatException('details.json phải là một object JSON.');
    }
    for (final key in ['title', 'author', 'artist', 'description', 'series']) {
      if (value[key] != null && value[key] is! String) {
        throw FormatException('Trường $key trong details.json phải là chuỗi.');
      }
    }
    final genre = value['genre'] ?? value['genres'];
    if (genre != null &&
        (genre is! List ||
            genre.length > 1000 ||
            genre.any((item) => item is! String))) {
      throw const FormatException(
        'Thể loại trong details.json phải là danh sách chuỗi.',
      );
    }
    final status = value['status'];
    if (status != null && (status is! int || status < 0 || status > 7)) {
      throw const FormatException(
        'Trạng thái trong details.json phải từ 0 đến 7.',
      );
    }
    return LocalComicMetadata._(value);
  }

  LibraryBook apply(LibraryBook book) => book.copyWith(
    title: (values['title'] as String?)?.trim().isNotEmpty == true
        ? (values['title'] as String).trim()
        : book.title,
    author: values['author'] as String?,
    artist: values['artist'] as String?,
    description: values['description'] as String?,
    series: values['series'] as String?,
    genres: ((values['genre'] ?? values['genres']) as List?)?.cast<String>(),
    status: values['status'] as int?,
  );
}

String? localImageType(String name) =>
    switch (name.toLowerCase().split('.').last) {
      'png' => 'image/png',
      'jpg' || 'jpeg' => 'image/jpeg',
      'webp' => 'image/webp',
      'gif' => 'image/gif',
      'avif' => 'image/avif',
      'heic' => 'image/heic',
      'heif' => 'image/heif',
      'jxl' => 'image/jxl',
      _ => null,
    };

int naturalFileCompare(String left, String right) {
  final a = RegExp(r'\d+|\D+')
      .allMatches(left.toLowerCase())
      .map((match) => match.group(0)!)
      .toList();
  final b = RegExp(r'\d+|\D+')
      .allMatches(right.toLowerCase())
      .map((match) => match.group(0)!)
      .toList();
  for (var index = 0; index < a.length && index < b.length; index++) {
    final ai = BigInt.tryParse(a[index]), bi = BigInt.tryParse(b[index]);
    final comparison = ai != null && bi != null
        ? ai.compareTo(bi)
        : a[index].compareTo(b[index]);
    if (comparison != 0) return comparison;
  }
  final comparison = a.length.compareTo(b.length);
  return comparison != 0 ? comparison : left.compareTo(right);
}
