import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tachi_books/features/library/data/backup_compatibility/mihon_backup.dart';
import 'package:tachi_books/features/library/data/backup_compatibility/mihon_backup_exporter.dart';
import 'package:tachi_books/features/library/data/backup_compatibility/protobuf_reader.dart';
import 'package:tachi_books/features/library/data/backup_compatibility/protobuf_writer.dart';
import 'package:tachi_books/features/library/data/library_snapshot.dart';
import 'package:tachi_books/features/library/domain/library_book.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('official Mihon fields roundtrip signed64 identities, metadata, chapters, categories and latest history', () async {
    final sourceIds = ['9223372036854775807', '-9223372036854775808', '-1'];
    final snapshot = LibrarySnapshot([
      for (final (index, source) in sourceIds.indexed)
        LibrarySnapshotEntry(
          _book().copyWith(id: 'book-$index', sourceId: source),
          {
            1: ReaderContent(
              kind: 'manga',
              images: List.filled(10, 'data:image/png;base64,OFFLINE_BYTES'),
            ),
          },
        ),
    ]);
    final before = snapshot.encode();
    final exported = await exportMihonBackup(
      snapshot,
      sourceNames: {for (final source in sourceIds) source: 'Nguồn thử'},
    );
    expect(exported.books, 3);
    expect(exported.chapters, 9);
    expect(exported.categories, 2);
    expect(exported.skippedBooks, 0);
    expect(snapshot.encode(), before);
    final raw = Uint8List.fromList(GZipDecoder().decodeBytes(exported.bytes));
    expect(
      utf8.decode(raw, allowMalformed: true),
      isNot(contains('OFFLINE_BYTES')),
    );
    final root = ProtoMessage(raw);
    expect(
      root.messages(101).map((m) => m.integer(2).toString()).toSet(),
      sourceIds.toSet(),
    );
    expect(
      root.messages(101).map((m) => m.string(1)),
      everyElement('Nguồn thử'),
    );
    final manga = root.messages(1).first;
    expect(
      manga.boolean(100),
      true,
    ); // Membership, even without a TachiBooks star.
    expect(manga.messages(16).map((c) => c.integer(10).toInt()), [2, 1, 0]);
    expect(manga.messages(16).map((c) => c.integer(6).toInt()), [0, 5, 0]);
    expect(manga.messages(16).first.integer(7).toInt(), 1700000005000);
    expect(manga.messages(16).first.floatingPoint(9), 1.5);
    expect(manga.messages(104).single.integer(2).toInt(), 1700000010000);
    expect(manga.messages(104).single.string(1), '/chapter/2');
    expect(manga.messages(104).single.integer(3), BigInt.zero);
    final imported = await readMihonBackup(exported.bytes);
    expect(
      imported.snapshot.entries.map((e) => e.book.sourceId).toSet(),
      sourceIds.toSet(),
    );
    for (final entry in imported.snapshot.entries) {
      final book = entry.book;
      expect(book.title, 'Truyện kiểm thử');
      expect(book.sourceRef, '/title');
      expect(book.author, 'Tác giả');
      expect(book.artist, 'Họa sĩ');
      expect(book.notes, 'Ghi chú riêng\nDòng thứ hai');
      expect(book.genres, ['Phiêu lưu', 'Đời thường']);
      expect(book.categories, ['Manga', 'Tác giả']);
      expect(book.createdAt, _book().createdAt);
      expect(book.cover, 'https://example.test/cover.png');
      expect(book.chapters.map((c) => c.id), [
        '/chapter/1',
        '/chapter/2',
        '/chapter/3',
      ]);
      expect(book.chapters.map((c) => c.read), [true, false, true]);
      expect(book.chapters.every((c) => !c.downloaded), true);
      expect(book.chapters.first.scanlator, 'Nhóm dịch');
      expect(book.chapters.first.uploadedAt, _book().chapters.first.uploadedAt);
      expect(
        book.chapters.first.discoveredAt,
        _book().chapters.first.discoveredAt,
      );
      expect(book.chapters[1].discoveredAt, isNull);
      expect(book.chapters[1].uploadedAt, isNull);
      expect(book.currentChapter, 1);
      expect(
        book.progress,
        1 / 3,
      ); // External schema does not carry page count.
      expect(book.bookmarks, ['1:0.0']);
      expect(book.lastRead, _book().lastRead);
      expect(entry.contents, isEmpty);
    }
    expect(imported.warnings.join(' '), contains('thiếu số trang'));
    expect(exported.warnings.join(' '), contains('chỉ giữ đánh dấu chương'));
    expect(exported.warnings.join(' '), contains('EPUB/TXT/CBZ'));
  });

  test('partial unknown page positions, local covers and inexact numbers are warned rather than fabricated', () async {
    final b = _book().copyWith(
      cover: 'attachment://private/cover',
      chapters: [
        _book().chapters[0].copyWith(number: 1.1),
        _book().chapters[1].copyWith(number: 1e100),
        _book().chapters[2],
      ],
    );
    final exported = await exportMihonBackup(
      LibrarySnapshot([LibrarySnapshotEntry(b, {})]),
    );
    final warning = exported.warnings.join(' ');
    expect(warning, contains('thiếu số trang đã tải'));
    expect(warning, contains('ảnh bìa lưu trên máy'));
    expect(warning, contains('làm tròn'));
    expect(warning, contains('chưa có số chương hợp lệ'));
    final root = ProtoMessage(
      Uint8List.fromList(GZipDecoder().decodeBytes(exported.bytes)),
    );
    final manga = root.messages(1).single;
    expect(manga.string(9), '');
    expect(manga.messages(16)[1].integer(6), BigInt.zero);
    expect(manga.messages(16)[1].one(9), isNull);
    expect(
      (await readMihonBackup(exported.bytes)).snapshot.entries,
      hasLength(1),
    );
  });

  test('local, vBook, unverified numeric references and noncanonical source IDs are explicitly skipped', () async {
    final variants = [
      _book().copyWith(id: 'local', engine: 'local'),
      _book().copyWith(id: 'zero', sourceId: '0'),
      _book().copyWith(id: 'vbook', engine: 'vbook'),
      _book().copyWith(id: 'numeric', sourceRef: '123'),
      _book().copyWith(
        id: 'chapter',
        chapters: [_book().chapters[0].copyWith(id: '44')],
      ),
      _book().copyWith(id: 'large', sourceId: '9223372036854775808'),
      _book().copyWith(id: 'leading-zero', sourceId: '0123'),
    ];
    final exported = await exportMihonBackup(
      LibrarySnapshot([
        LibrarySnapshotEntry(_book(), {}),
        for (final b in variants) LibrarySnapshotEntry(b, {}),
      ]),
    );
    expect(exported.skippedBooks, variants.length);
    expect(exported.books, 1);
    expect(exported.warnings.join(' '), contains('vBook được bỏ qua'));
    expect(exported.warnings.join(' '), contains('chưa có URL'));
    final empty = await exportMihonBackup(
      LibrarySnapshot([LibrarySnapshotEntry(variants.first, {})]),
    );
    expect(empty.books, 0);
    expect((await readMihonBackup(empty.bytes)).snapshot.entries, isEmpty);
  });

  test(
    'invalid library state and resource limits reject before returning a file',
    () async {
      final source = _book();
      for (final bad in [
        source.copyWith(progress: double.nan),
        source.copyWith(progress: 1.01),
        source.copyWith(currentChapter: -1),
        source.copyWith(currentChapter: 3),
        source.copyWith(chapters: [], currentChapter: 1),
        source.copyWith(bookmarks: ['1:NaN']),
        source.copyWith(bookmarks: ['3:0']),
        source.copyWith(bookmarks: List.filled(10001, '1:0')),
        source.copyWith(chapters: [source.chapters.first.copyWith(index: 1)]),
        source.copyWith(
          chapters: [source.chapters.first.copyWith(number: double.infinity)],
        ),
        source.copyWith(
          chapters: [
            source.chapters.first,
            source.chapters.first.copyWith(index: 1),
          ],
        ),
        source.copyWith(notes: 'a' * (2 * 1024 * 1024 + 1)),
        source.copyWith(genres: List.filled(10001, 'genre')),
      ]) {
        await expectLater(
          exportMihonBackup(LibrarySnapshot([LibrarySnapshotEntry(bad, {})])),
          throwsFormatException,
        );
      }
      await expectLater(
        exportMihonBackup(
          LibrarySnapshot([
            LibrarySnapshotEntry(source, {}),
            LibrarySnapshotEntry(source.copyWith(id: 'duplicate'), {}),
          ]),
        ),
        throwsFormatException,
      );
      await expectLater(
        exportMihonBackup(
          LibrarySnapshot(List.filled(10001, LibrarySnapshotEntry(source, {}))),
        ),
        throwsFormatException,
      );
    },
  );

  test('writer uses signed64 two-complement wire bytes, packed integers and a shared nested field budget', () {
    final writer = ProtoWriter()
      ..integer(1, -(BigInt.one << 63))
      ..integer(2, (BigInt.one << 63) - BigInt.one)
      ..packedIntegers(3, [BigInt.from(-1), BigInt.zero, BigInt.one]);
    // Independent known bytes for min signed64: tag + nine continuation 0s + 1.
    expect(writer.finish().take(11), [
      8,
      128,
      128,
      128,
      128,
      128,
      128,
      128,
      128,
      128,
      1,
    ]);
    final message = ProtoMessage(writer.finish());
    expect(message.integer(1), -(BigInt.one << 63));
    expect(message.integer(2), (BigInt.one << 63) - BigInt.one);
    expect(message.integers(3), [BigInt.from(-1), BigInt.zero, BigInt.one]);
    for (final v in [-(BigInt.one << 63) - BigInt.one, BigInt.one << 63]) {
      expect(() => ProtoWriter().integer(1, v), throwsFormatException);
    }
    expect(() => ProtoWriter().int64(0, 0), throwsFormatException);
    expect(() => ProtoWriter().int64(0x20000000, 0), throwsFormatException);
    expect(() => ProtoWriter().float32(1, double.nan), throwsFormatException);
    expect(
      () => ProtoWriter().packedIntegers(1, List.filled(10001, BigInt.one)),
      throwsFormatException,
    );
    final budget = ProtoWriteBudget()..fields = 1999999;
    final child = ProtoWriter(budget)..string(1, 'last valid field');
    expect(
      () => ProtoWriter(budget).message(1, child.finish()),
      throwsFormatException,
    );
  });
}

