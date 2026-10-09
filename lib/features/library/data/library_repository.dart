import 'dart:convert';
import 'dart:typed_data';

import 'package:shared_preferences/shared_preferences.dart';

import '../domain/library_book.dart';
import 'library_mutation.dart';
import 'library_snapshot.dart';
import 'library_repository_web.dart'
    if (dart.library.io) 'library_repository_native.dart'
    as platform;

abstract class LibraryRepository {
  static const maxMetadataBytes = 2 * 1024 * 1024;
  static const maxChapterBytes = 32 * 1024 * 1024;
  static const maxImageBytes = 8 * 1024 * 1024;
  static const webPreviewBytes = 4 * 1024 * 1024;
  static Future<LibraryRepository> open({String? directoryPath}) =>
      platform.openLibrary(directoryPath: directoryPath);

  /// Explicit browser persistence implementation, also testable without native plugins.
  static Future<LibraryRepository> openWebPreview() async =>
      _PreferenceLibraryRepository(await SharedPreferences.getInstance());
  Future<List<LibraryBook>> list();
  Future<LibraryBook?> find(String id);
  Future<void> save(LibraryBook book);

  /// Adds metadata and staged chapters together, preserving an existing title.
  Future<LibraryBook> insertBook(
    LibraryBook book, {
    Map<int, ReaderContent> contents = const {},
    required int expectedRevision,
  });
  Future<void> remove(String id);
  Future<ReaderContent?> readChapter(String bookId, int index);
  Future<void> saveChapter(String bookId, int index, ReaderContent content);
  Future<void> deleteChapter(String bookId, int index);

  /// Invalidates work started before a successful restore, clear or removal.
  int get replacementRevision;
  Future<LibraryChapterRead?> openChapter(String bookId, String chapterId);
  Future<ReaderContent> commitChapter(
    LibraryChapterRead read,
    ReaderContent content, {
    required bool downloaded,
  });
  Future<LibraryBook?> mutateBook(
    String id,
    LibraryBook Function(LibraryBook) transform, {
    int? expectedRevision,
  });
  Future<int> updateChapterOrder(
    LibraryBook expected,
    List<BookChapter> incoming, {
    required int expectedRevision,
  });
  Future<void> removeBook(String id, {int? expectedRevision});

  /// Atomically replaces chapter metadata and moves cached chapters by identity.
  /// Each entry is the previous index of the chapter at that new index.
  Future<void> replaceChapterOrder(
    LibraryBook book,
    List<int?> previousIndices,
  );
  Future<void> clear();
  Future<LibrarySnapshot> snapshot();

  /// Replace the entire library only if its hydrated fingerprint still matches.
  /// Implementations must provide an atomic compare/write and recovery image.
  Future<void> replaceSnapshot(
    LibrarySnapshot incoming, {
    required String expectedFingerprint,
  });
  Future<Uint8List?> recoverySnapshot();
  Future<void> close() async {}
  Future<String> storeAttachment(
    String bookId,
    Uint8List bytes,
    String mediaType,
  ) async {
    if (bytes.length > maxImageBytes) {
      throw const FormatException('Ảnh vượt giới hạn 8 MB.');
    }
    return 'data:$mediaType;base64,${base64Encode(bytes)}';
  }

  void validateBook(LibraryBook book) {
    if (book.id.isEmpty ||
        book.title.isEmpty ||
        book.chapters.length > 10000 ||
        utf8.encode(jsonEncode(book.toJson())).length > maxMetadataBytes) {
      throw const FormatException(
        'Thông tin sách trống hoặc vượt giới hạn lưu trữ.',
      );
    }
  }

  void validateChapter(int index, ReaderContent content) {
    if (index < 0 ||
        utf8.encode(jsonEncode(content.toJson())).length > maxChapterBytes) {
      throw const FormatException(
        'Chương vượt giới hạn 32 MB hoặc vị trí không hợp lệ.',
      );
    }
  }
}

