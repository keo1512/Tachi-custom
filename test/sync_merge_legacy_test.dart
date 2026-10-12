import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tachi_books/features/library/data/backup_validation.dart';
import 'package:tachi_books/features/library/data/library_repository.dart';
import 'package:tachi_books/features/library/domain/library_book.dart';
import 'package:tachi_books/features/sync/domain/sync_merge_plan.dart';

Uint8List _encode(Map<String, dynamic> root) =>
    Uint8List.fromList(utf8.encode(jsonEncode(root)));

Map<String, dynamic> _snapshot({String notes = ''}) => {
  'schema': 'tachi-books-backup',
  'version': 1,
  'entries': [
    {
      'book': LibraryBook(
        id: 'tachimanga:9223372036854775807:/book/123',
        title: 'Truyện',
        notes: notes,
        kind: 'manga',
        engine: 'tachimanga',
        sourceId: '9223372036854775807',
        chapters: const [
          BookChapter(id: '/chapter/abc', title: 'Chương', index: 0),
        ],
      ).toJson(),
      'contents': {
        '0': ReaderContent(
          kind: 'manga',
          images: const ['data:image/png;base64,AQID'],
        ).toJson(),
      },
    },
  ],
};

void main() {
  final validator = BackupValidator(MemoryLibraryRepository());

  test(
    'legacy omitted defaults do not conflict with a remote-only book edit',
    () {
      final baseline = _snapshot();
      final entry = (baseline['entries'] as List).single as Map;
      final book = entry['book'] as Map;
      for (final key in [
        'artist',
        'genres',
        'notes',
        'series',
        'categories',
        'status',
        'sourceName',
      ]) {
        book.remove(key);
      }
      ((entry['contents'] as Map)['0'] as Map).remove('imageHeaders');
      final base = _encode(baseline);
      final local = _encode(_snapshot());
      final remote = _encode(_snapshot(notes: 'Ghi chú từ máy khác'));
      // These are real accepted backup images, not simplified JSON fixtures.
      expect(
        validator.validateSnapshot(base).fingerprint,
        validator.validateSnapshot(local).fingerprint,
      );
      validator.validateSnapshot(remote);
      final plan = SyncMergePlan.tryBuild(local, remote, baseline: base)!;
      expect(plan.conflicts, isEmpty);
      final merged = validator.validateSnapshot(plan.encode({}));
      final result = merged.entries.single;
      expect(result.book.notes, 'Ghi chú từ máy khác');
      expect(result.book.id, 'tachimanga:9223372036854775807:/book/123');
      expect(result.book.sourceId, '9223372036854775807');
      expect(result.book.chapters.single.id, '/chapter/abc');
      expect(
        UriData.parse(result.contents[0]!.images.single).contentAsBytes(),
        [1, 2, 3],
      );
    },
  );

  test('equivalent embedded image encodings preserve bytes without false conflicts', () {
    final baseline = _snapshot();
    final entry = (baseline['entries'] as List).single as Map;
    ((entry['contents'] as Map)['0'] as Map)['images'] = [
      'data:image/png,%01%02%03',
    ];
    final base = _encode(baseline);
    final local = _encode(_snapshot());
    expect(
      validator.validateSnapshot(base).fingerprint,
      validator.validateSnapshot(local).fingerprint,
    );
    final plan = SyncMergePlan.tryBuild(
      local,
      _encode(_snapshot(notes: 'Ghi chú')),
      baseline: base,
    )!;
    expect(plan.conflicts, isEmpty);
    final content = validator.validateSnapshot(plan.encode({})).entries.single;
    expect(content.book.notes, 'Ghi chú');
    expect(UriData.parse(content.contents[0]!.images.single).contentAsBytes(), [
      1,
      2,
      3,
    ]);
  });
}
