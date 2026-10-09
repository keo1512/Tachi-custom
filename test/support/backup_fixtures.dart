import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:sqlite3/sqlite3.dart';

const fixtureSource = '9223372036854775001';

Uint8List backupZip(Map<String, List<int>> entries) {
  final archive = Archive();
  for (final entry in entries.entries) {
    archive.add(ArchiveFile.bytes(entry.key, entry.value));
  }
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

/// Synthetic, redacted schema fixture. Never includes a user's backup bytes.
Uint8List tmbFixture({int version = 511, bool badChecksum = false}) {
  final directory = Directory.systemTemp.createTempSync('tachi-tmb-fixture-');
  Database? db;
  try {
    final path = '${directory.path}/tachimanga.db';
    db = sqlite3.open(path);
    db.execute(
      'CREATE TABLE Manga (id INTEGER PRIMARY KEY, url TEXT, title TEXT, '
      'author TEXT, description TEXT, thumbnail_url TEXT, source BIGINT, in_library INTEGER)',
    );
    db.execute(
      'CREATE TABLE Chapter (id INTEGER PRIMARY KEY, manga INTEGER, url TEXT, '
      'name TEXT, read INTEGER, bookmark INTEGER, last_page_read INTEGER, '
      'last_read_at INTEGER, source_order INTEGER, page_count INTEGER)',
    );
    db.execute(
      'CREATE TABLE Category (id INTEGER PRIMARY KEY, name TEXT, "order" INTEGER, is_delete INTEGER)',
    );
    db.execute('CREATE TABLE CategoryManga (manga INTEGER, category INTEGER)');
    db.execute(
      'CREATE TABLE History (manga_id INTEGER, last_chapter_id INTEGER, last_read_at INTEGER, is_delete INTEGER)',
    );
    db.execute('INSERT INTO Manga VALUES (1, ?, ?, ?, ?, ?, ?, 1)', [
      '/title',
      'Truyện mẫu',
      'Tác giả',
      'Mô tả',
      '',
      int.parse(fixtureSource),
    ]);
    db.execute('INSERT INTO Manga VALUES (2, ?, ?, ?, ?, ?, 123, 0)', [
      '/cached',
      'Kết quả tìm kiếm',
      '',
      '',
      '',
    ]);
    db.execute('INSERT INTO Chapter VALUES (10,1,?,?,1,0,4,1000,2,5)', [
      '/c1',
      'Chương 1',
    ]);
    db.execute('INSERT INTO Chapter VALUES (11,1,?,?,0,1,2,2000,1,5)', [
      '/c2',
      'Chương 2',
    ]);
    db.execute('INSERT INTO Chapter VALUES (12,1,?,?,1,0,4,0,0,5)', [
      '/c3',
      'Chương 3',
    ]);
    db.execute('INSERT INTO Chapter VALUES (20,2,?,?,0,0,0,0,0,0)', [
      '/cached/1',
      'Chương ngoài thư viện',
    ]);
    db.execute('INSERT INTO Category VALUES (1,?,2,0),(2,?,1,0),(3,?,0,1)', [
      'Nhóm sau',
      'Nhóm đầu',
      'Đã xóa',
    ]);
    db.execute('INSERT INTO CategoryManga VALUES (1,1),(1,2),(1,3)');
    db.execute(
      'INSERT INTO History VALUES (1,10,1000,0),(1,11,2000,0),(1,12,3000,1)',
    );
    db.close();
    db = null;
    final contents = backupZip({
      'tachimanga.db': File(path).readAsBytesSync(),
      'prefs.json': utf8.encode('{"account":"ignored"}'),
      'extensions/ignored.jar': [1, 2, 3],
    });
    return backupZip({
      'meta.json': utf8.encode(
        jsonEncode({
          'version': version,
          'type': 0,
          'checksum': badChecksum ? 'wrong' : sha1.convert(contents).toString(),
        }),
      ),
      'contents.zip': contents,
    });
  } finally {
    db?.close();
    directory.deleteSync(recursive: true);
  }
}

List<int> varint(BigInt value) {
  var remaining = value.toUnsigned(64);
  final bytes = <int>[];
  do {
    final byte = (remaining & BigInt.from(127)).toInt();
    remaining >>= 7;
    bytes.add(byte | (remaining == BigInt.zero ? 0 : 128));
  } while (remaining != BigInt.zero);
  return bytes;
}

List<int> integerField(int field, int value) => [
  ...varint(BigInt.from(field << 3)),
  ...varint(BigInt.from(value)),
];
List<int> messageField(int field, List<int> value) => [
  ...varint(BigInt.from((field << 3) | 2)),
  ...varint(BigInt.from(value.length)),
  ...value,
];
List<int> stringField(int field, String value) =>
    messageField(field, utf8.encode(value));

Uint8List mihonFixture({bool empty = false}) {
  List<int> chapter(
    String url,
    int order,
    int read, {
    int bookmark = 0,
    int page = 0,
  }) => [
    ...stringField(1, url),
    ...stringField(2, 'Chương $url'),
    ...integerField(4, read),
    ...integerField(5, bookmark),
    ...integerField(6, page),
    ...integerField(10, order),
  ];
  final category = [
    ...stringField(1, 'Nhóm mẫu'),
    ...integerField(2, 0),
    ...integerField(3, 42),
  ];
  final manga = [
    ...integerField(1, int.parse(fixtureSource)),
    ...stringField(2, '/title'),
    ...stringField(3, 'Truyện mẫu'),
    ...stringField(4, 'Họa sĩ mẫu'),
    ...stringField(5, 'Tác giả'),
    ...stringField(7, 'Phiêu lưu'),
    ...stringField(7, 'Đời thường'),
    ...stringField(110, 'Ghi chú riêng\nChương yêu thích: 2'),
    ...messageField(112, utf8.encode('{"source":"opaque"}')),
    ...messageField(16, chapter('/c1', 2, 1)),
    ...messageField(16, chapter('/c2', 1, 0, bookmark: 1, page: 2)),
    ...messageField(16, chapter('/c3', 0, 1)),
    ...messageField(17, varint(BigInt.from(42))),
    ...messageField(104, [...stringField(1, '/c2'), ...integerField(2, 2000)]),
  ];
  final historyOnly = [
    ...integerField(1, 123),
    ...stringField(2, '/history'),
    ...stringField(3, 'Chỉ lịch sử'),
    ...integerField(100, 0),
  ];
  final root = [
    if (!empty) ...messageField(1, manga),
    if (!empty) ...messageField(1, historyOnly),
    ...messageField(2, category),
  ];
  return Uint8List.fromList(GZipEncoder().encode(root));
}
