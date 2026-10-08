class BookChapter {
  const BookChapter({
    required this.id,
    required this.title,
    required this.index,
    this.downloaded = false,
  });
  final String id;
  final String title;
  final int index;
  final bool downloaded;
  BookChapter copyWith({
    String? id,
    String? title,
    int? index,
    bool? downloaded,
  }) => BookChapter(
    id: id ?? this.id,
    title: title ?? this.title,
    index: index ?? this.index,
    downloaded: downloaded ?? this.downloaded,
  );
  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'index': index,
    'downloaded': downloaded,
  };
  factory BookChapter.fromJson(Map<String, dynamic> json) => BookChapter(
    id: json['id'] as String,
    title: json['title'] as String,
    index: (json['index'] as num).toInt(),
    downloaded: json['downloaded'] as bool? ?? false,
  );
}

class LibraryBook {
  LibraryBook({
    required this.id,
    required this.title,
    this.author = '',
    this.description = '',
    this.kind = 'novel',
    this.engine = 'local',
    this.sourceId = '',
    this.sourceRef = '',
    this.cover = '',
    List<BookChapter> chapters = const [],
    this.currentChapter = 0,
    this.progress = 0,
    this.lastRead,
    this.favorite = false,
    this.completed = false,
    this.collection = 'Mặc định',
    List<String> bookmarks = const [],
  }) : chapters = List.unmodifiable(chapters),
       bookmarks = List.unmodifiable(bookmarks);
  final String id,
      title,
      author,
      description,
      kind,
      engine,
      sourceId,
      sourceRef,
      cover,
      collection;
  final List<BookChapter> chapters;
  final List<String> bookmarks;
  final int currentChapter;
  final double progress;
  final DateTime? lastRead;
  final bool favorite, completed;
  LibraryBook copyWith({
    String? id,
    String? title,
    String? author,
    String? description,
    String? kind,
    String? engine,
    String? sourceId,
    String? sourceRef,
    String? cover,
    List<BookChapter>? chapters,
    int? currentChapter,
    double? progress,
    DateTime? lastRead,
    bool? favorite,
    bool? completed,
    String? collection,
    List<String>? bookmarks,
    bool clearLastRead = false,
  }) => LibraryBook(
    id: id ?? this.id,
    title: title ?? this.title,
    author: author ?? this.author,
    description: description ?? this.description,
    kind: kind ?? this.kind,
    engine: engine ?? this.engine,
    sourceId: sourceId ?? this.sourceId,
    sourceRef: sourceRef ?? this.sourceRef,
    cover: cover ?? this.cover,
    chapters: chapters ?? this.chapters,
    currentChapter: currentChapter ?? this.currentChapter,
    progress: progress ?? this.progress,
    lastRead: clearLastRead ? null : (lastRead ?? this.lastRead),
    favorite: favorite ?? this.favorite,
    completed: completed ?? this.completed,
    collection: collection ?? this.collection,
    bookmarks: bookmarks ?? this.bookmarks,
  );
  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'author': author,
    'description': description,
    'kind': kind,
    'engine': engine,
    'sourceId': sourceId,
    'sourceRef': sourceRef,
    'cover': cover,
    'chapters': chapters.map((value) => value.toJson()).toList(),
    'currentChapter': currentChapter,
    'progress': progress,
    'lastRead': lastRead?.toIso8601String(),
    'favorite': favorite,
    'completed': completed,
    'collection': collection,
    'bookmarks': bookmarks,
  };
  factory LibraryBook.fromJson(Map<String, dynamic> json) => LibraryBook(
    id: json['id'] as String,
    title: json['title'] as String,
    author: json['author'] as String? ?? '',
    description: json['description'] as String? ?? '',
    kind: json['kind'] as String? ?? 'novel',
    engine: json['engine'] as String? ?? 'local',
    sourceId: json['sourceId'] as String? ?? '',
    sourceRef: json['sourceRef'] as String? ?? '',
    cover: json['cover'] as String? ?? '',
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
    collection: json['collection'] as String? ?? 'Mặc định',
    bookmarks: (json['bookmarks'] as List? ?? []).cast<String>(),
  );
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
