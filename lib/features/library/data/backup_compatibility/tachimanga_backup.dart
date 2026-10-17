import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:sqlite3/sqlite3.dart';

import 'bounded_archive.dart';
import 'external_library.dart';
import 'protobuf_writer.dart';
import '../../domain/external_backup_metadata.dart';

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
  final mangaColumns = db
      .select('PRAGMA table_info("Manga")')
      .map((row) => row['name'])
      .toSet();
  final optionalStatus = [
    for (final column in ['status', 'memo', 'artist', 'genre'])
      if (mangaColumns.contains(column)) ',$column',
  ].join();
  final manga = db.select(
    'SELECT id,url,title,author,description,thumbnail_url,source$optionalStatus '
    'FROM Manga WHERE in_library=1 ORDER BY id LIMIT 10001',
  );
  if (manga.length > 10000) {
    throw const FormatException('Backup có quá nhiều truyện trong thư viện.');
  }
  final chapterColumns = db
      .select('PRAGMA table_info("Chapter")')
      .map((row) => row['name'])
      .toSet();
  final optionalChapterColumns = [
    for (final column in ['date_upload', 'chapter_number', 'scanlator'])
      if (chapterColumns.contains(column)) ',c.$column',
  ].join();
  final chapters = db.select(
    'SELECT c.id,c.manga,c.url,c.name,c.read,c.bookmark,c.last_page_read,'
    'c.last_read_at,c.source_order,c.page_count$optionalChapterColumns FROM Chapter c JOIN Manga m ON c.manga=m.id '
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
  final tracking = _tracking(db);
  // Older backups may omit this optional table. Never substitute the author
  // or extension package name for the source's own display name.
  final sourceNames = <String, String>{};
  if (db
      .select(
        "SELECT name FROM sqlite_master WHERE type='table' AND name='Source'",
      )
      .isNotEmpty) {
    final columns = db
        .select('PRAGMA table_info("Source")')
        .map((r) => r['name'])
        .toSet();
    if (columns.containsAll(['id', 'name'])) {
      for (final source in db.select(
        'SELECT id,name FROM Source LIMIT 10001',
      )) {
        sourceNames[_integer(source['id']).toString()] = _string(
          source['name'],
          optional: true,
        );
      }
    }
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
        sourceName: sourceNames[_integer(row['source']).toString()] ?? '',
        status: mangaColumns.contains('status') ? _integer(row['status']) : 0,
        url: _string(row['url']),
        title: _string(row['title']),
        author: _string(row['author'], optional: true),
        artist: mangaColumns.contains('artist')
            ? _string(row['artist'], optional: true)
            : '',
        genres: mangaColumns.contains('genre')
            ? _genres(row['genre'])
            : const [],
        externalBackupMetadata:
            !mangaColumns.contains('memo') && (tracking[id]?.isEmpty ?? true)
            ? null
            : ExternalBackupMetadata(
                format: 'tachimanga-build511',
                engine: 'tachimanga',
                sourceId: _integer(row['source']).toString(),
                sourceRef: _string(row['url']),
                tracking: [
                  for (final value in tracking[id] ?? const []) value.$1,
                ],
                trackingArchive: [
                  for (final value in tracking[id] ?? const []) value.$2,
                ],
                memo: mangaColumns.contains('memo')
                    ? base64Encode(utf8.encode(_string(row['memo'])))
                    : null,
              ),
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
                uploadedAt: chapterColumns.contains('date_upload')
                    ? _integer(chapter['date_upload'])
                    : 0,
                scanlator: chapterColumns.contains('scanlator')
                    ? _string(chapter['scanlator'], optional: true)
                    : '',
                number: chapterColumns.contains('chapter_number')
                    ? _number(chapter['chapter_number'])
                    : null,
              ),
            )
            .toList(),
      ),
    );
  }
  return convertExternalLibrary(
    'Tachimanga 5.0 (build511)',
    titles,
    sourceOrderNewestFirst: false,
  );
}

/// The optional TrackRecord columns were verified in the provided build511
/// database. Only active library rows are read, without account/session tables.
Map<int, List<(String, String)>> _tracking(Database db) {
  final schema = db.select(
    "SELECT type FROM sqlite_master WHERE name='TrackRecord'",
  );
  if (schema.isEmpty) return {};
  final columns = db
      .select('PRAGMA table_info("TrackRecord")')
      .map((row) => row['name'])
      .toSet();
  const required = [
    'manga_id',
    'sync_id',
    'remote_id',
    'library_id',
    'title',
    'last_chapter_read',
    'total_chapters',
    'status',
    'score',
    'remote_url',
    'start_date',
    'finish_date',
    'is_delete',
  ];
  if (schema.length != 1 ||
      schema.single['type'] != 'table' ||
      !columns.containsAll(required)) {
    throw const FormatException(
      'Schema tracker Tachimanga chưa được xác minh.',
    );
  }
  final rows = db.select(
    'SELECT t.* FROM TrackRecord t JOIN Manga m ON m.id=t.manga_id '
    'WHERE m.in_library=1 AND t.is_delete=0 ORDER BY t.manga_id,t.sync_id '
    'LIMIT 100001',
  );
  if (rows.length > 100000) {
    throw const FormatException('Sao lưu có quá nhiều liên kết tracker.');
  }
  final result = <int, List<(String, String)>>{};
  final identities = <String>{};
  for (final row in rows) {
    final mangaId = _integer(row['manga_id']);
    final sync = _integer(row['sync_id']);
    final total = _integer(row['total_chapters']);
    final status = _integer(row['status']);
    if (!identities.add('$mangaId:$sync') ||
        [sync, total, status].any((n) => n < -0x80000000 || n > 0x7fffffff)) {
      throw const FormatException(
        'Liên kết tracker trùng hoặc số vượt giới hạn.',
      );
    }
    final writer = ProtoWriter()
      ..int64(1, sync)
      ..int64(2, row['library_id'] == null ? 0 : _integer(row['library_id']))
      ..string(4, _string(row['remote_url']))
      ..string(5, _string(row['title']))
      ..float32(6, _requiredNumber(row['last_chapter_read']))
      ..int64(7, total)
      ..float32(8, _requiredNumber(row['score']))
      ..int64(9, status)
      ..int64(10, _integer(row['start_date']))
      ..int64(11, _integer(row['finish_date']))
      ..int64(100, _integer(row['remote_id']));
    final values = result.putIfAbsent(mangaId, () => []);
    if (values.length >= ExternalBackupMetadata.maxTrackers) {
      throw const FormatException(
        'Sao lưu có quá nhiều tracker cho một truyện.',
      );
    }
    final archive = jsonEncode({
      for (final key in required)
        if (key != 'manga_id' && key != 'is_delete')
          key: row[key] is int ? (row[key] as int).toString() : row[key],
    });
    values.add((
      base64Encode(writer.finish()),
      base64Encode(utf8.encode(archive)),
    ));
  }
  return result;
}

List<String> _genres(Object? value) {
  final text = _string(value, optional: true);
  // Verified Suwayomi build511 stores this column as comma-separated text.
  return text
      .split(',')
      .map((value) => value.trim())
      .where((value) => value.isNotEmpty)
      .toList();
}

double _requiredNumber(Object? value) {
  final result = _number(value);
  if (result == null) {
    throw const FormatException('Tracker thiếu số thực bắt buộc.');
  }
  return result;
}

double? _number(Object? value) {
  if (value == null) return null;
  if (value is! num || !value.isFinite) {
    throw const FormatException('Số chương trong backup không hợp lệ.');
  }
  return value.toDouble();
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
