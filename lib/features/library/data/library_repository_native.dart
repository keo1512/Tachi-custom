import 'dart:convert';
import 'dart:typed_data';

import 'package:html/parser.dart' as html_parser;
import 'package:isar_community/isar.dart';
import 'package:path_provider/path_provider.dart';

import '../domain/library_book.dart';
import 'attachment_store.dart';
import 'isar_models.dart';
import 'library_repository.dart';

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
  return _IsarLibraryRepository(isar, await AttachmentStore.open(directory));
}

class _IsarLibraryRepository extends LibraryRepository {
  _IsarLibraryRepository(this._isar, this._attachments);
  final Isar _isar;
  final AttachmentStore _attachments;
  Future<LibraryBook> _decodeBook(LibraryRecord row) async {
    final book = LibraryBook.fromJson(
      Map<String, dynamic>.from(jsonDecode(row.payload) as Map),
    );
    return book.copyWith(cover: await _attachments.resolve(book.cover));
  }

  @override
  Future<List<LibraryBook>> list() async => Future.wait(
    (await _isar.libraryRecords.where().findAll()).map(_decodeBook),
  );
  @override
  Future<LibraryBook?> find(String id) async {
    final row = await _isar.libraryRecords
        .filter()
        .bookIdEqualTo(id)
        .findFirst();
    return row == null ? null : _decodeBook(row);
  }

  @override
  Future<String> storeAttachment(
    String bookId,
    Uint8List bytes,
    String mediaType,
  ) {
    if (bytes.length > LibraryRepository.maxImageBytes) {
      throw const FormatException('Ảnh vượt giới hạn 8 MB.');
    }
    return _attachments.store(bookId, bytes, mediaType);
  }

  @override
  Future<void> save(LibraryBook book) async {
    if (book.cover.startsWith('data:image/')) {
      final uri = UriData.parse(book.cover);
      book = book.copyWith(
        cover: await storeAttachment(
          book.id,
          Uint8List.fromList(uri.contentAsBytes()),
          uri.mimeType,
        ),
      );
    }
    validateBook(book);
    final row = LibraryRecord()
      ..bookId = book.id
      ..payload = jsonEncode(book.toJson());
    await _isar.writeTxn(() => _isar.libraryRecords.put(row));
  }

  @override
  Future<void> remove(String id) async {
    await _isar.writeTxn(() async {
      await _isar.libraryRecords.filter().bookIdEqualTo(id).deleteAll();
      await _isar.chapterRecords.filter().bookIdEqualTo(id).deleteAll();
    });
    await _attachments.removeBook(id);
  }

  @override
  Future<ReaderContent?> readChapter(String bookId, int index) async {
    final row = await _isar.chapterRecords
        .filter()
        .chapterKeyEqualTo(jsonEncode([bookId, index]))
        .findFirst();
    if (row == null) return null;
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

  @override
  Future<void> saveChapter(
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
        image.attributes['src'] = await storeAttachment(
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
          await storeAttachment(
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
    final row = ChapterRecord()
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
    await _isar.writeTxn(() => _isar.chapterRecords.put(row));
  }

  @override
  Future<void> clear() async {
    await _isar.writeTxn(() async {
      await _isar.libraryRecords.clear();
      await _isar.chapterRecords.clear();
    });
    await _attachments.clear();
  }

  @override
  Future<void> deleteChapter(String bookId, int index) async {
    await _isar.writeTxn(
      () => _isar.chapterRecords
          .filter()
          .chapterKeyEqualTo(jsonEncode([bookId, index]))
          .deleteAll(),
    );
  }

  @override
  Future<void> replaceChapterOrder(
    LibraryBook book,
    List<int?> previousIndices,
  ) async {
    if (previousIndices.length != book.chapters.length) {
      throw const FormatException('Ánh xạ chương không hợp lệ.');
    }
    if (book.cover.startsWith('data:image/')) {
      final uri = UriData.parse(book.cover);
      book = book.copyWith(
        cover: await storeAttachment(
          book.id,
          Uint8List.fromList(uri.contentAsBytes()),
          uri.mimeType,
        ),
      );
    }
    validateBook(book);
    final savedBook = book;
    await _isar.writeTxn(() async {
      final old = {
        for (final row
            in await _isar.chapterRecords
                .filter()
                .bookIdEqualTo(savedBook.id)
                .findAll())
          row.chapterIndex: row,
      };
      await _isar.chapterRecords
          .filter()
          .bookIdEqualTo(savedBook.id)
          .deleteAll();
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
    });
  }

  @override
  Future<void> close() async {
    await _isar.close();
  }
}
