import 'external_backup_metadata.dart';
import '../../../core/source_memo.dart' as metadata;

class BookChapter {
  const BookChapter({
    required this.id,
    required this.title,
    required this.index,
    this.downloaded = false,
    this.read,
    this.uploadedAt,
    this.discoveredAt,
    this.scanlator = '',
    this.number,
    this.sourceMemo = const {},
    this.sourceUrl = '',
    this.nativeSourceContext = false,
  });
  final String id;
  final String title;
  final int index;
  final bool downloaded;
  final DateTime? uploadedAt;

  /// When an update first found this chapter; legacy/imported chapters stay null.
  final DateTime? discoveredAt;
  final String scanlator;
  final double? number;
  final Map<String, dynamic> sourceMemo;
  final String sourceUrl;
  final bool nativeSourceContext;

  /// null keeps the existing sequential progress inference for older libraries.
  final bool? read;
  BookChapter copyWith({
    String? id,
    String? title,
    int? index,
    bool? downloaded,
    bool? read,
    DateTime? uploadedAt,
    DateTime? discoveredAt,
    bool clearDiscoveredAt = false,
    String? scanlator,
    double? number,
    Map<String, dynamic>? sourceMemo,
    String? sourceUrl,
    bool? nativeSourceContext,
  }) => BookChapter(
    id: id ?? this.id,
    title: title ?? this.title,
    index: index ?? this.index,
    downloaded: downloaded ?? this.downloaded,
    read: read ?? this.read,
    uploadedAt: uploadedAt ?? this.uploadedAt,
    discoveredAt: clearDiscoveredAt
        ? null
        : (discoveredAt ?? this.discoveredAt),
    scanlator: scanlator ?? this.scanlator,
    number: number ?? this.number,
    sourceMemo: sourceMemo ?? this.sourceMemo,
    sourceUrl: sourceUrl ?? this.sourceUrl,
    nativeSourceContext: nativeSourceContext ?? this.nativeSourceContext,
  );
  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'index': index,
    'downloaded': downloaded,
    if (read != null) 'read': read,
    if (uploadedAt != null) 'uploadedAt': uploadedAt!.toIso8601String(),
    if (discoveredAt != null) 'discoveredAt': discoveredAt!.toIso8601String(),
    if (scanlator.isNotEmpty) 'scanlator': scanlator,
    if (number != null) 'number': number,
    if (sourceMemo.isNotEmpty) 'sourceMemo': sourceMemo,
    if (sourceUrl.isNotEmpty) 'sourceUrl': sourceUrl,
    if (nativeSourceContext) 'nativeSourceContext': true,
  };
  factory BookChapter.fromJson(Map<String, dynamic> json) => BookChapter(
    id: json['id'] as String,
    title: json['title'] as String,
    index: (json['index'] as num).toInt(),
    downloaded: json['downloaded'] as bool? ?? false,
    read: json['read'] as bool?,
    uploadedAt: json['uploadedAt'] == null
        ? null
        : DateTime.parse(json['uploadedAt'] as String),
    discoveredAt: json['discoveredAt'] == null
        ? null
        : DateTime.parse(json['discoveredAt'] as String),
    scanlator: json['scanlator'] as String? ?? '',
    number: (json['number'] as num?)?.toDouble(),
    sourceMemo: metadata.sourceMemo(json['sourceMemo']),
    sourceUrl: json['sourceUrl'] as String? ?? '',
    nativeSourceContext: json['nativeSourceContext'] as bool? ?? false,
  );
}

class LibraryBook {
  LibraryBook({
    required this.id,
    required this.title,
    List<String> alternativeTitles = const [],
    this.author = '',
    this.artist = '',
    List<String> genres = const [],
    this.notes = '',
    this.externalBackupMetadata,
    this.series = '',
    this.description = '',
    this.kind = 'novel',
    this.engine = 'local',
    this.sourceId = '',
    this.sourceName = '',
    this.sourceRef = '',
    Map<String, dynamic> sourceMemo = const {},
    this.nativeSourceContext = false,
    this.cover = '',
    this.originalCover = '',
    this.customCover = false,
    List<BookChapter> chapters = const [],
    this.currentChapter = 0,
    this.progress = 0,
    this.lastRead,
    this.favorite = false,
    this.completed = false,
    this.status = 0,
    this.readingState = '',
    this.rating,
    String collection = 'Mặc định',
    List<String>? categories,
    this.createdAt,
    this.lastUpdated,
    Map<String, dynamic> readerPreferences = const {},
    Map<String, dynamic> chapterListPreferences = const {},
    List<String> bookmarks = const [],
  }) : alternativeTitles = List.unmodifiable(alternativeTitles),
       genres = List.unmodifiable(genres),
       sourceMemo = metadata.sourceMemo(sourceMemo),
       categories = List.unmodifiable(_categoryNames(categories, collection)),
       collection = _categoryNames(categories, collection).first,
       readerPreferences = Map.unmodifiable(readerPreferences),
       chapterListPreferences = Map.unmodifiable(chapterListPreferences),
       chapters = List.unmodifiable(chapters),
       bookmarks = List.unmodifiable(bookmarks);
  final String id,
      title,
      author,
      artist,
      notes,
      series,
      description,
      kind,
      engine,
      sourceId,
      sourceName,
      sourceRef,
      cover,
      originalCover,
      readingState,
      collection;
  final List<String> alternativeTitles;
  final Map<String, dynamic> sourceMemo;
  final bool nativeSourceContext;
  final bool customCover;
  final double? rating;
  final List<BookChapter> chapters;
  final List<String> genres;
  final ExternalBackupMetadata? externalBackupMetadata;

