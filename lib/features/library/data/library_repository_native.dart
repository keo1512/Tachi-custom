import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:html/parser.dart' as html_parser;
import 'package:crypto/crypto.dart';
import 'package:isar_community/isar.dart';
import 'package:path_provider/path_provider.dart';

import '../domain/library_book.dart';
import 'attachment_store_native.dart';
import 'isar_models.dart';
import 'library_repository.dart';
import 'library_mutation.dart';
import '../../downloads/domain/download_deletion.dart';
import 'library_snapshot.dart';
import 'library_cache_maintenance.dart';
import 'backup_validation.dart';
import 'attachment_gc.dart';
import 'library_recovery_store.dart';

Future<LibraryRepository> openLibrary({String? directoryPath}) async {
  final directory =
      directoryPath ??
      await resolveActiveLibraryDirectory(
        (await getApplicationDocumentsDirectory()).path,
      );
  final existing = Isar.getInstance('tachi_books');
  if (existing != null &&
      (existing.directory == null ||
          Directory(existing.directory!).absolute.path !=
              Directory(directory).absolute.path)) {
    throw StateError('Đóng thư viện cũ trước khi mở vị trí dữ liệu khác.');
  }
  final isar =
      existing ??
      await Isar.open(
        [LibraryRecordSchema, ChapterRecordSchema],
        directory: directory,
        name: 'tachi_books',
      );
  try {
    return _IsarLibraryRepository(
      isar,
      await AttachmentStore.open(directory),
      Directory('$directory/backup-recovery'),
    );
  } catch (_) {
    if (existing == null) await isar.close();
    rethrow;
  }
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
    return book.copyWith(
      cover: await _attachments.resolve(book.cover),
      originalCover: await _attachments.resolve(book.originalCover),
    );
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
    if (book.originalCover.startsWith('data:image/')) {
      final uri = UriData.parse(book.originalCover);
      book = book.copyWith(
        originalCover: await _storeAttachment(
          book.id,
          Uint8List.fromList(uri.contentAsBytes()),
          uri.mimeType,
        ),
      );
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
  Future<int> mutateBooks(
    Iterable<String> ids,
    LibraryBook Function(LibraryBook) transform, {
    int? expectedRevision,
  }) {
    final distinct = ids.toSet();
    if (distinct.length > 10000) {
      throw const FormatException('Thao tác có quá nhiều sách.');
    }
    return _serialized(() async {
      var count = 0;
      await _isar.writeTxn(() async {
        checkLibraryRevision(replacementRevision, expectedRevision);
        final saved = <LibraryRecord>[];
        for (final id in distinct) {
          final row = await _bookRow(id);
          if (row == null) continue;
          final updated = transform(_book(row));
          if (updated.id != id) {
            throw StateError('Không thể đổi mã sách trong cập nhật metadata.');
          }
          saved.add(await _prepareBook(updated));
        }
        await _isar.libraryRecords.putAll(saved);
        count = saved.length;
      });
      return count;
    });
  }

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
  Future<int> deleteDownloadedChapters(
    LibraryBook expected,
    Iterable<String> chapterIds, {
    required int expectedRevision,
    bool protectBookmarks = true,
    bool readOnly = false,
  }) {
    return deleteDownloadedChaptersBatch(
      [LibraryChapterDeletion(expected, chapterIds)],
      expectedRevision: expectedRevision,
      protectBookmarks: protectBookmarks,
      readOnly: readOnly,
    );
  }

  @override
  Future<int> deleteDownloadedChaptersBatch(
    Iterable<LibraryChapterDeletion> selections, {
    required int expectedRevision,
    bool protectBookmarks = true,
    bool readOnly = false,
  }) {
    final values = checkedChapterDeletions(selections);
    return _serialized(() async {
      var count = 0;
      final cleanup =
          <({String id, Set<String> candidates, Set<String> retained})>[];
      final assetPattern = RegExp(r'tachi-asset://[a-f0-9]{64}/[a-f0-9]{64}');
      Iterable<String> references(ChapterRecord chapter) => [
        ...assetPattern
            .allMatches(chapter.html)
            .map((match) => match.group(0)!),
        ...assetPattern
            .allMatches(chapter.imagesJson)
            .map((match) => match.group(0)!),
      ];
      await _isar.writeTxn(() async {
        checkLibraryRevision(replacementRevision, expectedRevision);
        for (final selection in values) {
          final expected = selection.book;
          final candidates = <String>{}, retained = <String>{};
          final row = await _bookRow(expected.id);
          if (row == null) throw StateError('Sách đã được xóa khỏi thư viện');
          final book = _book(row);
          if (bookSourceIdentity(book) != bookSourceIdentity(expected)) {
            throw StateError('Nguồn của sách đã thay đổi. Hãy mở lại sách.');
          }
          final indices = downloadDeletionIndices(
            book,
            selection.chapterIds,
            protectBookmarks: protectBookmarks,
            readOnly: readOnly,
          ).toSet();
          final cached = await _isar.chapterRecords
              .filter()
              .bookIdEqualTo(book.id)
              .findAll();
          final deleted = cached
              .where((chapter) => indices.contains(chapter.chapterIndex))
              .toList();
          final actual = {
            ...deleted.map((chapter) => chapter.chapterIndex),
            ...indices.where((index) => book.chapters[index].downloaded),
          };
          if (actual.isEmpty) continue;
          final chapters = [...book.chapters];
          for (final index in actual) {
            chapters[index] = chapters[index].copyWith(downloaded: false);
          }
          final updated = book.copyWith(chapters: chapters);
          validateBook(updated);
          row.payload = jsonEncode(updated.toJson());
          await _isar.chapterRecords.deleteAll(
            deleted.map((chapter) => chapter.id).toList(),
          );
          await _isar.libraryRecords.put(row);
          count += actual.length;
          candidates.addAll(deleted.expand(references));
          retained.addAll(
            cached
                .where((chapter) => !actual.contains(chapter.chapterIndex))
                .expand(references),
          );
          retained.addAll(
            assetPattern.allMatches(book.cover).map((match) => match.group(0)!),
          );
          retained.addAll(
            assetPattern
                .allMatches(book.originalCover)
                .map((match) => match.group(0)!),
          );
          cleanup.add((
            id: book.id,
            candidates: candidates,
            retained: retained,
          ));
        }
      });
      if (count > 0) {
        _invalidatePendingReads();
        for (final entry in cleanup) {
          await _attachments.removeUnreferenced(
            entry.id,
            entry.candidates,
            entry.retained,
          );
        }
      }
      return count;
    });
  }

  @override
  Future<void> replaceChapterOrder(
    LibraryBook book,
    List<int?> previousIndices,
  ) => _serialized(() async {
    if (previousIndices.length != book.chapters.length) {
      throw const FormatException('Ánh xạ chương không hợp lệ.');
    }
    if (book.originalCover.startsWith('data:image/')) {
      final uri = UriData.parse(book.originalCover);
      book = book.copyWith(
        originalCover: await _storeAttachment(
          book.id,
          Uint8List.fromList(uri.contentAsBytes()),
          uri.mimeType,
        ),
      );
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
    final identities = <String>{};
    final positions = <String>{};
    for (final row in books) {
      final book = await _decodeBook(row);
      if (row.bookId != book.id || !identities.add(book.id)) {
        throw const FormatException(
          'Mã truyện trong cơ sở dữ liệu không khớp hoặc bị lặp.',
        );
      }
      final contents = <int, ReaderContent>{};
      for (final chapter in chapters) {
        if (chapter.bookId == book.id) {
          if (chapter.chapterIndex < 0 ||
              chapter.chapterIndex >= book.chapters.length ||
              !positions.add(jsonEncode([book.id, chapter.chapterIndex]))) {
            throw const FormatException(
              'Nội dung chương không thuộc mục lục hoặc bị lặp. Dữ liệu được giữ nguyên.',
            );
          }
          contents[chapter.chapterIndex] = await _decodeChapter(chapter);
        }
      }
      entries.add(LibrarySnapshotEntry(book, contents));
    }
    if (chapters.any((row) => !identities.contains(row.bookId))) {
      throw const FormatException(
        'Nội dung không thuộc truyện trong thư viện. Dữ liệu được giữ nguyên.',
      );
    }
    return LibrarySnapshot(entries);
  }

  @override
  Future<LibrarySnapshot> snapshot() =>
      _serialized(() => _isar.writeTxn(_snapshot));

  Future<Set<String>> _allRawAttachmentKeys() async {
    final retained = rawAttachmentKeys([
      for (final row in await _isar.libraryRecords.where().findAll())
        jsonDecode(row.payload),
      for (final row in await _isar.chapterRecords.where().findAll())
        [row.html, jsonDecode(row.imagesJson), jsonDecode(row.headersJson)],
    ]);
    // Own recovery JSON can contain future/unknown attachment references. Keep
    // those bytes too, even though ordinary snapshots hydrate known media.
    if (await _recoveries.exists()) {
      if (await FileSystemEntity.type(_recoveries.path, followLinks: false) !=
          FileSystemEntityType.directory) {
        throw const FileSystemException('Vị trí sao lưu không an toàn.');
      }
      await for (final entity in _recoveries.list(followLinks: false)) {
        if (entity is! File ||
            !RegExp(r'^(?:raw-)?recovery-\d{16,20}\.json$')
                .hasMatch(entity.uri.pathSegments.last)) {
          continue;
        }
        if (await entity.length() > LibrarySnapshot.maxBytes) {
          throw const FormatException('Bản phục hồi quá lớn; chưa dọn tệp.');
        }
        retained.addAll(
          rawAttachmentKeys(jsonDecode(await entity.readAsString())),
        );
      }
    }
    return retained;
  }

  @override
  Future<LibraryStorageReport> inspectStorage() => _serialized(() async {
    return _isar.writeTxn(() async {
      final image = await _snapshot();
      BackupValidator(this).validateSnapshot(image.encode());
      final unused = await findUnusedAttachments(
        _attachments.directory,
        await _allRawAttachmentKeys(),
      );
      final entries = {for (final entry in image.entries) entry.book.id: entry};
      final media = <String>{};
      var payloadBytes = 0;
      for (final row in await _isar.chapterRecords.where().findAll()) {
        final content = entries[row.bookId]?.contents[row.chapterIndex];
        if (content == null || !chapterIsOffline(content)) continue;
        payloadBytes +=
            utf8Bytes(row.html) +
            utf8Bytes(row.imagesJson) +
            utf8Bytes(row.headersJson);
        media.addAll(
          rawAttachmentKeys([
            row.html,
            jsonDecode(row.imagesJson),
            jsonDecode(row.headersJson),
          ]),
        );
      }
      for (final key in media) {
        final file = File('${_attachments.directory.path}/$key');
        if (await FileSystemEntity.type(file.path, followLinks: false) !=
            FileSystemEntityType.file) {
          throw const FileSystemException(
            'Không đọc được tệp nội dung offline.',
          );
        }
        payloadBytes += await file.length();
      }
      return snapshotStorageReport(
        image,
        replacementRevision,
        downloadedBytes: payloadBytes,
        unusedAttachmentFiles: unused.length,
        unusedAttachmentBytes: unused.fold(
          0,
          (sum, candidate) => sum + candidate.size,
        ),
      );
    });
  });

  @override
  Future<LibraryCacheMaintenanceResult> clearTransientChapterCache({
    required String expectedFingerprint,
    void Function()? guard,
  }) => _serialized(() async {
    guard?.call();
    final removed = await _isar.writeTxn(() async {
      final image = await _snapshot();
      final preserved = image.encode();
      BackupValidator(this).validateSnapshot(preserved);
      if (image.fingerprint != expectedFingerprint) {
        throw StateError(
          'Thư viện đã thay đổi. Hãy kiểm tra lại trước khi dọn cache.',
        );
      }
      final keys = transientChapterKeys(image);
      if (keys.isEmpty) return 0;
      guard?.call();
      await _writeRecoverySnapshot(preserved);
      guard?.call();
      for (final key in keys) {
        await _isar.chapterRecords
            .filter()
            .chapterKeyEqualTo(jsonEncode([key.bookId, key.index]))
            .deleteAll();
      }
      return keys.length;
    });
    if (removed > 0) _invalidatePendingReads();
    return LibraryCacheMaintenanceResult(removedChapters: removed);
  });

  @override
  Future<LibraryCacheMaintenanceResult> collectUnusedAttachments({
    required String expectedFingerprint,
    void Function()? guard,
  }) => _serialized(() async {
    guard?.call();
    return _isar.writeTxn(() async {
      final image = await _snapshot();
      final preserved = image.encode();
      BackupValidator(this).validateSnapshot(preserved);
      if (image.fingerprint != expectedFingerprint) {
        throw StateError(
          'Thư viện đã thay đổi. Hãy kiểm tra lại trước khi dọn cache.',
        );
      }
      final candidates = await findUnusedAttachments(
        _attachments.directory,
        await _allRawAttachmentKeys(),
        guard: guard,
      );
      if (candidates.isEmpty) return const LibraryCacheMaintenanceResult();
      for (final candidate in candidates) {
        guard?.call();
        await verifyUnusedAttachment(candidate, _attachments.directory);
      }
      await _writeRecoverySnapshot(preserved);
      var removed = 0;
      var bytes = 0;
      try {
        for (final candidate in candidates) {
          guard?.call();
          await verifyUnusedAttachment(candidate, _attachments.directory);
          guard?.call();
          await candidate.file.delete();
          removed++;
          bytes += candidate.size;
        }
      } catch (_) {
        throw StateError(
          'Dọn tệp chưa hoàn tất; đã dọn $removed tệp không còn được dùng. '
          'Thư viện, nội dung offline và bản sao lưu được giữ nguyên. Hãy kiểm tra lại.',
        );
      }
      return LibraryCacheMaintenanceResult(
        removedFiles: removed,
        reclaimedBytes: bytes,
      );
    });
  });

  Future<void> _writeRecoverySnapshot(Uint8List bytes) async {
    await _recoveries.create(recursive: true);
    var revision = DateTime.now().microsecondsSinceEpoch;
    while (await File('${_recoveries.path}/recovery-$revision.json').exists()) {
      revision++;
    }
    final target = '${_recoveries.path}/recovery-$revision.json';
    final raw = <String, Object>{
      'schema': 'tachi-books-raw-storage',
      'version': 1,
      'books': <Object>[],
      'chapters': <Object>[],
    };
    var budget = 0;
    void checkSize(String value) {
      // Bound JSON escaping before allocating the complete envelope.
      budget += utf8.encode(value).length * 6 + 1024;
      if (budget > LibrarySnapshot.maxBytes) {
        throw const FormatException(
          'Dữ liệu gốc quá lớn để sao lưu an toàn; chưa sửa thư viện.',
        );
      }
    }

    for (final row in await _isar.libraryRecords.where().findAll()) {
      checkSize(row.payload);
      checkSize(row.bookId);
      (raw['books'] as List).add({
        'id': row.id,
        'bookId': row.bookId,
        'payload': row.payload,
      });
    }
    for (final row in await _isar.chapterRecords.where().findAll()) {
      for (final value in [
        row.chapterKey,
        row.bookId,
        row.kind,
        row.html,
        row.imagesJson,
        row.headersJson,
      ]) {
        checkSize(value);
      }
      (raw['chapters'] as List).add({
        'id': row.id,
        'chapterKey': row.chapterKey,
        'bookId': row.bookId,
        'chapterIndex': row.chapterIndex,
        'kind': row.kind,
        'html': row.html,
        'imagesJson': row.imagesJson,
        'headersJson': row.headersJson,
      });
    }
    final rawBytes = Uint8List.fromList(utf8.encode(jsonEncode(raw)));
    if (rawBytes.length > LibrarySnapshot.maxBytes) {
      throw const FormatException(
        'Dữ liệu gốc quá lớn để sao lưu an toàn; chưa sửa thư viện.',
      );
    }
    await _writeVerifiedRecoveryFile(
      '${_recoveries.path}/raw-recovery-$revision.json',
      rawBytes,
    );
    await _writeVerifiedRecoveryFile(target, bytes);
  }

  Future<void> _writeVerifiedRecoveryFile(
    String target,
    Uint8List bytes,
  ) async {
    final pending = File('$target.pending');
    try {
      await pending.writeAsBytes(bytes, flush: true);
      if ((await sha256.bind(pending.openRead()).first).toString() !=
          sha256.convert(bytes).toString()) {
        throw const FileSystemException(
          'Không xác minh được bản phục hồi; chưa dọn dữ liệu.',
        );
      }
      await pending.rename(target);
    } finally {
      if (await pending.exists()) await pending.delete();
    }
  }

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
      final recoveryBytes = recovery ?? previous.encode();
      if (previous.fingerprint != expectedFingerprint) {
        throw StateError(
          'Thư viện đã thay đổi. Hãy tải lại trước khi khôi phục.',
        );
      }
      // A complete, flushed recovery image is required before the first mutation.
      await _writeRecoverySnapshot(recoveryBytes);
      if (beforeCommit != null) await beforeCommit();
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
