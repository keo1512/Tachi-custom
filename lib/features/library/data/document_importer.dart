import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:xml/xml.dart';

import '../domain/library_book.dart';
import 'library_repository.dart';
import 'local_comic_metadata.dart';
import 'local_comic_files_platform.dart';

class DocumentImporter {
  DocumentImporter({
    Future<Map<String, Uint8List>> Function(Uint8List)? extractRar,
    this.stableComicChapterIds = false,
  }) : _extractRar = extractRar ?? NativeLocalComicFilesPlatform().extractRar;
  final Future<Map<String, Uint8List>> Function(Uint8List) _extractRar;
  final bool stableComicChapterIds;
  static const maxInputBytes = 100 * 1024 * 1024;
  static const maxExpandedBytes = 200 * 1024 * 1024;
  static const maxEntryBytes = 8 * 1024 * 1024;
  static const maxEntries = 10000;

  Future<LibraryBook> import(
    String filename,
    Uint8List bytes,
    LibraryRepository repo, {
    List<String>? defaultCategories,
  }) async {
    if (bytes.isEmpty || bytes.length > maxInputBytes) {
      throw const FormatException('Tệp trống hoặc vượt giới hạn nhập 100 MB.');
    }
    final id = sha256.convert(bytes).toString();
    final revision = repo.replacementRevision;
    final existing = await repo.find(id);
    // Content-addressed import is idempotent and keeps all reader/library state.
    if (existing != null) return existing;
    final extension = filename.toLowerCase().split('.').last;
    final title = filename
        .split(RegExp(r'[/\\]'))
        .last
        .replaceFirst(RegExp(r'\.[^.]+$'), '');
    // Parsing stages media in memory; no active library files are written.
    final staging = MemoryLibraryRepository();
    final parsed = switch (extension) {
      'txt' => await _text(id, title, bytes),
      'epub' => await _epub(id, title, bytes, staging),
      'cbz' || 'zip' => await _comic(id, title, bytes, staging),
      'cbr' || 'rar' => await _comicEntries(
        id,
        title,
        await _extractRar(bytes),
        staging,
      ),
      'png' ||
      'jpg' ||
      'jpeg' ||
      'webp' ||
      'gif' ||
      'avif' ||
      'heic' ||
      'heif' ||
      'jxl' => await _singleImage(id, title, filename, bytes, staging),
      _ => throw const FormatException(
        'Hỗ trợ EPUB, TXT, CBZ, ZIP, CBR, RAR và tệp ảnh truyện.',
      ),
    };
    final book = parsed.book.copyWith(
      createdAt: DateTime.now(),
      categories: defaultCategories,
    );
    repo.validateBook(book);
    for (var index = 0; index < parsed.contents.length; index++) {
      repo.validateChapter(index, parsed.contents[index]);
    }
    return repo.insertBook(
      book,
      contents: {
        for (var index = 0; index < parsed.contents.length; index++)
          index: parsed.contents[index],
      },
      expectedRevision: revision,
    );
  }

  Future<_ParsedBook> _text(String id, String title, Uint8List bytes) async {
    if (bytes.length > 8 * 1024 * 1024) {
      throw const FormatException('Tệp TXT vượt giới hạn 8 MB.');
    }
    final text = utf8
        .decode(bytes)
        .replaceFirst(RegExp('^\uFEFF'), '')
        .replaceAll('\r\n', '\n')
        .trim();
    if (text.isEmpty) throw const FormatException('Tệp TXT không có nội dung.');
    final matches = RegExp(
      r'^(?:chương|chapter|卷|第)[ \t]*[^\n]{0,100}$',
      multiLine: true,
      caseSensitive: false,
    ).allMatches(text).toList();
    final sections = <({String title, String text})>[];
    if (matches.isEmpty) {
      sections.add((title: title, text: text));
    } else {
      if (text.substring(0, matches.first.start).trim().isNotEmpty) {
        sections.add((
          title: 'Mở đầu',
          text: text.substring(0, matches.first.start).trim(),
        ));
      }
      for (var index = 0; index < matches.length; index++) {
        final match = matches[index];
        final end = index + 1 < matches.length
            ? matches[index + 1].start
            : text.length;
        sections.add((
          title: match.group(0)!.trim(),
          text: text.substring(match.end, end).trim(),
        ));
      }
    }
    final contents = sections
        .map(
          (section) => ReaderContent(
            kind: 'novel',
            html: section.text
                .split(RegExp(r'\n\s*\n'))
                .map(
                  (paragraph) =>
                      '<p>${const HtmlEscape().convert(paragraph).replaceAll('\n', '<br/>')}</p>',
                )
                .join(),
          ),
        )
        .toList();
    return _ParsedBook(
      LibraryBook(
        id: id,
        title: title,
        engine: 'local',
        kind: 'novel',
        chapters: [
          for (var i = 0; i < sections.length; i++)
            BookChapter(
              id: '$id:$i',
              title: sections[i].title,
              index: i,
              downloaded: true,
            ),
        ],
      ),
      contents,
    );
  }

