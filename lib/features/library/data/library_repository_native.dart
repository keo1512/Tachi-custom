import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:html/parser.dart' as html_parser;
import 'package:isar_community/isar.dart';
import 'package:path_provider/path_provider.dart';

import '../domain/library_book.dart';
import 'attachment_store.dart';
import 'isar_models.dart';
import 'library_repository.dart';
import 'library_mutation.dart';
import 'library_snapshot.dart';

Future<LibraryRepository> openLibrary({String? directoryPath}) async {
  final directory =
      directoryPath ?? (await getApplicationDocumentsDirectory()).path;
  final isar =
      Isar.getInstance('tachi_books') ??
      await Isar.open(
        [LibraryRecordSchema, ChapterRecordSchema],
        directory: directory,
        name: 'tachi_books',
      );
  return _IsarLibraryRepository(
    isar,
    await AttachmentStore.open(directory),
    Directory('$directory/backup-recovery'),
  );
}

class _IsarLibraryRepository extends LibraryRepository {
  _IsarLibraryRepository(this._isar, this._attachments, this._recoveries);
  final Isar _isar;
  final AttachmentStore _attachments;
  final Directory _recoveries;
  static final Map<Isar, Future<void>> _pending = {};
  static final Map<Isar, int> _replacementRevisions = {};
  @override
  int get replacementRevision => _replacementRevisions[_isar] ?? 0;
  void _invalidatePendingReads() =>
      _replacementRevisions[_isar] = replacementRevision + 1;

  // Share the queue between handles to the same Isar instance. File hydration,
  // deletion and staged replacement must never race another repository write.
  Future<T> _serialized<T>(Future<T> Function() action) {
    final result = (_pending[_isar] ?? Future<void>.value()).then(
      (_) => action(),
    );
    _pending[_isar] = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }

  Future<LibraryBook> _decodeBook(LibraryRecord row) async {
    final book = LibraryBook.fromJson(
      Map<String, dynamic>.from(jsonDecode(row.payload) as Map),
    );
    return book.copyWith(cover: await _attachments.resolve(book.cover));
  }

  LibraryBook _book(LibraryRecord row) => LibraryBook.fromJson(
    Map<String, dynamic>.from(jsonDecode(row.payload) as Map),
  );
  Future<LibraryRecord?> _bookRow(String id) =>
      _isar.libraryRecords.filter().bookIdEqualTo(id).findFirst();

  @override
  Future<List<LibraryBook>> list() => _serialized(
    () async => Future.wait(
      (await _isar.libraryRecords.where().findAll()).map(_decodeBook),
    ),
  );
  @override
  Future<LibraryBook?> find(String id) => _serialized(() async {
    final row = await _isar.libraryRecords
        .filter()
        .bookIdEqualTo(id)
        .findFirst();
    return row == null ? null : _decodeBook(row);
  });

  @override
  Future<String> storeAttachment(
    String bookId,
    Uint8List bytes,
    String mediaType,
  ) => _serialized(() => _storeAttachment(bookId, bytes, mediaType));

  Future<String> _storeAttachment(
    String bookId,
    Uint8List bytes,
    String mediaType,
  ) {
    if (bytes.length > LibraryRepository.maxImageBytes) {
      throw const FormatException('Ảnh vượt giới hạn 8 MB.');
    }
    return _attachments.store(bookId, bytes, mediaType);
  }

  Future<LibraryRecord> _prepareBook(LibraryBook book) async {
    if (book.cover.startsWith('data:image/')) {
      final uri = UriData.parse(book.cover);
      book = book.copyWith(
        cover: await _storeAttachment(
          book.id,
          Uint8List.fromList(uri.contentAsBytes()),
          uri.mimeType,
        ),
      );
    }
    validateBook(book);
    return LibraryRecord()
      ..bookId = book.id
      ..payload = jsonEncode(book.toJson());
  }

  @override
  Future<void> save(LibraryBook book) => _serialized(() async {
    final row = await _prepareBook(book);
    await _isar.writeTxn(() => _isar.libraryRecords.put(row));
  });

  @override
  Future<LibraryBook> insertBook(
    LibraryBook book, {
    Map<int, ReaderContent> contents = const {},
    required int expectedRevision,
  }) => _serialized(() async {
    checkLibraryRevision(replacementRevision, expectedRevision);
    final existing = await _bookRow(book.id);
    if (existing != null) return _decodeBook(existing);
    final row = await _prepareBook(book);
    final chapters = <ChapterRecord>[];
    for (final entry in contents.entries) {
      if (entry.key >= book.chapters.length) {
        throw const FormatException('Nội dung không thuộc mục lục sách.');
      }
      chapters.add(await _prepareChapter(book.id, entry.key, entry.value));
    }
    await _isar.writeTxn(() async {
      await _isar.libraryRecords.put(row);
      await _isar.chapterRecords.putAll(chapters);
    });
    return _decodeBook(row);
  });

