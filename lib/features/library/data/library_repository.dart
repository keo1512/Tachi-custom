import 'dart:convert';
import 'dart:typed_data';

import 'package:shared_preferences/shared_preferences.dart';

import '../domain/library_book.dart';
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
  Future<void> remove(String id);
  Future<ReaderContent?> readChapter(String bookId, int index);
  Future<void> saveChapter(String bookId, int index, ReaderContent content);
  Future<void> deleteChapter(String bookId, int index);

  /// Atomically replaces chapter metadata and moves cached chapters by identity.
  /// Each entry is the previous index of the chapter at that new index.
  Future<void> replaceChapterOrder(
    LibraryBook book,
    List<int?> previousIndices,
  );
  Future<void> clear();
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
  Future<void> remove(String id) async {
    _books.remove(id);
    _chapters.removeWhere(
      (key, value) => (jsonDecode(key) as List).first == id,
    );
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
        'Bản xem trước web chỉ lưu tối đa 4 MB. Hãy nhập sách lớn trong app Android/iOS.',
      );
    }
    if (!await _preferences.setString(_storageKey, value)) {
      throw const FormatException(
        'Không thể lưu thư viện trong bộ nhớ trình duyệt.',
      );
    }
  }

  Future<void> _mutate(Future<void> Function() action) async {
    final books = Map<String, LibraryBook>.from(_books);
    final chapters = Map<String, ReaderContent>.from(_chapters);
    try {
      await action();
      await _persist();
    } catch (_) {
      _books
        ..clear()
        ..addAll(books);
      _chapters
        ..clear()
        ..addAll(chapters);
      rethrow;
    }
  }

  @override
  Future<void> save(LibraryBook book) => _mutate(() => super.save(book));
  @override
  Future<void> saveChapter(String bookId, int index, ReaderContent content) =>
      _mutate(() => super.saveChapter(bookId, index, content));
  @override
  Future<void> remove(String id) => _mutate(() => super.remove(id));
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
}