  Future<_ParsedBook> _comic(
    String id,
    String title,
    Uint8List bytes,
    LibraryRepository repo,
  ) async {
    final zip = _SafeZip(bytes);
    return _comicReader(id, title, zip.names, zip.read, repo);
  }

  /// Native RAR extraction and Files-folder scans share archive validation and
  /// the same natural page/chapter ordering, metadata and cover handling.
  Future<LibraryBook> importComicEntries(
    String id,
    String title,
    Map<String, Uint8List> entries,
    LibraryRepository repo,
  ) async {
    final staging = MemoryLibraryRepository();
    final parsed = await _comicEntries(id, title, entries, staging);
    return repo.insertBook(
      parsed.book,
      contents: {
        for (var i = 0; i < parsed.contents.length; i++) i: parsed.contents[i],
      },
      expectedRevision: repo.replacementRevision,
    );
  }

  Future<_ParsedBook> _comicEntries(
    String id,
    String title,
    Map<String, Uint8List> entries,
    LibraryRepository repo,
  ) {
    if (entries.isEmpty || entries.length > maxEntries) {
      throw const FormatException(
        'Thư mục/archive trống hoặc có quá nhiều mục.',
      );
    }
    var expanded = 0;
    for (final entry in entries.entries) {
      _safePath(entry.key);
      expanded += entry.value.length;
      if (entry.value.length > maxEntryBytes || expanded > maxExpandedBytes) {
        throw const FormatException(
          'Ảnh/archive vượt giới hạn 8 MB/mục hoặc 200 MB tổng.',
        );
      }
    }
    return _comicReader(
      id,
      title,
      entries.keys,
      (name) => entries[name]!,
      repo,
    );
  }

  Future<_ParsedBook> _comicReader(
    String id,
    String title,
    Iterable<String> entryNames,
    Uint8List Function(String) read,
    LibraryRepository repo,
  ) async {
    final names =
        entryNames.where((name) => localImageType(name) != null).toList()
          ..sort(naturalFileCompare);
    if (names.isEmpty) {
      throw const FormatException(
        'ZIP/CBZ không có ảnh truyện được nhận diện.',
      );
    }
    final metadata = entryNames.contains('details.json')
        ? LocalComicMetadata.decode(read('details.json'))
        : null;
    final covers = names
        .where(
          (name) =>
              !name.contains('/') &&
              name.toLowerCase().split('.').first == 'cover',
        )
        .toList();
    final coverName =
        covers.where((name) => name.toLowerCase() == 'cover.jpg').firstOrNull ??
        covers.firstOrNull;
    final pageNames = names.where((name) => !covers.contains(name)).toList();
    if (pageNames.isEmpty) pageNames.addAll(names);
    final groups = <String, List<String>>{};
    for (final name in pageNames) {
      final slash = name.lastIndexOf('/');
      final group = slash < 0 ? '' : name.substring(0, slash);
      (groups[group] ??= []).add(name);
    }
    final folders = groups.keys.toList()..sort(naturalFileCompare);
    final contents = <ReaderContent>[];
    final chapters = <BookChapter>[];
    for (final folder in folders) {
      final pages = <String>[];
      for (final name in groups[folder]!) {
        pages.add(
          await repo.storeAttachment(id, read(name), localImageType(name)!),
        );
      }
      final index = contents.length;
      contents.add(ReaderContent(kind: 'manga', images: pages));
      chapters.add(
        BookChapter(
          id: stableComicChapterIds ? '$id:folder:$folder' : '$id:$index',
          title: folder.isEmpty ? title : folder.split('/').last,
          index: index,
          downloaded: true,
        ),
      );
    }
    final cover = coverName == null
        ? contents.first.images.first
        : await repo.storeAttachment(
            id,
            read(coverName),
            localImageType(coverName)!,
          );
    var book = LibraryBook(
      id: id,
      title: title,
      kind: 'manga',
      cover: cover,
      chapters: chapters,
    );
    if (metadata != null) book = metadata.apply(book);
    return _ParsedBook(book, contents);
  }

