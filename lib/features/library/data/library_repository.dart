import 'dart:convert';
import 'dart:typed_data';

import 'package:shared_preferences/shared_preferences.dart';

import '../domain/library_book.dart';
import '../../downloads/domain/download_deletion.dart';
import 'library_mutation.dart';
import 'library_snapshot.dart';
import 'library_cache_maintenance.dart';
import 'backup_validation.dart';
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

  /// Removes cache and downloaded flags together, preserving reading metadata.
  /// An actual deletion invalidates requests opened before it.
  Future<int> deleteDownloadedChapters(
    LibraryBook expected,
    Iterable<String> chapterIds, {
    required int expectedRevision,
    bool protectBookmarks = true,
    bool readOnly = false,
  });

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

  /// Applies metadata transforms to the latest matching titles as one commit.
  /// Chapter contents and replacement revision are retained.
  Future<int> mutateBooks(
    Iterable<String> ids,
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

  /// Joint restore hook; configuration is journaled by the caller and written
  /// after library CAS/recovery, before the atomic book commit. Unsupported
  /// implementations must reject before changing either store.
  Future<void> replaceSnapshotWithConfiguration(
    LibrarySnapshot incoming, {
    required String expectedFingerprint,
    required Uint8List recovery,
    required Future<void> Function() beforeCommit,
  }) async => throw UnsupportedError(
    'Bộ nhớ này chưa hỗ trợ khôi phục thiết lập và thư viện cùng nhau.',
  );
  Future<Uint8List?> recoverySnapshot();
  Future<LibraryStorageReport> inspectStorage() async {
    final image = await snapshot();
    BackupValidator(this).validateSnapshot(image.encode());
    return snapshotStorageReport(image, replacementRevision);
  }

  Future<LibraryCacheMaintenanceResult> clearTransientChapterCache({
    required String expectedFingerprint,
    void Function()? guard,
  }) async =>
      throw UnsupportedError('Bộ nhớ chưa hỗ trợ dọn cache chương an toàn.');
  Future<LibraryCacheMaintenanceResult> collectUnusedAttachments({
    required String expectedFingerprint,
    void Function()? guard,
  }) async => throw UnsupportedError('Bộ nhớ chưa hỗ trợ dọn tệp ảnh an toàn.');
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
    if (book.alternativeTitles.length > 2 ||
        book.alternativeTitles.any((title) => title.trim().isEmpty) ||
        book.alternativeTitles.toSet().length !=
            book.alternativeTitles.length) {
      throw const FormatException(
        'Tên khác phải gồm tối đa hai tên không trống, không trùng.',
      );
    }
    if (![
          '',
          'planned',
          'reading',
          'paused',
          'completed',
        ].contains(book.readingState) ||
        (book.rating != null &&
            (!book.rating!.isFinite ||
                book.rating! < 0 ||
                book.rating! > 10))) {
      throw const FormatException(
        'Trạng thái đọc hoặc điểm đánh giá không hợp lệ.',
      );
    }
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
  Future<LibraryCacheMaintenanceResult> clearTransientChapterCache({
    required String expectedFingerprint,
    void Function()? guard,
  }) async {
    guard?.call();
    final image = await snapshot();
    BackupValidator(this).validateSnapshot(image.encode());
    final keys = transientChapterKeys(image);
    if (image.fingerprint != expectedFingerprint) {
      throw StateError(
        'Thư viện đã thay đổi. Hãy kiểm tra lại trước khi dọn cache.',
      );
    }
    if (keys.isEmpty) return const LibraryCacheMaintenanceResult();
    guard?.call();
    // No await between preservation and cache deletion.
    _recovery = image.encode();
    for (final key in keys) {
      _chapters.remove(_key(key.bookId, key.index));
    }
    _replacementRevision++;
    return LibraryCacheMaintenanceResult(removedChapters: keys.length);
  }

  @override
  Future<LibraryCacheMaintenanceResult> collectUnusedAttachments({
    required String expectedFingerprint,
    void Function()? guard,
  }) async {
    guard?.call();
    final image = await snapshot();
    BackupValidator(this).validateSnapshot(image.encode());
    if (image.fingerprint != expectedFingerprint) {
      throw StateError(
        'Thư viện đã thay đổi. Hãy kiểm tra lại trước khi dọn cache.',
      );
    }
    return const LibraryCacheMaintenanceResult();
  }

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
  Future<int> deleteDownloadedChapters(
    LibraryBook expected,
    Iterable<String> chapterIds, {
    required int expectedRevision,
    bool protectBookmarks = true,
    bool readOnly = false,
  }) async {
    checkLibraryRevision(replacementRevision, expectedRevision);
    final book = _books[expected.id];
    if (book == null ||
        bookSourceIdentity(book) != bookSourceIdentity(expected)) {
      throw StateError('Sách hoặc nguồn đã thay đổi. Hãy mở lại sách.');
    }
    final indices =
        downloadDeletionIndices(
              book,
              chapterIds.toSet(),
              protectBookmarks: protectBookmarks,
              readOnly: readOnly,
            )
            .where(
              (index) =>
                  book.chapters[index].downloaded ||
                  _chapters.containsKey(_key(book.id, index)),
            )
            .toList();
    if (indices.isEmpty) return 0;
    final chapters = [...book.chapters];
    for (final index in indices) {
      chapters[index] = chapters[index].copyWith(downloaded: false);
    }
    final updated = book.copyWith(chapters: chapters);
    validateBook(updated);
    for (final index in indices) {
      _chapters.remove(_key(book.id, index));
    }
    _books[book.id] = updated;
    _replacementRevision++;
    return indices.length;
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
  Future<int> mutateBooks(
    Iterable<String> ids,
    LibraryBook Function(LibraryBook) transform, {
    int? expectedRevision,
  }) async {
    checkLibraryRevision(replacementRevision, expectedRevision);
    final distinct = ids.toSet();
    if (distinct.length > 10000) {
      throw const FormatException('Thao tác có quá nhiều sách.');
    }
    final updated = <String, LibraryBook>{};
    for (final id in distinct) {
      final book = _books[id];
      if (book == null) continue;
      final next = transform(book);
      if (next.id != id) {
        throw StateError('Không thể đổi mã sách trong cập nhật metadata.');
      }
      validateBook(next);
      updated[id] = next;
    }
    _books.addAll(updated);
    return updated.length;
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

  LibrarySnapshot _snapshot() {
    for (final key in _chapters.keys) {
      final position = jsonDecode(key) as List<dynamic>;
      final book = _books[position[0]];
      final index = position[1] as int;
      if (book == null || index < 0 || index >= book.chapters.length) {
        throw const FormatException(
          'Nội dung chương không thuộc thư viện hoặc mục lục. Dữ liệu được giữ nguyên.',
        );
      }
    }
    return LibrarySnapshot([
      for (final book in _books.values)
        LibrarySnapshotEntry(book, {
          for (var index = 0; index < book.chapters.length; index++)
            if (_chapters[_key(book.id, index)] != null)
              index: _chapters[_key(book.id, index)]!,
        }),
    ]);
  }

  @override
  Future<LibrarySnapshot> snapshot() async => _snapshot();

  @override
  Future<void> replaceSnapshot(
    LibrarySnapshot incoming, {
    required String expectedFingerprint,
  }) => _replaceSnapshot(incoming, expectedFingerprint: expectedFingerprint);

  @override
  Future<void> replaceSnapshotWithConfiguration(
    LibrarySnapshot incoming, {
    required String expectedFingerprint,
    required Uint8List recovery,
    required Future<void> Function() beforeCommit,
  }) => _replaceSnapshot(
    incoming,
    expectedFingerprint: expectedFingerprint,
    recovery: recovery,
    beforeCommit: beforeCommit,
  );

  Future<void> _replaceSnapshot(
    LibrarySnapshot incoming, {
    required String expectedFingerprint,
    Uint8List? recovery,
    Future<void> Function()? beforeCommit,
  }) async {
    final books = <String, LibraryBook>{};
    final chapters = <String, ReaderContent>{};
    for (final entry in incoming.entries) {
      validateBook(entry.book.copyWith(cover: '', originalCover: ''));
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
    _recovery = recovery ?? previous.encode();
    if (beforeCommit != null) {
      await beforeCommit();
      // Memory repositories also reject an edit while async preferences write.
      if (_snapshot().fingerprint != expectedFingerprint) {
        throw StateError('Thư viện đã thay đổi trong khi khôi phục.');
      }
    }
    // No await between the final comparison and map replacement.
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
  Future<int> mutateBooks(
    Iterable<String> ids,
    LibraryBook Function(LibraryBook) transform, {
    int? expectedRevision,
  }) => _mutate(
    () => super.mutateBooks(ids, transform, expectedRevision: expectedRevision),
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
  Future<int> deleteDownloadedChapters(
    LibraryBook expected,
    Iterable<String> chapterIds, {
    required int expectedRevision,
    bool protectBookmarks = true,
    bool readOnly = false,
  }) => _mutate(
    () => super.deleteDownloadedChapters(
      expected,
      chapterIds,
      expectedRevision: expectedRevision,
      protectBookmarks: protectBookmarks,
      readOnly: readOnly,
    ),
  );
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

  @override
  Future<void> replaceSnapshotWithConfiguration(
    LibrarySnapshot incoming, {
    required String expectedFingerprint,
    required Uint8List recovery,
    required Future<void> Function() beforeCommit,
  }) async => throw UnsupportedError(
    'Khôi phục thay thế chỉ được hỗ trợ trong app iOS.',
  );
}