LibraryBook _book() => LibraryBook(
  id: 'manga',
  title: 'Truyện kiểm thử',
  kind: 'manga',
  engine: 'tachimanga',
  sourceId: '9223372036854775001',
  sourceRef: '/title',
  author: 'Tác giả',
  artist: 'Họa sĩ',
  description: 'Mô tả',
  notes: 'Ghi chú riêng\nDòng thứ hai',
  genres: ['Phiêu lưu', 'Đời thường'],
  categories: ['Manga', 'Tác giả'],
  cover: 'https://example.test/cover.png',
  currentChapter: 1,
  progress: .5,
  lastRead: DateTime.fromMillisecondsSinceEpoch(1700000010000, isUtc: true),
  createdAt: DateTime.fromMillisecondsSinceEpoch(1600000000000, isUtc: true),
  bookmarks: ['1:0.5', '1:0.8'],
  chapters: [
    BookChapter(
      id: '/chapter/1',
      title: 'Chương 1',
      index: 0,
      read: true,
      downloaded: true,
      number: 1.5,
      scanlator: 'Nhóm dịch',
      uploadedAt: DateTime.fromMillisecondsSinceEpoch(
        1700000000000,
        isUtc: true,
      ),
      discoveredAt: DateTime.fromMillisecondsSinceEpoch(
        1700000005000,
        isUtc: true,
      ),
    ),
    const BookChapter(
      id: '/chapter/2',
      title: 'Chương 2',
      index: 1,
      read: false,
      number: 2,
    ),
    const BookChapter(
      id: '/chapter/3',
      title: 'Chương 3',
      index: 2,
      read: true,
      number: 3,
    ),
  ],
);
