import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tachi_books/features/library/data/backup_service.dart';
import 'package:tachi_books/features/library/data/library_repository.dart';

import 'support/backup_fixtures.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Tachimanga SQLite adapter imports library only, exact source IDs and nonsequential read state', () async {
    final repository = MemoryLibraryRepository();
    final service = BackupService(repository);
    final preview = await service.preview(tmbFixture());
    expect(preview.format, contains('build511'));
    expect(preview.books, 1);
    expect(preview.cachedChapters, 0);
    expect(preview.warnings.join(' '), contains('nhiều danh mục'));
    expect(await service.mergePreview(preview), 1);
    final book = (await repository.list()).single;
    expect(book.sourceId, fixtureSource);
    expect(book.sourceRef, '/title');
    expect(book.collection, 'Nhóm đầu');
    expect(book.chapters.map((chapter) => chapter.id), ['/c1', '/c2', '/c3']);
    expect(book.chapters.map((chapter) => chapter.read), [true, false, true]);
    expect(book.chapters.every((chapter) => !chapter.downloaded), isTrue);
    expect(book.currentChapter, 1);
    expect(book.progress, .5);
    expect(book.bookmarks, ['1:0.5']);
    expect(
      book.lastRead,
      DateTime.fromMillisecondsSinceEpoch(2000, isUtc: true),
    );
    expect(await repository.readChapter(book.id, 0), isNull);
  });

  test('Mihon gzip protobuf shares identities, preserves read/bookmarks, warns about absent page counts', () async {
    final repository = MemoryLibraryRepository();
    final service = BackupService(repository);
    final preview = await service.preview(mihonFixture());
    expect(preview.books, 1);
    expect(preview.warnings.join(' '), contains('thiếu số trang'));
    expect(preview.warnings.join(' '), contains('chỉ có trong lịch sử'));
    final book = preview.snapshot.entries.single.book;
    expect(book.sourceId, fixtureSource);
    expect(book.collection, 'Nhóm mẫu');
    expect(book.artist, 'Họa sĩ mẫu');
    expect(book.genres, ['Phiêu lưu', 'Đời thường']);
    expect(book.notes, 'Ghi chú riêng\nChương yêu thích: 2');
    expect(preview.warnings.join(' '), contains('memo riêng'));
    expect(book.currentChapter, 1);
    expect(book.progress, 1 / 3);
    expect(book.chapters.map((chapter) => chapter.read), [true, false, true]);
    expect(book.bookmarks, ['1:0.0']);
    await service.mergePreview(preview);
    final tmb = await service.preview(tmbFixture());
    expect(tmb.additions, 0);
    expect(await service.mergePreview(tmb), 0);
    expect((await repository.list()).length, 1);
    expect((await repository.list()).single.collection, 'Nhóm mẫu');
    final fresh = MemoryLibraryRepository();
    final freshService = BackupService(fresh);
    await freshService.replace(
      await service.export(),
      expectedFingerprint: (await fresh.snapshot()).fingerprint,
    );
    final restored = (await fresh.list()).single;
    expect(restored.notes, book.notes);
    expect(restored.artist, book.artist);
    expect(restored.genres, book.genres);
  });

  test('Valid empty Mihon library imports no books', () async {
    final repository = MemoryLibraryRepository();
    expect(await BackupService(repository).merge(mihonFixture(empty: true)), 0);
    expect(await repository.list(), isEmpty);
  });

  test('Unsupported versions/checksums/malformed gzip/unknown vBook reject before mutations', () async {
    for (final bytes in [
      tmbFixture(version: 512),
      tmbFixture(badChecksum: true),
      Uint8List.sublistView(mihonFixture(), 0, 20),
      Uint8List.fromList(utf8.encode('{"vBook":"unknown"}')),
    ]) {
      final repository = MemoryLibraryRepository();
      await expectLater(
        BackupService(repository).merge(bytes),
        throwsA(isA<FormatException>()),
      );
      expect(await repository.list(), isEmpty);
      expect(await repository.recoverySnapshot(), isNull);
    }
  });

  test('Forged ZIP small expansion and gzip CRC are rejected', () async {
    final oversized = backupZip({
      'meta.json': List<int>.filled(1024 * 1024, 0),
    });
    final view = ByteData.sublistView(oversized);
    for (var offset = 0; offset + 46 <= oversized.length; offset++) {
      if (view.getUint32(offset, Endian.little) == 0x02014b50) {
        view.setUint32(offset + 24, 1, Endian.little);
        break;
      }
    }
    final gzip = mihonFixture();
    gzip[gzip.length - 8] ^= 1;
    for (final bytes in [oversized, gzip]) {
      await expectLater(
        BackupService(MemoryLibraryRepository()).preview(bytes),
        throwsA(isA<FormatException>()),
      );
    }
  });

  final sample = Platform.environment['TACHI_TMB_SAMPLE'];
  test(
    'User-provided TMB is read-only convertible with no fabricated offline bytes',
    () async {
      final file = File(sample!);
      final bytes = await file.readAsBytes();
      final before = file.statSync();
      final preview = await BackupService(MemoryLibraryRepository())
          .preview(bytes);
      expect(preview.format, 'Tachimanga 5.0 (build511)');
      expect(preview.books, greaterThan(0));
      expect(preview.cachedChapters, 0);
      expect(
        preview.snapshot.entries.every(
          (entry) =>
              entry.book.chapters.every((chapter) => !chapter.downloaded),
        ),
        isTrue,
      );
      expect(await file.readAsBytes(), bytes);
      expect(file.statSync().modified, before.modified);
      // Deliberately print no titles, account values or other personal metadata.
    },
    skip: sample == null
        ? 'Opt-in: TACHI_TMB_SAMPLE points to a read-only private sample.'
        : false,
  );
}