/// Ephemeral storage for tests; production open() uses persistent storage.
class MemoryLibraryRepository extends LibraryRepository {
  final Map<String, LibraryBook> _books = {};
  final Map<String, ReaderContent> _chapters = {};
  Uint8List? _recovery;
  int _replacementRevision = 0;
  @override
  int get replacementRevision => _replacementRevision;
  String _key(String id, int index) => jsonEncode([id, index]);
  @override
  Future<List<LibraryBook>> list() async => _books.values.toList();
  @override
  Future<LibraryBook?> find(String id) async => _books[id];
  @override
  Future<void> save(LibraryBook book) async {
    validateBook(book);
    _books[book.id] = book;
  }

  @override
  Future<LibraryBook> insertBook(
    LibraryBook book, {
    Map<int, ReaderContent> contents = const {},
    required int expectedRevision,
  }) async {
    checkLibraryRevision(replacementRevision, expectedRevision);
    final existing = _books[book.id];
    if (existing != null) return existing;
    validateBook(book);
    for (final entry in contents.entries) {
      if (entry.key >= book.chapters.length) {
        throw const FormatException('Nội dung không thuộc mục lục sách.');
      }
      validateChapter(entry.key, entry.value);
    }
    // No await between validation and the complete metadata/content insertion.
    for (final entry in contents.entries) {
      _chapters[_key(book.id, entry.key)] = entry.value;
    }
    _books[book.id] = book;
    return book;
  }

  @override
  Future<void> remove(String id) async {
    await removeBook(id);
  }

  @override
  Future<void> removeBook(String id, {int? expectedRevision}) async {
    checkLibraryRevision(replacementRevision, expectedRevision);
    _books.remove(id);
    _chapters.removeWhere(
      (key, value) => (jsonDecode(key) as List).first == id,
    );
    _replacementRevision++;
  }

  @override
  Future<ReaderContent?> readChapter(String bookId, int index) async =>
      _chapters[_key(bookId, index)];
  @override
  Future<void> saveChapter(
    String bookId,
    int index,
    ReaderContent content,
  ) async {
    validateChapter(index, content);
    _chapters[_key(bookId, index)] = content;
  }

  @override
  Future<void> clear() async {
    _books.clear();
    _chapters.clear();
    _replacementRevision++;
  }

  @override
  Future<void> deleteChapter(String bookId, int index) async {
    _chapters.remove(_key(bookId, index));
  }

  @override
  Future<void> replaceChapterOrder(
    LibraryBook book,
    List<int?> previousIndices,
  ) async {
    _replaceChapterOrder(book, previousIndices);
  }

  void _replaceChapterOrder(LibraryBook book, List<int?> previousIndices) {
    validateBook(book);
    if (previousIndices.length != book.chapters.length) {
      throw const FormatException('Ánh xạ chương không hợp lệ.');
    }
    final cached = [
      for (final index in previousIndices)
        index == null ? null : _chapters[_key(book.id, index)],
    ];
    _chapters.removeWhere(
      (key, _) => (jsonDecode(key) as List).first == book.id,
    );
    for (var i = 0; i < cached.length; i++) {
      if (cached[i] != null) _chapters[_key(book.id, i)] = cached[i]!;
    }
    _books[book.id] = book;
  }

  @override
  Future<LibraryChapterRead?> openChapter(
    String bookId,
    String chapterId,
  ) async {
    final book = _books[bookId];
    if (book == null) return null;
    final index = book.chapters.indexWhere(
      (chapter) => chapter.id == chapterId,
    );
    if (index < 0) return null;
    return LibraryChapterRead(
      book: book,
      index: index,
      revision: replacementRevision,
      content: _chapters[_key(bookId, index)],
    );
  }