  /// The first membership remains the legacy `collection` for older consumers.
  final List<String> categories;
  final Map<String, dynamic> readerPreferences;
  final Map<String, dynamic> chapterListPreferences;
  final List<String> bookmarks;
  final int currentChapter;
  final double progress;
  final DateTime? lastRead;
  final DateTime? createdAt, lastUpdated;
  final bool favorite, completed;
  final int status;
  LibraryBook copyWith({
    String? id,
    String? title,
    List<String>? alternativeTitles,
    String? author,
    String? artist,
    List<String>? genres,
    String? notes,
    ExternalBackupMetadata? externalBackupMetadata,
    String? series,
    String? description,
    String? kind,
    String? engine,
    String? sourceId,
    String? sourceName,
    String? sourceRef,
    Map<String, dynamic>? sourceMemo,
    bool? nativeSourceContext,
    String? cover,
    String? originalCover,
    bool? customCover,
    List<BookChapter>? chapters,
    int? currentChapter,
    double? progress,
    DateTime? lastRead,
    bool? favorite,
    bool? completed,
    int? status,
    String? readingState,
    double? rating,
    bool clearRating = false,
    String? collection,
    List<String>? categories,
    DateTime? createdAt,
    DateTime? lastUpdated,
    Map<String, dynamic>? readerPreferences,
    Map<String, dynamic>? chapterListPreferences,
    List<String>? bookmarks,
    bool clearLastRead = false,
  }) => LibraryBook(
    id: id ?? this.id,
    title: title ?? this.title,
    alternativeTitles: alternativeTitles ?? this.alternativeTitles,
    author: author ?? this.author,
    artist: artist ?? this.artist,
    genres: genres ?? this.genres,
    notes: notes ?? this.notes,
    externalBackupMetadata:
        externalBackupMetadata ?? this.externalBackupMetadata,
    series: series ?? this.series,
    description: description ?? this.description,
    kind: kind ?? this.kind,
    engine: engine ?? this.engine,
    sourceId: sourceId ?? this.sourceId,
    sourceName: sourceName ?? this.sourceName,
    sourceRef: sourceRef ?? this.sourceRef,
    sourceMemo: sourceMemo ?? this.sourceMemo,
    nativeSourceContext: nativeSourceContext ?? this.nativeSourceContext,
    cover: cover ?? this.cover,
    originalCover: originalCover ?? this.originalCover,
    customCover: customCover ?? this.customCover,
    chapters: chapters ?? this.chapters,
    currentChapter: currentChapter ?? this.currentChapter,
    progress: progress ?? this.progress,
    lastRead: clearLastRead ? null : (lastRead ?? this.lastRead),
    favorite: favorite ?? this.favorite,
    completed: completed ?? this.completed,
    status: status ?? this.status,
    readingState: readingState ?? this.readingState,
    rating: clearRating ? null : (rating ?? this.rating),
    collection: collection ?? this.collection,
    categories: categories ?? (collection == null ? this.categories : null),
    createdAt: createdAt ?? this.createdAt,
    lastUpdated: lastUpdated ?? this.lastUpdated,
    readerPreferences: readerPreferences ?? this.readerPreferences,
    chapterListPreferences:
        chapterListPreferences ?? this.chapterListPreferences,
    bookmarks: bookmarks ?? this.bookmarks,
  );
  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    if (alternativeTitles.isNotEmpty) 'alternativeTitles': alternativeTitles,
    'author': author,
    'artist': artist,
    'genres': genres,
    'notes': notes,
    if (externalBackupMetadata != null)
      'externalBackupMetadata': externalBackupMetadata!.toJson(),
    'series': series,
    'description': description,
    'kind': kind,
    'engine': engine,
    'sourceId': sourceId,
    if (sourceName.isNotEmpty) 'sourceName': sourceName,
    'sourceRef': sourceRef,
    if (sourceMemo.isNotEmpty) 'sourceMemo': sourceMemo,
    if (nativeSourceContext) 'nativeSourceContext': true,
    'cover': cover,
    if (originalCover.isNotEmpty) 'originalCover': originalCover,
    if (customCover) 'customCover': true,
    'chapters': chapters.map((value) => value.toJson()).toList(),
    'currentChapter': currentChapter,
    'progress': progress,
    'lastRead': lastRead?.toIso8601String(),
    'favorite': favorite,
    'completed': completed,
    'status': status,
    if (readingState.isNotEmpty) 'readingState': readingState,
    if (rating != null) 'rating': rating,
    'collection': collection,
    'categories': categories,
    if (createdAt != null) 'createdAt': createdAt!.toIso8601String(),
    if (lastUpdated != null) 'lastUpdated': lastUpdated!.toIso8601String(),
    if (readerPreferences.isNotEmpty) 'readerPreferences': readerPreferences,
    if (chapterListPreferences.isNotEmpty)
      'chapterListPreferences': chapterListPreferences,
    'bookmarks': bookmarks,
  };
  factory LibraryBook.fromJson(Map<String, dynamic> json) => LibraryBook(
    id: json['id'] as String,
    title: json['title'] as String,
    alternativeTitles: (json['alternativeTitles'] as List? ?? const [])
        .cast<String>(),
    author: json['author'] as String? ?? '',
    artist: json['artist'] as String? ?? '',
    genres: (json['genres'] as List? ?? const []).cast<String>(),
    notes: json['notes'] as String? ?? '',
    externalBackupMetadata: json.containsKey('externalBackupMetadata')
        ? ExternalBackupMetadata.fromJson(json['externalBackupMetadata'])
        : null,
    series: json['series'] as String? ?? '',
    description: json['description'] as String? ?? '',
    kind: json['kind'] as String? ?? 'novel',
    engine: json['engine'] as String? ?? 'local',
    sourceId: json['sourceId'] as String? ?? '',
    sourceName: json['sourceName'] as String? ?? '',
    sourceRef: json['sourceRef'] as String? ?? '',
    sourceMemo: metadata.sourceMemo(json['sourceMemo']),
    nativeSourceContext: json['nativeSourceContext'] as bool? ?? false,
    cover: json['cover'] as String? ?? '',
    originalCover: json['originalCover'] as String? ?? '',
    customCover: json['customCover'] as bool? ?? false,
    chapters: (json['chapters'] as List? ?? [])
        .map(
          (value) =>
              BookChapter.fromJson(Map<String, dynamic>.from(value as Map)),
        )
        .toList(),
    currentChapter: (json['currentChapter'] as num?)?.toInt() ?? 0,
    progress: (json['progress'] as num?)?.toDouble() ?? 0,
    lastRead: json['lastRead'] == null
        ? null
        : DateTime.parse(json['lastRead'] as String),
    favorite: json['favorite'] as bool? ?? false,
    completed: json['completed'] as bool? ?? false,
    status: (json['status'] as num?)?.toInt() ?? 0,
    readingState: json['readingState'] as String? ?? '',
    rating: (json['rating'] as num?)?.toDouble(),
    collection: json['collection'] as String? ?? 'Mặc định',
    categories: (json['categories'] as List?)?.cast<String>(),
    createdAt: json['createdAt'] == null
        ? null
        : DateTime.parse(json['createdAt'] as String),
    lastUpdated: json['lastUpdated'] == null
        ? null
        : DateTime.parse(json['lastUpdated'] as String),
    readerPreferences: Map<String, dynamic>.from(
      json['readerPreferences'] as Map? ?? const {},
    ),
    chapterListPreferences: Map<String, dynamic>.from(
      json['chapterListPreferences'] as Map? ?? const {},
    ),
    bookmarks: (json['bookmarks'] as List? ?? []).cast<String>(),
  );
}

