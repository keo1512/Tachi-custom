import 'dart:convert';
import 'dart:typed_data';

import '../domain/library_book.dart';
import 'library_repository.dart';

class BackupService {
  BackupService(this.repository);
  final LibraryRepository repository;
  static const maxBackupBytes = 128 * 1024 * 1024;

  Future<Uint8List> export() async {
    final entries = <Map<String, dynamic>>[];
    for (final book in await repository.list()) {
      final contents = <String, dynamic>{};
      for (var index = 0; index < book.chapters.length; index++) {
        final content = await repository.readChapter(book.id, index);
        if (content != null) contents['$index'] = content.toJson();
      }
      entries.add({'book': book.toJson(), 'contents': contents});
    }
    final bytes = Uint8List.fromList(
      utf8.encode(
        jsonEncode({
          'schema': 'tachi-books-backup',
          'version': 1,
          'entries': entries,
        }),
      ),
    );
    if (bytes.length > maxBackupBytes) {
      throw const FormatException('Bản sao lưu vượt giới hạn 128 MB.');
    }
    // Never emit a backup that this version cannot validate and restore.
    _validate(bytes);
    return bytes;
  }

  Future<int> merge(Uint8List bytes) async {
    // Validate every book/content before the first persistence mutation.
    final entries = _validate(bytes);
    final additions = <_BackupEntry>[];
    for (final entry in entries) {
      if (await repository.find(entry.book.id) == null) additions.add(entry);
    }
    final created = <String>[];
    String? pending;
    try {
      for (final entry in additions) {
        pending = entry.book.id;
        for (final content in entry.contents.entries) {
          await repository.saveChapter(
            entry.book.id,
            content.key,
            content.value,
          );
        }
        await repository.save(entry.book);
        created.add(entry.book.id);
        pending = null;
      }
    } catch (_) {
      if (pending != null) await repository.remove(pending);
      for (final id in created.reversed) {
        await repository.remove(id);
      }
      rethrow;
    }
    return created.length;
  }

  List<_BackupEntry> _validate(Uint8List bytes) {
    if (bytes.isEmpty || bytes.length > maxBackupBytes) {
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
    if (values.length > 10000) {
      throw const FormatException('Bản sao lưu có quá nhiều sách.');
    }
    final ids = <String>{};
    final result = <_BackupEntry>[];
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
        'description',
        'kind',
        'engine',
        'sourceId',
        'sourceRef',
        'cover',
        'collection',
      ]) {
        _string(json, key);
      }
      for (final key in ['favorite', 'completed']) {
        if (json.containsKey(key) && json[key] is! bool) {
          throw FormatException('$key phải là true hoặc false.');
        }
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
        _string(chapter, 'id', required: true);
        _string(chapter, 'title', required: true);
        if ((chapter['id'] as String).isEmpty ||
            (chapter['title'] as String).trim().isEmpty ||
            !chapterIds.add(chapter['id'] as String) ||
            chapter['index'] is! int ||
            chapter['index'] != index ||
            (chapter.containsKey('downloaded') &&
                chapter['downloaded'] is! bool)) {
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
      final book = LibraryBook.fromJson(json);
      _imageReference(book.cover, allowEmpty: true);
      // Native hydrated covers may be large; metadata uses a short attachment ref.
      repository.validateBook(book.copyWith(cover: ''));
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
        final content = ReaderContent.fromJson(contentJson);
        repository.validateChapter(index, content);
        for (final image in content.images) {
          _imageReference(image);
        }
        if (content.html.contains('tachi-asset://')) {
          throw const FormatException('Sao lưu thiếu dữ liệu ảnh đính kèm.');
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
      result.add(_BackupEntry(book, contents));
    }
    return result;
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

class _BackupEntry {
  const _BackupEntry(this.book, this.contents);
  final LibraryBook book;
  final Map<int, ReaderContent> contents;
}