  @override
  Future<void> remove(String id) => removeBook(id);

  @override
  Future<void> removeBook(String id, {int? expectedRevision}) =>
      _serialized(() async {
        checkLibraryRevision(replacementRevision, expectedRevision);
        await _isar.writeTxn(() async {
          await _isar.libraryRecords.filter().bookIdEqualTo(id).deleteAll();
          await _isar.chapterRecords.filter().bookIdEqualTo(id).deleteAll();
        });
        _invalidatePendingReads();
        await _attachments.removeBook(id);
      });

  @override
  Future<ReaderContent?> readChapter(String bookId, int index) =>
      _serialized(() async {
        final row = await _isar.chapterRecords
            .filter()
            .chapterKeyEqualTo(jsonEncode([bookId, index]))
            .findFirst();
        return row == null ? null : _decodeChapter(row);
      });

  Future<ReaderContent> _decodeChapter(ChapterRecord row) async {
    final images = (jsonDecode(row.imagesJson) as List).cast<String>();
    var html = row.html;
    final references = RegExp(
      r"""tachi-asset://[a-f0-9]{64}/[a-f0-9]{64}\?type=[^"'\s<>]+""",
    ).allMatches(html).map((match) => match.group(0)!).toSet();
    for (final reference in references) {
      html = html.replaceAll(reference, await _attachments.resolve(reference));
    }
    final storedHeaders = Map<String, dynamic>.from(
      jsonDecode(row.headersJson) as Map,
    );
    // Existing records stored a flat map; new records also retain per-image headers.
    final hasEnvelope =
        storedHeaders['imageHeaders'] is Map && storedHeaders['headers'] is Map;
    return ReaderContent(
      kind: row.kind,
      html: html,
      images: await Future.wait(images.map(_attachments.resolve)),
      headers: Map<String, String>.from(
        hasEnvelope ? storedHeaders['headers'] as Map : storedHeaders,
      ),
      imageHeaders: hasEnvelope
          ? (storedHeaders['imageHeaders'] as Map).map(
              (url, headers) => MapEntry(
                url as String,
                Map<String, String>.from(headers as Map),
              ),
            )
          : const {},
    );
  }

  Future<ChapterRecord> _prepareChapter(
    String bookId,
    int index,
    ReaderContent content,
  ) async {
    validateChapter(index, content);
    var chapterHtml = content.html;
    if (chapterHtml.contains('data:image/')) {
      final document = html_parser.parseFragment(chapterHtml);
      for (final image in document.querySelectorAll('img[src]')) {
        final source = image.attributes['src']!;
        if (!source.startsWith('data:image/')) continue;
        final uri = UriData.parse(source);
        image.attributes['src'] = await _storeAttachment(
          bookId,
          Uint8List.fromList(uri.contentAsBytes()),
          uri.mimeType,
        );
      }
      chapterHtml = document.outerHtml;
    }
    final images = <String>[];
    for (final image in content.images) {
      if (image.startsWith('data:image/')) {
        final uri = UriData.parse(image);
        images.add(
          await _storeAttachment(
            bookId,
            Uint8List.fromList(uri.contentAsBytes()),
            uri.mimeType,
          ),
        );
      } else {
        images.add(image);
      }
    }
    // Isar strings stay below its 16 MB field limit; image bytes are files.
    if (utf8.encode(chapterHtml).length > 8 * 1024 * 1024 ||
        utf8.encode(jsonEncode(images)).length > 8 * 1024 * 1024 ||
        utf8
                .encode(
                  jsonEncode({
                    'headers': content.headers,
                    'imageHeaders': content.imageHeaders,
                  }),
                )
                .length >
            8 * 1024 * 1024) {
      throw const FormatException(
        'Nội dung chữ của chương vượt giới hạn 8 MB.',
      );
    }
    return ChapterRecord()
      ..chapterKey = jsonEncode([bookId, index])
      ..bookId = bookId
      ..chapterIndex = index
      ..kind = content.kind
      ..html = chapterHtml
      ..imagesJson = jsonEncode(images)
      ..headersJson = jsonEncode({
        'headers': content.headers,
        'imageHeaders': content.imageHeaders,
      });
  }

  @override
  Future<void> saveChapter(String bookId, int index, ReaderContent content) =>
      _serialized(() async {
        final row = await _prepareChapter(bookId, index, content);
        await _isar.writeTxn(() => _isar.chapterRecords.put(row));
      });

