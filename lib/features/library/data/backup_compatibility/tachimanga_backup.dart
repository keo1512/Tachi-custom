import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:sqlite3/sqlite3.dart';

import 'bounded_archive.dart';
import 'external_library.dart';

/// Verified against a user-provided Tachimanga 5.0 / build511 .tmb.
/// Only the library tables are read. Preferences/JARs/account tables are ignored.
Future<ConvertedBackup> readTachimangaBackup(Uint8List bytes) =>
    Isolate.run(() => _read(bytes));

ConvertedBackup _read(Uint8List bytes) {
  final zip = BoundedBackupZip(bytes);
  final meta = jsonDecode(
    utf8.decode(zip.read('meta.json', limit: 1024 * 1024)),
  );
  if (meta is! Map ||
      meta['version'] != 511 ||
      meta['type'] != 0 ||
      meta['checksum'] is! String) {
    throw const FormatException(
      'Chỉ nhận diện được Tachimanga .tmb build511, type0. Phiên bản này chưa có adapter được kiểm chứng.',
    );
  }
  final contents = zip.read('contents.zip');
  if (sha1.convert(contents).toString() != meta['checksum']) {
    throw const FormatException(
      'Checksum contents.zip trong Tachimanga backup không đúng.',
    );
  }
  final inner = BoundedBackupZip(contents);
  final databaseBytes = inner.read('tachimanga.db');
  if (databaseBytes.length < 100 ||
      ascii.decode(databaseBytes.sublist(0, 16), allowInvalid: true) !=
          'SQLite format 3\u0000') {
    throw const FormatException('Tachimanga backup không có SQLite hợp lệ.');
  }
  final directory = Directory.systemTemp.createTempSync('tachibooks-backup-');
  Database? database;
  try {
    final path = '${directory.path}/import.db';
    File(path).writeAsBytesSync(databaseBytes, flush: true);
    database = sqlite3.open(path, mode: OpenMode.readOnly);
    database.execute('PRAGMA trusted_schema=OFF');
    database.execute('PRAGMA query_only=ON');
    return _readLibrary(database);
  } on SqliteException {
    throw const FormatException(
      'SQLite trong backup hỏng hoặc có schema Tachimanga chưa được hỗ trợ.',
    );
  } finally {
    database?.close();
    directory.deleteSync(recursive: true);
  }
}

const _requiredColumns = {
  'Manga': [
    'id',
    'url',
    'title',
    'author',
    'description',
    'thumbnail_url',
    'in_library',
    'source',
  ],
  'Chapter': [
    'id',
    'manga',
    'url',
    'name',
    'read',
    'bookmark',
    'last_page_read',
    'last_read_at',
    'source_order',
    'page_count',
  ],
  'Category': ['id', 'name', 'order', 'is_delete'],
  'CategoryManga': ['manga', 'category'],
  'History': ['manga_id', 'last_chapter_id', 'last_read_at', 'is_delete'],
};

