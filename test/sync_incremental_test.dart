import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tachi_books/features/library/domain/library_book.dart';
import 'package:tachi_books/features/sync/data/sync_blob_cache.dart';
import 'package:tachi_books/features/sync/data/sync_chunk_plan.dart';
import 'package:tachi_books/features/sync/domain/sync_engine.dart';
import 'package:tachi_books/features/sync/domain/sync_merge_plan.dart';

Uint8List image({
  Map<String, Map<String, Object?>>? books,
  Map<String, Object?>? settings,
}) => Uint8List.fromList(
  utf8.encode(
    jsonEncode({
      'schema': 'tachi-books-backup',
      'version': 1,
      if (settings != null)
        'configuration': {'version': 1, 'preferences': settings},
      'entries': [
        for (final entry
            in (books ??
                    {
                      'a': {'progress': 0},
                    })
                .entries)
          {
            'book': {
              ...LibraryBook(
                id: entry.key,
                title: 'Truyện ${entry.key}',
                cover: 'https://example.org/cover.png',
                chapters: const [
                  BookChapter(id: 'chapter', title: 'Chương', index: 0),
                ],
              ).toJson(),
              ...entry.value,
            },
            'contents': {
              '0': ReaderContent(
                kind: 'novel',
                html: '<p>Nội dung ${entry.key}</p>',
              ).toJson(),
            },
          },
      ],
    }),
  ),
);
Map<String, dynamic> decoded(Uint8List bytes) =>
    jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('content-addressed roundtrip preserves cached content, covers and public configuration', () {
    final source = image(settings: {'appearanceV1': 'dark'});
    final original = Uint8List.fromList(source);
    final plan = SyncChunkPlan.build(source);
    expect(
      decoded(SyncChunkPlan.assemble(plan.manifest, plan.chunks)),
      decoded(source),
    );
    expect(source, original);
    expect(
      SyncChunkPlan.inventory(plan.manifest).keys.toSet(),
      plan.chunks.keys.toSet(),
    );
  });
  test('metadata-only reading edit reuses megabytes of offline pages', () {
    final root = decoded(image());
    final entry = (root['entries'] as List).single as Map;
    (entry['contents'] as Map)['0'] = {
      'images': ['data:image/png;base64,${'A' * 1700000}'],
      'html': '',
    };
    Uint8List encode() => Uint8List.fromList(utf8.encode(jsonEncode(root)));
    final first = SyncChunkPlan.build(encode());
    (entry['book'] as Map)['progress'] = .8;
    final next = SyncChunkPlan.build(encode());
    final changed = next.chunks.entries.where(
      (entry) => !first.chunks.containsKey(entry.key),
    );
    expect(
      changed.fold<int>(0, (sum, item) => sum + item.value.length),
      lessThan(1024),
    );
    expect(
      next.chunks.values.every(
        (bytes) => bytes.length <= SyncChunkPlan.chunkBytes,
      ),
      isTrue,
    );
    expect(decoded(SyncChunkPlan.assemble(next.manifest, next.chunks)), root);
  });
  test(
    'missing and corrupt pieces are rejected before assembling a library',
    () {
      final plan = SyncChunkPlan.build(image());
      final missing = {...plan.chunks}..remove(plan.chunks.keys.first);
      expect(
        () => SyncChunkPlan.assemble(plan.manifest, missing),
        throwsA(isA<SyncFailure>()),
      );
      final corrupt = {
        ...plan.chunks,
        plan.chunks.keys.first: Uint8List.fromList([0]),
      };
      expect(
        () => SyncChunkPlan.assemble(plan.manifest, corrupt),
        throwsA(isA<SyncFailure>()),
      );
      final metadata = decoded(plan.manifest)..['digest'] = 'a' * 64;
      expect(
        () => SyncChunkPlan.assemble(
          Uint8List.fromList(utf8.encode(jsonEncode(metadata))),
          plan.chunks,
        ),
        throwsA(isA<SyncFailure>()),
      );
    },
  );
  test('manifest paths, impossible lengths and repeated expansion bombs are rejected', () {
    final plan = SyncChunkPlan.build(image());
    for (final value in ['../bad', 'a' * 63]) {
      final root = decoded(plan.manifest);
      (((root['root'] as Map)['entries'] as List).single as Map)['book'] = [
        {'hash': value, 'bytes': 10},
      ];
      expect(
        () => SyncChunkPlan.inventory(
          Uint8List.fromList(utf8.encode(jsonEncode(root))),
        ),
        throwsA(isA<SyncFailure>()),
      );
    }
    final root = decoded(plan.manifest);
    (((root['root'] as Map)['entries'] as List).single as Map)['book'] =
        List.generate(343, (_) => {'hash': 'a' * 64, 'bytes': 393216});
    expect(
      () => SyncChunkPlan.inventory(
        Uint8List.fromList(utf8.encode(jsonEncode(root))),
      ),
      throwsA(isA<SyncFailure>()),
    );
  });
  test('three-way merge retains independent changes and an unchanged-side deletion', () {
    final base = image(
      books: {
        'a': {'progress': 0},
        'b': {'progress': 0},
        'c': {'progress': 0},
      },
      settings: {'appearanceV1': 'dark', 'fontSize': 18},
    );
    final local = image(
      books: {
        'a': {'progress': .3},
        'b': {'progress': 0},
      },
      settings: {'appearanceV1': 'light', 'fontSize': 18},
    );
    final remote = image(
      books: {
        'a': {'progress': 0},
        'b': {'progress': .7},
        'c': {'progress': 0},
      },
      settings: {'appearanceV1': 'dark', 'fontSize': 20},
    );
    final plan = SyncMergePlan.tryBuild(local, remote, baseline: base)!;
    expect(plan.conflicts, isEmpty);
    final merged = decoded(plan.encode({}));
    final books = {
      for (final e in merged['entries'] as List)
        (e['book'] as Map)['id']: e['book'],
    };
    expect(books.keys, ['a', 'b']);
    expect(books['a']['progress'], .3);
    expect(books['b']['progress'], .7);
    expect((merged['configuration'] as Map)['preferences'], {
      'appearanceV1': 'light',
      'fontSize': 20,
    });
  });
  test(
    'same-book edits and edit-versus-delete require explicit record choices',
    () {
      final base = image(
        books: {
          'a': {'progress': 0},
          'b': {'progress': 0},
        },
      );
      final local = image(
        books: {
          'a': {'progress': .2},
        },
      );
      final remote = image(
        books: {
          'a': {'progress': .9},
          'b': {'progress': .5},
        },
      );
      final plan = SyncMergePlan.tryBuild(local, remote, baseline: base)!;
      expect(plan.conflicts.map((c) => c.key), ['book:a', 'book:b']);
      expect(plan.conflicts.last.localDeleted, isTrue);
      expect(() => plan.encode({'book:a': true}), throwsFormatException);
      final entries =
          decoded(plan.encode({'book:a': false, 'book:b': true}))['entries']
              as List;
      expect(entries, hasLength(1));
      expect(entries.single['book']['progress'], .9);
      expect(entries.single['contents']['0']['html'], '<p>Nội dung a</p>');
    },
  );
  test('without a common baseline merge unions unique books and asks for differing records', () {
    final plan = SyncMergePlan.tryBuild(
      image(
        books: {
          'a': {'progress': .2},
          'b': {},
        },
      ),
      image(
        books: {
          'a': {'progress': .5},
          'c': {},
        },
      ),
    )!;
    expect(plan.hasBaseline, isFalse);
    expect(plan.conflicts.map((item) => item.key), ['book:a']);
    expect(decoded(plan.encode({'book:a': true}))['entries'], hasLength(3));
  });
  test('disk cache is account-isolated and refuses corrupt reuse', () async {
    final folder = await Directory.systemTemp.createTemp('tachi-sync-cache-');
    addTearDown(() => folder.delete(recursive: true));
    final plan = SyncChunkPlan.build(image());
    final chunk = plan.chunks.entries.first;
    final alice = FileSyncBlobCache('alice', directory: folder);
    final bob = FileSyncBlobCache('bob', directory: folder);
    await alice.write(chunk.key, chunk.value);
    expect(await alice.read(chunk.key), chunk.value);
    expect(await bob.read(chunk.key), isNull);
    final file =
        await folder
                .list(recursive: true)
                .where((item) => item is File && item.path.endsWith(chunk.key))
                .first
            as File;
    await file.writeAsBytes([0]);
    expect(await alice.read(chunk.key), isNull);
    await expectLater(
      alice.write(chunk.key, Uint8List.fromList([0])),
      throwsFormatException,
    );
  });
}