  Future<_ParsedBook> _singleImage(
    String id,
    String title,
    String filename,
    Uint8List bytes,
    LibraryRepository repo,
  ) async {
    final image = await repo.storeAttachment(
      id,
      bytes,
      localImageType(filename)!,
    );
    return _ParsedBook(
      LibraryBook(
        id: id,
        title: title,
        kind: 'manga',
        cover: image,
        chapters: [
          BookChapter(id: '$id:0', title: title, index: 0, downloaded: true),
        ],
      ),
      [
        ReaderContent(kind: 'manga', images: [image]),
      ],
    );
  }

  Future<_ParsedBook> _epub(
    String id,
    String fallbackTitle,
    Uint8List bytes,
    LibraryRepository repo,
  ) async {
    final zip = _SafeZip(bytes);
    if (zip.names.contains('META-INF/encryption.xml')) {
      throw const FormatException(
        'EPUB có tài nguyên mã hóa chưa được hỗ trợ.',
      );
    }
    final container = _xml(zip.read('META-INF/container.xml'));
    final rootfiles = _elements(container, 'rootfile').toList();
    if (rootfiles.isEmpty) {
      throw const FormatException('EPUB thiếu rootfile trong container.xml.');
    }
    final packagePath = rootfiles.first.getAttribute('full-path');
    if (packagePath == null) {
      throw const FormatException('EPUB thiếu đường dẫn OPF.');
    }
    _safePath(packagePath);
    final package = _xml(zip.read(packagePath));
    String metadata(String name) =>
        _elements(
          package,
          name,
        ).map((element) => element.innerText.trim()).firstOrNull ??
        '';
    final seriesNames = <String>{};
    final metaElements = _elements(package, 'meta').toList();
    for (final meta in metaElements) {
      if (meta.getAttribute('name') == 'calibre:series') {
        final name = (meta.getAttribute('content') ?? '').trim();
        if (name.isNotEmpty) seriesNames.add(name);
      }
      if (meta.getAttribute('property') == 'belongs-to-collection') {
        final id = meta.getAttribute('id');
        if (id != null &&
            metaElements.any(
              (value) =>
                  value.getAttribute('refines') == '#$id' &&
                  value.getAttribute('property') == 'collection-type' &&
                  value.innerText.trim() == 'series',
            )) {
          final name = meta.innerText.trim();
          if (name.isNotEmpty) seriesNames.add(name);
        }
      }
    }
    final items = <String, XmlElement>{};
    for (final item in _elements(package, 'item')) {
      final key = item.getAttribute('id');
      if (key == null || items.containsKey(key)) {
        throw const FormatException('Manifest EPUB có ID trống hoặc trùng.');
      }
      items[key] = item;
    }
    final spine = _elements(
      package,
      'itemref',
    ).where((element) => element.getAttribute('linear') != 'no').toList();
    if (spine.isEmpty) {
      throw const FormatException('EPUB không có chương trong spine.');
    }
    String? coverId;
    for (final meta in _elements(package, 'meta')) {
      if (meta.getAttribute('name') == 'cover') {
        coverId = meta.getAttribute('content');
      }
    }
    final coverItem =
        items.values
            .where(
              (item) => (item.getAttribute('properties') ?? '')
                  .split(' ')
                  .contains('cover-image'),
            )
            .firstOrNull ??
        items[coverId];
    var cover = '';
    if (coverItem != null) {
      final coverPath = _resolve(
        packagePath,
        coverItem.getAttribute('href') ?? '',
      );
      final type = localImageType(coverPath);
      if (type != null) {
        cover = await repo.storeAttachment(id, zip.read(coverPath), type);
      }
    }
    final contents = <ReaderContent>[];
    final chapters = <BookChapter>[];
    final assetCache = <String, String>{};
    for (final itemref in spine) {
      final item = items[itemref.getAttribute('idref')];
      if (item == null) {
        throw const FormatException(
          'Spine EPUB tham chiếu chương không có trong manifest.',
        );
      }
      final path = _resolve(packagePath, item.getAttribute('href') ?? '');
      final document = _xml(zip.read(path));
      final body = _elements(document, 'body').firstOrNull;
      if (body == null) {
        throw const FormatException('Chương EPUB thiếu phần body.');
      }
      final chapterTitle = _elements(
        document,
        'title',
      ).firstOrNull?.innerText.trim();
      for (final unsafe
          in document.descendants
              .whereType<XmlElement>()
              .where(
                (element) => {
                  'script',
                  'iframe',
                  'object',
                  'embed',
                  'style',
                  'link',
                  'form',
                }.contains(element.name.local),
              )
              .toList()) {
        unsafe.parent?.children.remove(unsafe);
      }
      for (final element in body.descendants.whereType<XmlElement>().toList()) {
        element.attributes.removeWhere(
          (attribute) =>
              attribute.name.local.toLowerCase().startsWith('on') ||
              attribute.name.local == 'style',
        );
        if (element.name.local == 'img' || element.name.local == 'image') {
          final source =
              element.getAttribute('src') ??
              element.getAttribute(
                'href',
                namespaceUri: 'http://www.w3.org/1999/xlink',
              );
          if (source == null || source.isEmpty) continue;
          final resourcePath = _resolve(path, source);
          final type = localImageType(resourcePath);
          if (type == null) {
            throw const FormatException('EPUB chứa ảnh không được hỗ trợ.');
          }
          final reference =
              assetCache[resourcePath] ??
              await repo.storeAttachment(id, zip.read(resourcePath), type);
          assetCache[resourcePath] = reference;
          element.attributes.removeWhere(
            (attribute) => {'src', 'href'}.contains(attribute.name.local),
          );
          element.setAttribute('src', reference);
          if (element.name.local == 'image') {
            final parent = element.parent;
            if (parent != null) {
              final image = XmlElement(XmlName.qualified('img'));
              image.setAttribute('src', reference);
              parent.children[parent.children.indexOf(element)] = image;
            }
          }
          if (cover.isEmpty) cover = reference;
        }
      }
      final index = contents.length;
      contents.add(
        ReaderContent(
          kind: 'novel',
          html: body.children.map((node) => node.toXmlString()).join(),
        ),
      );
      chapters.add(
        BookChapter(
          id: '$id:$index',
          title: chapterTitle == null || chapterTitle.isEmpty
              ? 'Chương ${index + 1}'
              : chapterTitle,
          index: index,
          downloaded: true,
        ),
      );
    }
    return _ParsedBook(
      LibraryBook(
        id: id,
        title: metadata('title').isEmpty ? fallbackTitle : metadata('title'),
        author: metadata('creator'),
        series: seriesNames.length == 1 ? seriesNames.single : '',
        description: metadata('description'),
        cover: cover,
        kind: 'novel',
        chapters: chapters,
      ),
      contents,
    );
  }
}

