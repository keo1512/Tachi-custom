import 'dart:typed_data';

enum SourceEngine { tachimanga, vbook }

enum ContentKind { manga, novel }

enum SourceBrowseMode { popular, latest }

class CatalogueSource {
  const CatalogueSource({
    required this.id,
    required this.name,
    required this.lang,
    required this.baseUrl,
    required this.kind,
    required this.engine,
    this.iconUrl = '',
  });

  // Source IDs remain strings: Tachiyomi IDs can exceed JavaScript's safe range.
  final String id;
  final String name;
  final String lang;
  final String baseUrl;
  final String iconUrl;
  final ContentKind kind;
  final SourceEngine engine;

  String get identity => '${engine.name}:$id';
}

class CatalogueBook {
  const CatalogueBook({
    required this.ref,
    required this.title,
    this.author = '',
    this.artist = '',
    this.genres = const [],
    this.description = '',
    this.coverUrl = '',
    this.status = 0,
    required this.sourceId,
    required this.kind,
    required this.engine,
  });

  final String ref;
  final String title;
  final String author;
  final String artist;
  final List<String> genres;
  final String description;
  final String coverUrl;
  final String sourceId;
  final int status;
  final ContentKind kind;
  final SourceEngine engine;

  String get identity => '${engine.name}:$sourceId:$ref';
}

class CatalogueChapter {
  const CatalogueChapter({
    required this.ref,
    required this.title,
    required this.index,
    this.number,
    this.uploadedAt,
    this.scanlator = '',
  });

  final String ref;
  final String title;
  final int index;
  final double? number;
  final DateTime? uploadedAt;
  final String scanlator;
}

DateTime? catalogueUploadDate(Object? value) {
  if (value is! num ||
      !value.isFinite ||
      value <= 0 ||
      value > 8640000000000000) {
    return null;
  }
  return DateTime.fromMillisecondsSinceEpoch(value.toInt());
}

double? catalogueChapterNumber(Object? value) =>
    value is num && value.isFinite && value >= 0 ? value.toDouble() : null;

int catalogueStatus(Object? value) => switch (value) {
  int number when number >= 0 && number <= 6 => number,
  'ONGOING' => 1,
  'COMPLETED' => 2,
  'LICENSED' => 3,
  'PUBLISHING_FINISHED' => 4,
  'CANCELLED' => 5,
  'ON_HIATUS' => 6,
  _ => 0,
};

class ChapterContent {
  const ChapterContent({
    required this.kind,
    this.html = '',
    this.images = const [],
    this.headers = const {},
    this.imageHeaders = const {},
  });

  final ContentKind kind;
  final String html;
  final List<String> images;
  final Map<String, String> headers;
  final Map<String, Map<String, String>> imageHeaders;

  Map<String, String> headersFor(String url) => {
    ...headers,
    ...?imageHeaders[url],
  };
}

class SourceImageData {
  const SourceImageData({required this.bytes, required this.mimeType});

  final Uint8List bytes;
  final String mimeType;
}

class CatalogueExtension {
  const CatalogueExtension({
    required this.id,
    required this.name,
    required this.version,
    required this.engine,
    this.installed = false,
    this.packageUrl = '',
    this.iconUrl = '',
    this.lang = '',
    this.limitations = const [],
    this.sourceIds = const [],
    this.loadError = '',
  });

  final String id;
  final String name;
  final String version;
  final SourceEngine engine;
  final bool installed;
  final String packageUrl;
  final String iconUrl;
  final String lang;
  final List<String> limitations;
  final List<String> sourceIds;
  final String loadError;

  String get installRef => engine == SourceEngine.tachimanga ? id : packageUrl;
}

class ApiException implements Exception {
  const ApiException(this.message, {this.statusCode, this.code});

  final String message;
  final int? statusCode;
  final String? code;

  @override
  String toString() => message;
}