  @override
  Future<void> clear() => _serialized(() async {
    await _isar.writeTxn(() async {
      await _isar.libraryRecords.clear();
      await _isar.chapterRecords.clear();
    });
    _invalidatePendingReads();
    await _attachments.clear();
  });

  @override
  Future<LibraryChapterRead?> openChapter(String bookId, String chapterId) =>
      _serialized(() async {
        final row = await _bookRow(bookId);
        if (row == null) return null;
        final book = await _decodeBook(row);
        final index = book.chapters.indexWhere(
          (chapter) => chapter.id == chapterId,
        );
        if (index < 0) return null;
        final chapter = await _isar.chapterRecords
            .filter()
            .chapterKeyEqualTo(jsonEncode([bookId, index]))
            .findFirst();
        return LibraryChapterRead(
          book: book,
          index: index,
          revision: replacementRevision,
          content: chapter == null ? null : await _decodeChapter(chapter),
        );
      });

  @override
  Future<ReaderContent> commitChapter(
    LibraryChapterRead read,
    ReaderContent content, {
    required bool downloaded,
  }) => _serialized(() async {
    late ChapterRecord saved;
    await _isar.writeTxn(() async {
      checkLibraryRevision(replacementRevision, read.revision);
      final row = await _bookRow(read.book.id);
      if (row == null) throw StateError('Sách đã được xóa khỏi thư viện');
      final book = _book(row);
      if (bookSourceIdentity(book) != bookSourceIdentity(read.book)) {
        throw StateError('Nguồn của sách đã thay đổi.');
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
      final cached = await _isar.chapterRecords
          .filter()
          .chapterKeyEqualTo(jsonEncode([book.id, index]))
          .findFirst();
      if (!downloaded &&
          cached != null &&
          chapterIsOffline(await _decodeChapter(cached))) {
        saved = cached;
        return;
      }
      saved = await _prepareChapter(book.id, index, content);
      final chapters = [...book.chapters];
      chapters[index] = chapters[index].copyWith(downloaded: downloaded);
      final updated = book.copyWith(chapters: chapters);
      validateBook(updated);
      row.payload = jsonEncode(updated.toJson());
      await _isar.chapterRecords.put(saved);
      await _isar.libraryRecords.put(row);
    });
    return _decodeChapter(saved);
  });

  @override
  Future<LibraryBook?> mutateBook(
    String id,
    LibraryBook Function(LibraryBook) transform, {
    int? expectedRevision,
  }) => _serialized(() async {
    LibraryRecord? saved;
    await _isar.writeTxn(() async {
      checkLibraryRevision(replacementRevision, expectedRevision);
      final row = await _bookRow(id);
      if (row == null) return;
      final updated = transform(_book(row));
      if (updated.id != id) {
        throw StateError('Không thể đổi mã sách trong cập nhật metadata.');
      }
      saved = await _prepareBook(updated);
      await _isar.libraryRecords.put(saved!);
    });
    return saved == null ? null : _decodeBook(saved!);
  });

  @override
  Future<int> updateChapterOrder(
    LibraryBook expected,
    List<BookChapter> incoming, {
    required int expectedRevision,
  }) => _serialized(() async {
    var additions = 0;
    await _isar.writeTxn(() async {
      checkLibraryRevision(replacementRevision, expectedRevision);
      final row = await _bookRow(expected.id);
      if (row == null) throw StateError('Sách đã được xóa khỏi thư viện');
      final latest = _book(row);
      if (bookSourceIdentity(latest) != bookSourceIdentity(expected)) {
        throw StateError('Nguồn của sách đã thay đổi.');
      }
      final change = remapChapterOrder(latest, incoming);
      validateBook(change.book);
      await _replaceChapterRows(change.book, change.previousIndices);
      additions = change.additions;
    });
    return additions;
  });

  @override
  Future<void> deleteChapter(String bookId, int index) => _serialized(() async {
    await _isar.writeTxn(
      () => _isar.chapterRecords
          .filter()
          .chapterKeyEqualTo(jsonEncode([bookId, index]))
          .deleteAll(),
    );
  });

  @override
  Future<void> replaceChapterOrder(
    LibraryBook book,
    List<int?> previousIndices,
  ) => _serialized(() async {
    if (previousIndices.length != book.chapters.length) {
      throw const FormatException('Ánh xạ chương không hợp lệ.');
    }
    if (book.cover.startsWith('data:image/')) {
      final uri = UriData.parse(book.cover);
      book = book.copyWith(
        cover: await _storeAttachment(
          book.id,
          Uint8List.fromList(uri.contentAsBytes()),
          uri.mimeType,
        ),
      );
    }
    validateBook(book);
    await _isar.writeTxn(() => _replaceChapterRows(book, previousIndices));
  });

  Future<void> _replaceChapterRows(
    LibraryBook savedBook,
    List<int?> previousIndices,
  ) async {
    final old = {
      for (final row
          in await _isar.chapterRecords
              .filter()
              .bookIdEqualTo(savedBook.id)
              .findAll())
        row.chapterIndex: row,
    };
    await _isar.chapterRecords.filter().bookIdEqualTo(savedBook.id).deleteAll();
    for (var i = 0; i < previousIndices.length; i++) {
      final cached = old[previousIndices[i]];
      if (cached == null) continue;
      final row = ChapterRecord()
        ..chapterKey = jsonEncode([savedBook.id, i])
        ..bookId = savedBook.id
        ..chapterIndex = i
        ..kind = cached.kind
        ..html = cached.html
        ..imagesJson = cached.imagesJson
        ..headersJson = cached.headersJson;
      await _isar.chapterRecords.put(row);
    }
    await _isar.libraryRecords.put(
      LibraryRecord()
        ..bookId = savedBook.id
        ..payload = jsonEncode(savedBook.toJson()),
    );
  }

  Future<LibrarySnapshot> _snapshot() async {
    final books = await _isar.libraryRecords.where().findAll();
    final chapters = await _isar.chapterRecords.where().findAll();
    final entries = <LibrarySnapshotEntry>[];
    for (final row in books) {
      final book = await _decodeBook(row);
      final contents = <int, ReaderContent>{};
      for (final chapter in chapters) {
        if (chapter.bookId == book.id &&
            chapter.chapterIndex < book.chapters.length) {
          contents[chapter.chapterIndex] = await _decodeChapter(chapter);
        }
      }
      entries.add(LibrarySnapshotEntry(book, contents));
    }
    return LibrarySnapshot(entries);
  }

  @override
  Future<LibrarySnapshot> snapshot() =>
      _serialized(() => _isar.writeTxn(_snapshot));

  @override
  Future<void> replaceSnapshot(
    LibrarySnapshot incoming, {
    required String expectedFingerprint,
  }) => _serialized(() async {
    // Stage append-only, content-addressed files. Existing files are retained
    // until the new rows commit, including when staging or the transaction fails.
    final books = <LibraryRecord>[];
    final chapters = <ChapterRecord>[];
    for (final entry in incoming.entries) {
      books.add(await _prepareBook(entry.book));
      for (final chapter in entry.contents.entries) {
        chapters.add(
          await _prepareChapter(entry.book.id, chapter.key, chapter.value),
        );
      }
    }
    await _isar.writeTxn(() async {
      final previous = await _snapshot();
      final recovery = previous.encode();
      if (previous.fingerprint != expectedFingerprint) {
        throw StateError(
          'Thư viện đã thay đổi. Hãy tải lại trước khi khôi phục.',
        );
      }
      await _recoveries.create(recursive: true);
      var revision = DateTime.now().microsecondsSinceEpoch;
      while (await File('${_recoveries.path}/recovery-$revision.json')
          .exists()) {
        revision++;
      }
      final target = '${_recoveries.path}/recovery-$revision.json';
      final pending = File('$target.pending');
      // A complete, flushed recovery image is required before the first mutation.
      try {
        await pending.writeAsBytes(recovery, flush: true);
        await pending.rename(target);
      } finally {
        if (await pending.exists()) await pending.delete();
      }
      await _isar.chapterRecords.clear();
      await _isar.libraryRecords.clear();
      await _isar.libraryRecords.putAll(books);
      await _isar.chapterRecords.putAll(chapters);
    });
    _invalidatePendingReads();
  });

  @override
  Future<Uint8List?> recoverySnapshot() => _serialized(() async {
    if (!await _recoveries.exists()) return null;
    final files = await _recoveries
        .list()
        .where(
          (entry) =>
              entry is File &&
              RegExp(r'^recovery-\d+\.json$')
                  .hasMatch(entry.uri.pathSegments.last),
        )
        .cast<File>()
        .toList();
    if (files.isEmpty) return null;
    files.sort((a, b) => b.path.compareTo(a.path));
    if (await files.first.length() > LibrarySnapshot.maxBytes) {
      throw const FormatException('Bản phục hồi vượt giới hạn 128 MB.');
    }
    return files.first.readAsBytes();
  });

  @override
  Future<void> close() => _serialized(() async {
    await _isar.close();
  });
}