class _ParsedBook {
  const _ParsedBook(this.book, this.contents);
  final LibraryBook book;
  final List<ReaderContent> contents;
}

XmlDocument _xml(Uint8List bytes) => XmlDocument.parse(utf8.decode(bytes));
Iterable<XmlElement> _elements(XmlNode node, String local) => node.descendants
    .whereType<XmlElement>()
    .where((element) => element.name.local == local);

void _safePath(String path) {
  if (path.isEmpty ||
      path.startsWith('/') ||
      path.contains('\\') ||
      path.contains('\u0000') ||
      path.contains(':') ||
      path.split('/').any((part) => part == '..' || part == '.')) {
    throw const FormatException('Đường dẫn trong archive không hợp lệ.');
  }
}

String _resolve(String base, String reference) {
  final uri = Uri.parse(reference);
  if (uri.hasScheme || uri.hasAuthority || uri.path.startsWith('/')) {
    throw const FormatException(
      'EPUB chỉ hỗ trợ tài nguyên nằm trong tệp sách.',
    );
  }
  final parts = base.split('/')..removeLast();
  for (final part in Uri.decodeComponent(uri.path).split('/')) {
    if (part.isEmpty || part == '.') continue;
    if (part == '..') {
      if (parts.isEmpty) {
        throw const FormatException('Tài nguyên EPUB nằm ngoài archive.');
      }
      parts.removeLast();
    } else {
      parts.add(part);
    }
  }
  final result = parts.join('/');
  _safePath(result);
  return result;
}