List<String> _categoryNames(List<String>? categories, String collection) {
  if (categories == null) return [collection];
  final values = categories
      .map((name) => name.trim())
      .where((name) => name.isNotEmpty)
      .toSet()
      .toList();
  return values.isEmpty ? ['Mặc định'] : values;
}

class ReaderContent {
  ReaderContent({
    required this.kind,
    this.html = '',
    List<String> images = const [],
    Map<String, String> headers = const {},
    Map<String, Map<String, String>> imageHeaders = const {},
  }) : images = List.unmodifiable(images),
       headers = Map.unmodifiable(headers),
       imageHeaders = Map.unmodifiable(
         imageHeaders.map(
           (url, value) =>
               MapEntry(url, Map<String, String>.unmodifiable(value)),
         ),
       );
  final String kind, html;
  final List<String> images;
  final Map<String, String> headers;
  final Map<String, Map<String, String>> imageHeaders;
  Map<String, String> headersFor(String url) => {
    ...headers,
    ...?imageHeaders[url],
  };
  Map<String, dynamic> toJson() => {
    'kind': kind,
    'html': html,
    'images': images,
    'headers': headers,
    'imageHeaders': imageHeaders,
  };
  factory ReaderContent.fromJson(Map<String, dynamic> json) => ReaderContent(
    kind: json['kind'] as String,
    html: json['html'] as String? ?? '',
    images: (json['images'] as List? ?? []).cast<String>(),
    headers: Map<String, String>.from(json['headers'] as Map? ?? {}),
    imageHeaders: (json['imageHeaders'] as Map? ?? {}).map(
      (url, value) =>
          MapEntry(url as String, Map<String, String>.from(value as Map)),
    ),
  );
}