  @override
  Future<ReaderContent> commitChapter(
    LibraryChapterRead read,
    ReaderContent content, {
    required bool downloaded,
  }) async {
    checkLibraryRevision(replacementRevision, read.revision);
    final book = _books[read.book.id];
    if (book == null ||
        bookSourceIdentity(book) != bookSourceIdentity(read.book)) {
      throw StateError('Sách hoặc nguồn đã thay đổi.');
    }
    final index = book.chapters.indexWhere(
      (chapter) => chapter.id == read.chapterId,
    );
    if (index < 0) throw StateError('Chương không còn trong mục lục');
    checkChapterContent(book, content);
    validateChapter(index, content);
    if (downloaded && !chapterIsOffline(content)) {
      throw StateError('Nội dung chưa được lưu đầy đủ để đọc offline.');
    }
    final existing = _chapters[_key(book.id, index)];
    if (!downloaded && existing != null && chapterIsOffline(existing)) {
      return existing;
    }
    final chapters = [...book.chapters];
    chapters[index] = chapters[index].copyWith(downloaded: downloaded);
    final updated = book.copyWith(chapters: chapters);
    validateBook(updated);
    _chapters[_key(book.id, index)] = content;
    _books[book.id] = updated;
    return content;
  }

  @override
  Future<LibraryBook?> mutateBook(
    String id,
    LibraryBook Function(LibraryBook) transform, {
    int? expectedRevision,
  }) async {
    checkLibraryRevision(replacementRevision, expectedRevision);
    final book = _books[id];
    if (book == null) return null;
    final updated = transform(book);
    if (updated.id != id) {
      throw StateError('Không thể đổi mã sách trong cập nhật metadata.');
    }
    validateBook(updated);
    _books[id] = updated;
    return updated;
  }

  @override
  Future<int> updateChapterOrder(
    LibraryBook expected,
    List<BookChapter> incoming, {
    required int expectedRevision,
  }) async {
    checkLibraryRevision(replacementRevision, expectedRevision);
    final latest = _books[expected.id];
    if (latest == null ||
        bookSourceIdentity(latest) != bookSourceIdentity(expected)) {
      throw StateError('Sách hoặc nguồn đã thay đổi.');
    }
    final change = remapChapterOrder(latest, incoming);
    _replaceChapterOrder(change.book, change.previousIndices);
    return change.additions;
  }

  LibrarySnapshot _snapshot() => LibrarySnapshot([
    for (final book in _books.values)
      LibrarySnapshotEntry(book, {
        for (var index = 0; index < book.chapters.length; index++)
          if (_chapters[_key(book.id, index)] != null)
            index: _chapters[_key(book.id, index)]!,
      }),
  ]);

  @override
  Future<LibrarySnapshot> snapshot() async => _snapshot();

  @override
  Future<void> replaceSnapshot(
    LibrarySnapshot incoming, {
    required String expectedFingerprint,
  }) async {
    final books = <String, LibraryBook>{};
    final chapters = <String, ReaderContent>{};
    for (final entry in incoming.entries) {
      validateBook(entry.book.copyWith(cover: ''));
      books[entry.book.id] = entry.book;
      for (final chapter in entry.contents.entries) {
        validateChapter(chapter.key, chapter.value);
        chapters[_key(entry.book.id, chapter.key)] = chapter.value;
      }
    }
    final previous = _snapshot();
    if (previous.fingerprint != expectedFingerprint) {
      throw StateError(
        'Thư viện đã thay đổi. Hãy tải lại trước khi khôi phục.',
      );
    }
    // No await between the comparison and map replacement.
    _recovery = previous.encode();
    _books
      ..clear()
      ..addAll(books);
    _chapters
      ..clear()
      ..addAll(chapters);
    _replacementRevision++;
  }

  @override
  Future<Uint8List?> recoverySnapshot() async =>
      _recovery == null ? null : Uint8List.fromList(_recovery!);
}