class _SafeZip {
  _SafeZip(Uint8List bytes) {
    final directory = ZipDirectory()..read(InputMemoryStream(bytes));
    if (directory.fileHeaders.isEmpty ||
        directory.fileHeaders.length > DocumentImporter.maxEntries ||
        directory.totalCentralDirectoryEntries !=
            directory.fileHeaders.length) {
      throw const FormatException('ZIP không hợp lệ hoặc có quá nhiều mục.');
    }
    var expanded = 0;
    for (final header in directory.fileHeaders) {
      _safePath(
        header.filename.endsWith('/')
            ? header.filename.substring(0, header.filename.length - 1)
            : header.filename,
      );
      expanded += header.uncompressedSize;
      if (header.uncompressedSize > DocumentImporter.maxEntryBytes ||
          expanded > DocumentImporter.maxExpandedBytes) {
        throw const FormatException(
          'ZIP vượt giới hạn 8 MB/mục hoặc 200 MB sau giải nén.',
        );
      }
      if (header.generalPurposeBitFlag & 1 != 0 ||
          !{0, 8}.contains(header.compressionMethod) ||
          ((header.externalFileAttributes >> 16) & 0xf000) == 0xa000) {
        throw const FormatException(
          'ZIP mã hóa, liên kết hoặc kiểu nén này chưa được hỗ trợ.',
        );
      }
      if (header.filename != header.file?.filename ||
          _headers.containsKey(header.filename)) {
        throw const FormatException(
          'Tên tệp ZIP không nhất quán hoặc bị trùng.',
        );
      }
      if (!header.filename.endsWith('/')) _headers[header.filename] = header;
    }
  }
  final Map<String, ZipFileHeader> _headers = {};
  Iterable<String> get names => _headers.keys;
  Uint8List read(String path) {
    final header = _headers[path];
    if (header == null) throw FormatException('EPUB/ZIP thiếu tệp: $path');
    final raw = header.file!.getStream(decompress: false).toUint8List();
    final output = _BoundedOutput(header.uncompressedSize);
    if (header.compressionMethod == 8) {
      Inflate(raw, output: output);
    } else {
      output.writeBytes(raw);
    }
    final bytes = output.getBytes();
    if (bytes.length != header.uncompressedSize ||
        getCrc32(bytes) != header.crc32) {
      throw FormatException('Kích thước hoặc CRC của tệp không đúng: $path');
    }
    return bytes;
  }
}

class _BoundedOutput extends OutputMemoryStream {
  _BoundedOutput(this.maximum) : super(size: maximum > 32768 ? 32768 : maximum);
  final int maximum;
  void _check(int count) {
    if (length + count > maximum) {
      throw const FormatException('Dữ liệu giải nén vượt kích thước khai báo.');
    }
  }

  @override
  void writeByte(int value) {
    _check(1);
    super.writeByte(value);
  }

  @override
  void writeBytes(List<int> bytes, {int? length}) {
    _check(length ?? bytes.length);
    super.writeBytes(bytes, length: length);
  }

  @override
  void writeStream(InputStream stream) {
    _check(stream.length);
    super.writeStream(stream);
  }

  @override
  void writeBackReference(int distance, int count) {
    _check(count);
    super.writeBackReference(distance, count);
  }
}
