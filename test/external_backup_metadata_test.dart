import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tachi_books/features/library/data/backup_compatibility/mihon_backup.dart';
import 'package:tachi_books/features/library/data/backup_compatibility/mihon_backup_exporter.dart';
import 'package:tachi_books/features/library/data/backup_compatibility/protobuf_reader.dart';
import 'package:tachi_books/features/library/data/backup_compatibility/protobuf_writer.dart';
import 'package:tachi_books/features/library/data/backup_service.dart';
import 'package:tachi_books/features/library/data/library_repository.dart';
import 'package:tachi_books/features/library/data/library_snapshot.dart';
import 'package:tachi_books/features/library/domain/external_backup_metadata.dart';
import 'package:tachi_books/features/library/domain/library_book.dart';

import 'support/backup_fixtures.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Mihon tracker unknown fields and memo bytes survive full backup and exchange byte-for-byte', () async {
    final tracking = ProtoWriter()
      ..int64(1, 2)
      ..integer(2, BigInt.parse('-9223372036854775808'))
      ..integer(100, BigInt.parse('9223372036854775807'))
      ..string(5, 'Tên tracker')
      ..float32(6, 1.5)
      ..float32(8, 8.75)
      ..boolean(12, true)
      ..message(150, Uint8List.fromList([0, 255, 17]));
    final trackerBytes = tracking.finish();
    final memo = Uint8List.fromList([0, 255, 128, 3]);
    final manga = ProtoWriter()
      ..int64(1, int.parse(fixtureSource))
      ..string(2, '/title')
      ..string(3, 'Truyện')
      ..message(18, trackerBytes)
      ..message(112, memo);
    final root = ProtoWriter()..message(1, manga.finish());
    final input = Uint8List.fromList(GZipEncoder().encode(root.finish()));
    final repo = MemoryLibraryRepository();
    final service = BackupService(repo);
    await service.merge(input);
    final book = (await repo.list()).single;
    expect(
      book.externalBackupMetadata!.tracking.single,
      base64Encode(trackerBytes),
    );
    expect(book.externalBackupMetadata!.memo, base64Encode(memo));
    final fresh = MemoryLibraryRepository();
    await BackupService(fresh).replace(
      await service.export(),
      expectedFingerprint: (await fresh.snapshot()).fingerprint,
    );
    expect((await fresh.list()).single.toJson(), book.toJson());
    final exported = await exportMihonBackup(await fresh.snapshot());
    final output = ProtoMessage(
      Uint8List.fromList(GZipDecoder().decodeBytes(exported.bytes)),
    ).messages(1).single;
    expect(output.one(18)!.value, trackerBytes);
    expect(output.one(112)!.value, memo);
    expect(
      output.messages(18).single.integer(100).toString(),
      '9223372036854775807',
    );
    expect(
      output.messages(18).single.integer(2).toString(),
      '-9223372036854775808',
    );
    expect(output.messages(18).single.boolean(12), true);
  });

  test('Tachimanga imports active library tracker rows and preserves original REAL precision', () async {
    final repo = MemoryLibraryRepository();
    await BackupService(repo).merge(tmbFixture(trackerMetadata: true));
    final metadata = (await repo.list()).single.externalBackupMetadata!;
    expect(metadata.format, 'tachimanga-build511');
    expect(metadata.tracking, hasLength(1));
    final track = ProtoMessage(base64Decode(metadata.tracking.single));
    expect(track.integer(1), BigInt.from(2));
    expect(track.integer(2), BigInt.zero);
    expect(track.integer(100).toString(), '9223372036854775807');
    expect(track.string(5), 'Tên trên tracker');
    final archived = jsonDecode(
      utf8.decode(base64Decode(metadata.trackingArchive.single)),
    );
    expect(archived['last_chapter_read'], 1.1);
    expect(archived['score'], 8.1);
    expect(archived['remote_id'], '9223372036854775807');
    expect(archived['library_id'], isNull);
    expect(utf8.decode(base64Decode(metadata.memo!)), '{"source":{"nonce":7}}');
    final output = await exportMihonBackup(await repo.snapshot());
    expect(output.warnings.join(' '), contains('REAL gốc còn nguyên'));
  });

  test(
    'memo provenance is retained but not exported as another source memo',
    () async {
      final repo = MemoryLibraryRepository();
      await BackupService(repo).merge(mihonFixture());
      final original = (await repo.list()).single;
      final moved = original.copyWith(sourceId: '123', sourceRef: '/moved');
      expect(
        moved.externalBackupMetadata,
        same(original.externalBackupMetadata),
      );
      final output = await exportMihonBackup(
        LibrarySnapshot([LibrarySnapshotEntry(moved, {})]),
      );
      final manga = ProtoMessage(
        Uint8List.fromList(GZipDecoder().decodeBytes(output.bytes)),
      ).messages(1).single;
      expect(manga.one(112), isNull);
      expect(
        output.warnings.join(' '),
        contains('không xuất thành memo của nguồn mới'),
      );
    },
  );

  test('metadata rejects malformed, noncanonical or oversized payloads before restore', () async {
    final baseline = LibraryBook(id: 'fixture', title: 'Truyện').toJson();
    final valid = ExternalBackupMetadata(
      format: 'mihon-protobuf-v0.20.4',
      engine: 'tachimanga',
      sourceId: '123',
      sourceRef: '/title',
    ).toJson();
    for (final changes in [
      {'version': 1.0},
      {'sourceId': '00123'},
      {'engine': 'vbook'},
      {
        'tracking': ['not base64'],
      },
      {'tracking': List.filled(65, '')},
      {
        'trackingArchive': [''],
      },
      {'memo': 'A' * (3 * 1024 * 1024)},
      {'unknown': true},
    ]) {
      final root = {
        'schema': 'tachi-books-backup',
        'version': 1,
        'entries': [
          {
            'book': {
              ...baseline,
              'externalBackupMetadata': {...valid, ...changes},
            },
            'contents': {},
          },
        ],
      };
      final repo = MemoryLibraryRepository();
      await expectLater(
        BackupService(repo)
            .merge(Uint8List.fromList(utf8.encode(jsonEncode(root)))),
        throwsFormatException,
      );
      expect(await repo.list(), isEmpty);
    }
  });

  test('bad tracker field types are rejected instead of silently dropping its record', () async {
    final tracker = ProtoWriter()
      ..string(1, 'wrong')
      ..int64(2, 0);
    final manga = ProtoWriter()
      ..int64(1, 123)
      ..string(2, '/title')
      ..string(3, 'Truyện')
      ..message(18, tracker.finish());
    final root = ProtoWriter()..message(1, manga.finish());
    await expectLater(
      readMihonBackup(Uint8List.fromList(GZipEncoder().encode(root.finish()))),
      throwsFormatException,
    );
  });
}