class _PreferenceLibraryRepository extends MemoryLibraryRepository {
  _PreferenceLibraryRepository(this._preferences) {
    final stored = _preferences.getString(_storageKey);
    if (stored == null) return;
    final data = Map<String, dynamic>.from(jsonDecode(stored) as Map);
    for (final value in (data['books'] as List? ?? [])) {
      final book = LibraryBook.fromJson(
        Map<String, dynamic>.from(value as Map),
      );
      _books[book.id] = book;
    }
    for (final entry in Map<String, dynamic>.from(
      data['chapters'] as Map? ?? {},
    ).entries) {
      _chapters[entry.key] = ReaderContent.fromJson(
        Map<String, dynamic>.from(entry.value as Map),
      );
    }
  }
  static const _storageKey = 'tachi_books.library.v1';
  final SharedPreferences _preferences;
  Future<void> _persist() async {
    final value = jsonEncode({
      'books': _books.values.map((book) => book.toJson()).toList(),
      'chapters': _chapters.map(
        (key, content) => MapEntry(key, content.toJson()),
      ),
    });
    if (utf8.encode(value).length > LibraryRepository.webPreviewBytes) {
      throw const FormatException(
        'Bản xem trước chỉ lưu tối đa 4 MB. Hãy nhập sách lớn trong app iOS.',
      );
    }
    if (!await _preferences.setString(_storageKey, value)) {
      throw const FormatException(
        'Không thể lưu thư viện trong bộ nhớ trình duyệt.',
      );
    }
  }

  Future<void> _pendingMutation = Future<void>.value();
  Future<T> _mutate<T>(Future<T> Function() action) {
    final result = _pendingMutation.then((_) => _applyMutation(action));
    _pendingMutation = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }

  Future<T> _applyMutation<T>(Future<T> Function() action) async {
    final books = Map<String, LibraryBook>.from(_books);
    final chapters = Map<String, ReaderContent>.from(_chapters);
    final revision = _replacementRevision;
    try {
      final result = await action();
      await _persist();
      return result;
    } catch (_) {
      _books
        ..clear()
        ..addAll(books);
      _chapters
        ..clear()
        ..addAll(chapters);
      _replacementRevision = revision;
      rethrow;
    }
  }

  @override
  Future<void> save(LibraryBook book) => _mutate(() => super.save(book));
  @override
  Future<LibraryBook> insertBook(
    LibraryBook book, {
    Map<int, ReaderContent> contents = const {},
    required int expectedRevision,
  }) => _mutate(
    () => super.insertBook(
      book,
      contents: contents,
      expectedRevision: expectedRevision,
    ),
  );
  @override
  Future<void> saveChapter(String bookId, int index, ReaderContent content) =>
      _mutate(() => super.saveChapter(bookId, index, content));
  @override
  Future<void> remove(String id) => _mutate(() => super.removeBook(id));
  @override
  Future<void> removeBook(String id, {int? expectedRevision}) =>
      _mutate(() => super.removeBook(id, expectedRevision: expectedRevision));
  @override
  Future<ReaderContent> commitChapter(
    LibraryChapterRead read,
    ReaderContent content, {
    required bool downloaded,
  }) =>
      _mutate(() => super.commitChapter(read, content, downloaded: downloaded));
  @override
  Future<LibraryBook?> mutateBook(
    String id,
    LibraryBook Function(LibraryBook) transform, {
    int? expectedRevision,
  }) => _mutate(
    () => super.mutateBook(id, transform, expectedRevision: expectedRevision),
  );
  @override
  Future<int> updateChapterOrder(
    LibraryBook expected,
    List<BookChapter> incoming, {
    required int expectedRevision,
  }) => _mutate(
    () => super.updateChapterOrder(
      expected,
      incoming,
      expectedRevision: expectedRevision,
    ),
  );
  @override
  Future<void> deleteChapter(String bookId, int index) =>
      _mutate(() => super.deleteChapter(bookId, index));
  @override
  Future<void> replaceChapterOrder(
    LibraryBook book,
    List<int?> previousIndices,
  ) => _mutate(() => super.replaceChapterOrder(book, previousIndices));
  @override
  Future<void> clear() => _mutate(() => super.clear());

  @override
  Future<void> replaceSnapshot(
    LibrarySnapshot incoming, {
    required String expectedFingerprint,
  }) async => throw UnsupportedError(
    'Đồng bộ thay thế toàn bộ thư viện chỉ được hỗ trợ trong app iOS.',
  );
}
