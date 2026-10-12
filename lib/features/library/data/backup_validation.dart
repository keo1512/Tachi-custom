import 'dart:convert';
import 'dart:typed_data';

import 'package:html/parser.dart' as html_parser;

import '../domain/library_book.dart';
import '../domain/chapter_list_options.dart';
import 'library_repository.dart';
import 'library_snapshot.dart';
import 'backup_configuration.dart';
import '../../sources/domain/extension_backup.dart';

class BackupValidator {
  BackupValidator(this.repository);
  final LibraryRepository repository;
  List<LibrarySnapshotEntry> validate(Uint8List bytes) =>
      validateSnapshot(bytes).entries;

  LibrarySnapshot validateSnapshot(Uint8List bytes) {
    if (bytes.isEmpty || bytes.length > LibrarySnapshot.maxBytes) {
      throw const FormatException(
        'Bản sao lưu trống hoặc vượt giới hạn 128 MB.',
      );
    }
    final root = _object(jsonDecode(utf8.decode(bytes)), 'Bản sao lưu');
    if (root['schema'] != 'tachi-books-backup' ||
        root['version'] is! int ||
        root['version'] != 1 ||
        root['entries'] is! List) {
      throw const FormatException(
        'Không nhận diện được định dạng hoặc phiên bản sao lưu.',
      );
    }
    final values = root['entries'] as List;
    final configuration = root.containsKey('configuration')
        ? BackupConfiguration.fromJson(root['configuration'])
        : null;
    final extensions = root.containsKey('extensions')
        ? ExtensionBackup.fromJson(root['extensions'])
        : null;
    if (values.length > 10000) {
      throw const FormatException('Bản sao lưu có quá nhiều sách.');
    }
    final ids = <String>{};
    final result = <LibrarySnapshotEntry>[];
    for (final value in values) {
      final entry = _object(value, 'Mục sao lưu');
      final json = _object(entry['book'], 'Thông tin sách');
      _string(json, 'id', required: true);
      _string(json, 'title', required: true);
      if ((json['id'] as String).isEmpty ||
          (json['title'] as String).trim().isEmpty ||
          !ids.add(json['id'] as String)) {
        throw const FormatException(
          'ID hoặc tên sách trống, hoặc ID sách bị trùng.',
        );
      }
      for (final key in [
        'author',
        'artist',
        'notes',
        'series',
        'description',
        'kind',
        'engine',
        'sourceId',
        'sourceName',
        'sourceRef',
        'cover',
        'originalCover',
        'collection',
      ]) {
        _string(json, key);
      }
      final genres = json['genres'] ?? const [];
      final aliases = json['alternativeTitles'] ?? const [];
      if (aliases is! List ||
          aliases.length > 2 ||
          aliases.any((name) => name is! String || name.trim().isEmpty) ||
          aliases.toSet().length != aliases.length) {
        throw const FormatException(
          'Tên khác phải gồm tối đa hai tên không trống, không trùng.',
        );
      }
      if (json.containsKey('customCover') && json['customCover'] is! bool) {
        throw const FormatException('Trạng thái bìa riêng không hợp lệ.');
      }
      if (genres is! List || genres.any((genre) => genre is! String)) {
        throw const FormatException('Thể loại sách phải là danh sách chuỗi.');
      }
      final categories = json['categories'];
      if (categories != null &&
          (categories is! List ||
              categories.length > 10000 ||
              categories.any(
                (name) => name is! String || name.trim().isEmpty,
              ))) {
        throw const FormatException(
          'Danh mục sách phải là danh sách tên không trống.',
        );
      }
      for (final key in ['createdAt', 'lastUpdated']) {
        if (json[key] != null &&
            (json[key] is! String ||
                DateTime.tryParse(json[key] as String) == null)) {
          throw FormatException('$key phải là ngày hợp lệ.');
        }
      }
      if (json['readerPreferences'] != null &&
          (json['readerPreferences'] is! Map ||
              (json['readerPreferences'] as Map).keys.any(
                (key) => key is! String,
              ))) {
        throw const FormatException('Thiết lập đọc riêng phải là object JSON.');
      }
      if (json.containsKey('chapterListPreferences')) {
        ChapterListOptions.validateJson(json['chapterListPreferences']);
      }
      for (final key in ['favorite', 'completed']) {
        if (json.containsKey(key) && json[key] is! bool) {
          throw FormatException('$key phải là true hoặc false.');
        }
      }
      if (json['status'] != null &&
          (json['status'] is! int ||
              (json['status'] as int) < 0 ||
              (json['status'] as int) > 7)) {
        throw const FormatException('Trạng thái phát hành sách không hợp lệ.');
      }
      if (json['readingState'] != null &&
          ![
            '',
            'planned',
            'reading',
            'paused',
            'completed',
          ].contains(json['readingState'])) {
        throw const FormatException('Trạng thái đọc sách không hợp lệ.');
      }
      final rating = json['rating'];
      if (rating != null &&
          (rating is! num || !rating.isFinite || rating < 0 || rating > 10)) {
        throw const FormatException('Điểm đánh giá phải từ 0 đến 10.');
      }
      if (!['manga', 'novel'].contains(json['kind'] ?? 'novel') ||
          ![
            'local',
            'tachimanga',
            'vbook',
          ].contains(json['engine'] ?? 'local')) {
        throw const FormatException(
          'Loại nội dung hoặc nguồn sách không hợp lệ.',
        );
      }
      final progress = json['progress'] ?? 0;
      if (progress is! num ||
          !progress.isFinite ||
          progress < 0 ||
          progress > 1) {
        throw const FormatException('Tiến độ sách phải nằm trong khoảng 0–1.');
      }
      final current = json['currentChapter'] ?? 0;
      if (current is! int || current < 0) {
        throw const FormatException('Vị trí chương không hợp lệ.');
      }
      if (json['lastRead'] != null &&
          (json['lastRead'] is! String ||
              DateTime.tryParse(json['lastRead'] as String) == null)) {
        throw const FormatException('Ngày đọc gần nhất không hợp lệ.');
      }
      final chapters = json['chapters'];
      if (chapters is! List ||
          chapters.length > 10000 ||
          (chapters.isEmpty ? current != 0 : current >= chapters.length)) {
        throw const FormatException(
          'Danh sách chương hoặc vị trí đọc không hợp lệ.',
        );
      }
      final chapterIds = <String>{};
      for (var index = 0; index < chapters.length; index++) {
        final chapter = _object(chapters[index], 'Chương');
        _string(chapter, 'scanlator');
        if (chapter['uploadedAt'] != null &&
            (chapter['uploadedAt'] is! String ||
                DateTime.tryParse(chapter['uploadedAt'] as String) == null)) {
          throw const FormatException('Ngày phát hành chương không hợp lệ.');
        }
        if (chapter['discoveredAt'] != null &&
            (chapter['discoveredAt'] is! String ||
                DateTime.tryParse(chapter['discoveredAt'] as String) == null)) {
          throw const FormatException('Ngày phát hiện chương không hợp lệ.');
        }
        if (chapter['number'] != null &&
            (chapter['number'] is! num ||
                !(chapter['number'] as num).isFinite)) {
          throw const FormatException('Số chương phải hữu hạn.');
        }
        _string(chapter, 'id', required: true);
        _string(chapter, 'title', required: true);
        if ((chapter['id'] as String).isEmpty ||
            (chapter['title'] as String).trim().isEmpty ||
            !chapterIds.add(chapter['id'] as String) ||
            chapter['index'] is! int ||
            chapter['index'] != index ||
            (chapter.containsKey('downloaded') &&
                chapter['downloaded'] is! bool) ||
            (chapter.containsKey('read') &&
                chapter['read'] != null &&
                chapter['read'] is! bool)) {
          throw const FormatException(
            'Thứ tự hoặc trạng thái tải chương không hợp lệ.',
          );
        }
      }
      final bookmarks = json['bookmarks'] ?? [];
      if (bookmarks is! List ||
          bookmarks.any((bookmark) => bookmark is! String)) {
        throw const FormatException('Dấu trang không hợp lệ.');
      }
      for (final bookmark in bookmarks.cast<String>()) {
        final parts = bookmark.split(':');
        final index = parts.length == 2 ? int.tryParse(parts[0]) : null;
        final position = parts.length == 2 ? double.tryParse(parts[1]) : null;
        if (index == null ||
            index < 0 ||
            index >= chapters.length ||
            parts[0] != '$index' ||
            position == null ||
            !position.isFinite ||
            position < 0 ||
            position > 1) {
          throw const FormatException(
            'Dấu trang tham chiếu chương hoặc vị trí không hợp lệ.',
          );
        }
      }
      final book = LibraryBook.fromJson(json);
      _imageReference(book.cover, allowEmpty: true);
      _imageReference(book.originalCover, allowEmpty: true);
      // Native hydrated covers may be large; metadata uses a short attachment ref.
      repository.validateBook(book.copyWith(cover: '', originalCover: ''));
      final contentValues = _object(entry['contents'], 'Nội dung chương');
      final contents = <int, ReaderContent>{};
      for (final contentEntry in contentValues.entries) {
        if (!RegExp(r'^(0|[1-9]\d*)$').hasMatch(contentEntry.key)) {
          throw const FormatException('Chỉ số nội dung chương không hợp lệ.');
        }
        final index = int.tryParse(contentEntry.key);
        if (index == null || index >= chapters.length) {
          throw const FormatException(
            'Nội dung tham chiếu chương không có trong sách.',
          );
        }
        final contentJson = _object(contentEntry.value, 'Nội dung chương');
        _string(contentJson, 'kind', required: true);
        _string(contentJson, 'html');
        if (contentJson['kind'] != book.kind ||
            contentJson['images'] is! List ||
            (contentJson['images'] as List).any((image) => image is! String)) {
          throw const FormatException(
            'Loại hoặc danh sách ảnh của chương không hợp lệ.',
          );
        }
        final headers = _object(contentJson['headers'], 'Headers của chương');
        if (headers.values.any((header) => header is! String)) {
          throw const FormatException(
            'Headers của chương phải chứa các chuỗi.',
          );
        }
        final imageHeaders = _object(
          contentJson['imageHeaders'] ?? {},
          'Headers từng ảnh',
        );
        for (final value in imageHeaders.values) {
          if (_object(
            value,
            'Headers từng ảnh',
          ).values.any((value) => value is! String)) {
            throw const FormatException(
              'Headers từng ảnh phải chứa các chuỗi.',
            );
          }
        }
        final content = ReaderContent.fromJson(contentJson);
        repository.validateChapter(index, content);
        for (final image in content.images) {
          _imageReference(image);
        }
        if (content.html.contains('tachi-asset://')) {
          throw const FormatException('Sao lưu thiếu dữ liệu ảnh đính kèm.');
        }
        final embeddedImages = html_parser
            .parseFragment(content.html)
            .querySelectorAll('img[src]')
            .map((image) => image.attributes['src']!)
            .toList();
        for (final image in embeddedImages) {
          _imageReference(image);
        }
        final downloaded = book.chapters[index].downloaded;
        if (downloaded &&
            [
              ...content.images,
              ...embeddedImages,
            ].any((image) => !image.startsWith('data:image/'))) {
          throw const FormatException(
            'Chương đã tải vẫn chứa ảnh từ mạng; thiếu nội dung offline.',
          );
        }
        if (downloaded &&
            (content.kind == 'manga'
                ? content.images.isEmpty
                : content.html.trim().isEmpty)) {
          throw const FormatException('Nội dung chương đã tải bị trống.');
        }
        contents[index] = content;
      }
      for (final chapter in book.chapters) {
        if (chapter.downloaded && !contents.containsKey(chapter.index)) {
          throw const FormatException(
            'Sao lưu thiếu nội dung của một chương đã tải.',
          );
        }
      }
      result.add(LibrarySnapshotEntry(book, contents));
    }
    return LibrarySnapshot(
      result,
      configuration: configuration,
      extensions: extensions,
    );
  }

