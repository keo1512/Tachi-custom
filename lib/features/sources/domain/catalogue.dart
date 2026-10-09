enum SourceEngine { tachimanga, vbook }

enum ContentKind { manga, novel }

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
  final ContentKind kind;
  final SourceEngine engine;

  String get identity => '${engine.name}:$sourceId:$ref';
}

class CatalogueChapter {
  const CatalogueChapter({
    required this.ref,
    required this.title,
    required this.index,
  });

  final String ref;
  final String title;
  final int index;
}

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

class CatalogueExtension {
  const CatalogueExtension({
    required this.id,
    required this.name,
    required this.version,
    required this.engine,
    this.installed = false,
    this.packageUrl = '',
    this.lang = '',
    this.limitations = const [],
  });

  final String id;
  final String name;
  final String version;
  final SourceEngine engine;
  final bool installed;
  final String packageUrl;
  final String lang;
  final List<String> limitations;

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