ConvertedBackup _readLibrary(Database db) {
  for (final entry in _requiredColumns.entries) {
    final schema = db.select('SELECT type FROM sqlite_master WHERE name=?', [
      entry.key,
    ]);
    if (schema.length != 1 || schema.single['type'] != 'table') {
      throw const FormatException('Backup thiếu bảng Tachimanga bắt buộc.');
    }
    final columns = db
        .select('PRAGMA table_info("${entry.key}")')
        .map((row) => row['name'])
        .toSet();
    if (!columns.containsAll(entry.value)) {
      throw const FormatException('Schema bảng Tachimanga chưa được hỗ trợ.');
    }
  }
  final manga = db.select(
    'SELECT id,url,title,author,description,thumbnail_url,source '
    'FROM Manga WHERE in_library=1 ORDER BY id LIMIT 10001',
  );
  if (manga.length > 10000) {
    throw const FormatException('Backup có quá nhiều truyện trong thư viện.');
  }
  final chapters = db.select(
    'SELECT c.id,c.manga,c.url,c.name,c.read,c.bookmark,c.last_page_read,'
    'c.last_read_at,c.source_order,c.page_count FROM Chapter c JOIN Manga m ON c.manga=m.id '
    'WHERE m.in_library=1 ORDER BY c.id LIMIT 100001',
  );
  if (chapters.length > 100000) {
    throw const FormatException('Backup có quá nhiều chương.');
  }
  final categories = db.select(
    'SELECT id,name,"order" FROM Category WHERE is_delete=0 '
    'ORDER BY "order",id LIMIT 10001',
  );
  if (categories.length > 10000) {
    throw const FormatException('Backup có quá nhiều danh mục.');
  }
  final categoryMap = {
    for (final category in categories) _integer(category['id']): category,
  };
  final memberships = db.select(
    'SELECT cm.manga,cm.category FROM CategoryManga cm '
    'JOIN Manga m ON cm.manga=m.id WHERE m.in_library=1 LIMIT 100001',
  );
  if (memberships.length > 100000) {
    throw const FormatException('Backup có quá nhiều liên kết danh mục.');
  }
  final history = db.select(
    'SELECT h.manga_id,h.last_chapter_id,h.last_read_at FROM History h '
    'JOIN Manga m ON h.manga_id=m.id WHERE m.in_library=1 AND h.is_delete=0 '
    'ORDER BY h.last_read_at DESC LIMIT 100001',
  );
  if (history.length > 100000) {
    throw const FormatException('Backup có quá nhiều mục lịch sử.');
  }
  final latest = <int, Row>{};
  for (final row in history) {
    latest.putIfAbsent(_integer(row['manga_id']), () => row);
  }
  final titles = <ExternalTitle>[];
  for (final row in manga) {
    final id = _integer(row['id']);
    final bookChapters = chapters
        .where((chapter) => chapter['manga'] == id)
        .toList();
    final categoryIds = memberships
        .where((membership) => membership['manga'] == id)
        .map((membership) => _integer(membership['category']))
        .toSet();
    final selected = categories
        .where(
          (category) =>
              categoryIds.contains(category['id']) &&
              categoryMap.containsKey(category['id']),
        )
        .toList();
    final last = latest[id];
    final current = bookChapters
        .where((chapter) => chapter['id'] == last?['last_chapter_id'])
        .firstOrNull;
    titles.add(
      ExternalTitle(
        source: _integer(row['source']).toString(),
        url: _string(row['url']),
        title: _string(row['title']),
        author: _string(row['author'], optional: true),
        description: _string(row['description'], optional: true),
        cover: _string(row['thumbnail_url'], optional: true),
        categories: selected
            .map((category) => _string(category['name']))
            .toList(),
        lastRead: last == null ? 0 : _integer(last['last_read_at']),
        lastChapter: current == null ? '' : _string(current['url']),
        chapters: bookChapters
            .map(
              (chapter) => ExternalChapter(
                url: _string(chapter['url']),
                title: _string(chapter['name']),
                order: _integer(chapter['source_order']),
                read: _boolean(chapter['read']),
                bookmarked: _boolean(chapter['bookmark']),
                lastPage: _integer(chapter['last_page_read']),
                // Tachimanga uses -1 for an unknown page count.
                pageCount: _pageCount(chapter['page_count']),
                lastRead: _integer(chapter['last_read_at']),
              ),
            )
            .toList(),
      ),
    );
  }
  return convertExternalLibrary('Tachimanga 5.0 (build511)', titles);
}

int _pageCount(Object? value) {
  final count = _integer(value);
  return count == -1 ? 0 : count;
}

int _integer(Object? value) {
  if (value is! int) {
    throw const FormatException('Backup Tachimanga có số nguyên không hợp lệ.');
  }
  return value;
}

String _string(Object? value, {bool optional = false}) {
  if (value == null && optional) return '';
  if (value is! String) {
    throw const FormatException('Backup Tachimanga có chuỗi không hợp lệ.');
  }
  return value;
}

bool _boolean(Object? value) {
  if (value != 0 && value != 1) {
    throw const FormatException('Trạng thái chương trong backup không hợp lệ.');
  }
  return value == 1;
}