  Map<String, dynamic> _object(Object? value, String label) {
    if (value is! Map || value.keys.any((key) => key is! String)) {
      throw FormatException('$label phải là một object JSON.');
    }
    return Map<String, dynamic>.from(value);
  }

  void _string(
    Map<String, dynamic> object,
    String key, {
    bool required = false,
  }) {
    if ((required || object.containsKey(key)) && object[key] is! String) {
      throw FormatException('$key phải là một chuỗi.');
    }
  }

  void _imageReference(String reference, {bool allowEmpty = false}) {
    if (allowEmpty && reference.isEmpty) return;
    if (reference.startsWith('data:image/')) {
      if (reference.length > LibraryRepository.maxImageBytes * 4 ~/ 3 + 512) {
        throw const FormatException('Ảnh sao lưu vượt giới hạn 8 MB.');
      }
      final bytes = UriData.parse(reference).contentAsBytes();
      if (bytes.isEmpty) throw const FormatException('Ảnh sao lưu trống.');
      if (bytes.length > LibraryRepository.maxImageBytes) {
        throw const FormatException('Ảnh sao lưu vượt giới hạn 8 MB.');
      }
      return;
    }
    final uri = Uri.tryParse(reference);
    if (uri == null ||
        !['http', 'https'].contains(uri.scheme) ||
        uri.host.isEmpty) {
      throw const FormatException('Sao lưu chứa tham chiếu ảnh không hợp lệ.');
    }
  }
}
