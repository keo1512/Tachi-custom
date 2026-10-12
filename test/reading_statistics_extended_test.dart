import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tachi_books/features/library/application/reading_statistics_controller.dart';
import 'package:tachi_books/features/library/data/backup_compatibility/protobuf_writer.dart';
import 'package:tachi_books/features/library/data/backup_service.dart';
import 'package:tachi_books/features/library/data/library_repository.dart';
import 'package:tachi_books/features/library/data/library_snapshot.dart';
import 'package:tachi_books/features/library/domain/external_backup_metadata.dart';
import 'package:tachi_books/features/library/domain/library_book.dart';
import 'package:tachi_books/features/library/domain/reading_statistics.dart';
import 'package:tachi_books/features/library/presentation/library_view_model.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('explicit reading states remain separate from publication and legacy reading', () {
    final books = [
      _book('planned')
          .copyWith(readingState: 'planned', lastRead: DateTime(2026, 10, 10)),
      _book('paused').copyWith(readingState: 'paused', status: 2),
      _book('reading').copyWith(readingState: 'reading'),
      _book('done').copyWith(completed: true),
      _book('legacy').copyWith(progress: .1),
    ];
    final stats = ReadingStatistics(books, cachedChapters: const {});
    expect(stats.planned, 1);
    expect(stats.paused, 1);
    expect(stats.inProgress, 2);
    expect(stats.completed, 1);
    expect(stats.readingStates.values.reduce((a, b) => a + b), books.length);
    expect(books[1].status, 2);
  });

  test('verified cache overrides stale flags and weighted counts include all chapters', () {
    final short = _book('short').copyWith(completed: true);
    final long = _book('long', count: 4).copyWith(
      chapters: [
        const BookChapter(
          id: 'long-0',
          title: '1',
          index: 0,
          read: true,
          downloaded: true,
        ),
        for (var index = 1; index < 4; index++)
          BookChapter(
            id: 'long-$index',
            title: '$index',
            index: index,
            read: false,
            downloaded: true,
          ),
      ],
    );
    final stats = ReadingStatistics(
      [short, long],
      cachedChapters: {
        'long': {2, -1, 99},
      },
    );
    expect(stats.progress, .4);
    expect(stats.downloaded, 1);
    expect(stats.offlineBooks, 1);
    expect(stats.cacheVerified, true);
    expect(stats.progressGroups.values.reduce((a, b) => a + b), 2);
  });

  test('same source ID groups across labels and overlapping categories deduplicate', () {
    final stats = ReadingStatistics([
      _book('a').copyWith(
        engine: 'tachimanga',
        sourceId: '64',
        sourceName: 'QQ',
        categories: ['X', 'Y'],
      ),
      _book('b').copyWith(
        engine: 'tachimanga',
        sourceId: '64',
        sourceName: 'TruyenQQ',
        categories: ['X'],
      ),
      _book('c').copyWith(engine: 'vbook', sourceId: '64', sourceName: 'QQ'),
    ]);
    expect(stats.sources['QQ · tachimanga · 64'], 2);
    expect(stats.sources['QQ · vbook · 64'], 1);
    expect(stats.categories['X'], 2);
  });

  test('tracker service records deduplicate per book and preserve opaque unknown bytes', () {
    final tracker =
        (ProtoWriter()
              ..int64(1, 2)
              ..integer(2, BigInt.parse('9223372036854775807'))
              ..float32(8, 99)
              ..message(150, Uint8List.fromList([0, 255])))
            .finish();
    final unknown =
        (ProtoWriter()
              ..int64(1, 987)
              ..int64(2, 1))
            .finish();
    final metadata = ExternalBackupMetadata(
      format: 'mihon-protobuf-v0.20.4',
      engine: 'tachimanga',
      sourceId: '1',
      sourceRef: '/book',
      tracking: [
        base64Encode(tracker),
        base64Encode(tracker),
        base64Encode(unknown),
      ],
    );
    final book = _book('a').copyWith(externalBackupMetadata: metadata);
    final before = book.toJson();
    final stats = ReadingStatistics([book]);
    expect(stats.trackers, {'AniList': 1, 'Dịch vụ #987': 1});
    expect(stats.trackedBooks, 1);
    expect(stats.averageRating, isNull);
    expect(book.toJson(), before);
  });

  test('only explicit finite local ratings are averaged including a real zero rating', () {
    final stats = ReadingStatistics([
      _book('unrated'),
      _book('zero').copyWith(rating: 0),
      _book('rated').copyWith(rating: 8),
      _book('bad').copyWith(rating: double.nan),
    ]);
    expect(stats.ratedBooks, 2);
    expect(stats.averageRating, 4);
  });

  test('daily times validate calendar and retain genuine durations across year boundary', () {
    final time = RecordedReadingTime({
      'readSeconds:2026-1-2': 61,
      'readSeconds:2026-1-1': 120,
      'readSeconds:2025-12-31': 240,
      'readSeconds:2025-1-1': 600,
      'readSeconds:2026-2-30': 999,
      'readSeconds:2026-1-3': 999,
      'readSeconds:2026-1-0': 999,
      'readSeconds:2026-1-01': -1,
      'readSeconds:secret': 999,
      'unrelated': 999,
    }, now: DateTime(2026, 1, 2, 15));
    expect(time.todaySeconds, 61);
    expect(time.recentSeconds(7), 421);
    expect(time.totalSeconds, 1021);
    expect(time.ignoredRecords, 5);
    expect(time.daysBack(3), [
      DateTime(2025, 12, 31),
      DateTime(2026, 1, 1),
      DateTime(2026, 1, 2),
    ]);
  });

  test('recent books use saved dates and never manufacture future reading activity', () {
    final now = DateTime(2026, 10, 12);
    final stats = ReadingStatistics([
      _book('old').copyWith(lastRead: DateTime(2020)),
      _book('new').copyWith(lastRead: now.subtract(const Duration(minutes: 1))),
      _book('future').copyWith(lastRead: now.add(const Duration(days: 1))),
      _book('unread'),
    ]);
    expect(stats.recentBooks(now).map((book) => book.id), ['new', 'old']);
  });

  test('statistics provider counts stored offline content, excludes partial remote images without mutation', () async {
    final repo = MemoryLibraryRepository();
    final book = _book('one', count: 3).copyWith(
      kind: 'novel',
      chapters: [
        for (var index = 0; index < 3; index++)
          BookChapter(
            id: 'one-$index',
            title: '$index',
            index: index,
            downloaded: true,
          ),
      ],
    );
    await repo.save(book);
    await repo.saveChapter(
      'one',
      0,
      ReaderContent(kind: 'novel', html: '<p>Offline text</p>'),
    );
    await repo.saveChapter(
      'one',
      1,
      ReaderContent(
        kind: 'novel',
        html: '<p>Partial</p><img src="https://example.org/page.png">',
      ),
    );
    final before = (await repo.snapshot()).fingerprint;
    final container = ProviderContainer(
      overrides: [libraryRepositoryProvider.overrideWithValue(repo)],
    );
    addTearDown(container.dispose);
    final sub = container.listen(readingStatisticsProvider, (_, _) {});
    addTearDown(sub.close);
    final stats = await container.read(readingStatisticsProvider.future);
    expect(stats.downloaded, 1);
    expect(stats.offlineBooks, 1);
    expect((await repo.snapshot()).fingerprint, before);
  });

  test('status and rating edit latest metadata preserving download/progress and full backup roundtrip', () async {
    final repo = MemoryLibraryRepository();
    await repo.save(_book('a').copyWith(progress: .5, notes: 'original'));
    final revision = repo.replacementRevision;
    await repo.mutateBook(
      'a',
      (latest) => latest.copyWith(notes: 'later edit'),
    );
    final editor = ReadingStatisticsEditor(repo);
    await editor.setReadingState('a', 'paused', expectedRevision: revision);
    await editor.setRating('a', 7.5, expectedRevision: revision);
    final saved = (await repo.find('a'))!;
    expect(saved.notes, 'later edit');
    expect(saved.progress, .5);
    expect(saved.readingState, 'paused');
    expect(saved.rating, 7.5);
    final fresh = MemoryLibraryRepository();
    await BackupService(fresh).replace(
      await BackupService(repo).export(),
      expectedFingerprint: (await fresh.snapshot()).fingerprint,
    );
    expect((await fresh.find('a'))!.toJson(), saved.toJson());
    await editor.setRating('a', null, expectedRevision: revision);
    expect((await repo.find('a'))!.rating, isNull);
  });

  test('stale restore and privacy guards prevent editor writes', () async {
    final repo = MemoryLibraryRepository();
    await repo.save(_book('a'));
    final revision = repo.replacementRevision;
    await repo.replaceSnapshot(
      LibrarySnapshot([LibrarySnapshotEntry(_book('a'), {})]),
      expectedFingerprint: (await repo.snapshot()).fingerprint,
    );
    final before = (await repo.snapshot()).fingerprint;
    final editor = ReadingStatisticsEditor(repo);
    await expectLater(
      editor.setReadingState('a', 'paused', expectedRevision: revision),
      throwsStateError,
    );
    await expectLater(
      editor.setRating(
        'a',
        5,
        expectedRevision: repo.replacementRevision,
        guard: () => throw StateError('locked'),
      ),
      throwsStateError,
    );
    expect((await repo.snapshot()).fingerprint, before);
  });

  test('legacy backups omit new fields, explicit invalid fields are rejected without changes', () async {
    final repo = MemoryLibraryRepository();
    await repo.save(_book('a'));
    final service = BackupService(repo);
    final original = await service.export();
    final json = jsonDecode(utf8.decode(original)) as Map<String, dynamic>;
    final book = ((json['entries'] as List).single as Map)['book'] as Map;
    expect(book.containsKey('readingState'), false);
    expect(book.containsKey('rating'), false);
    for (final invalid in [
      {'readingState': 'bogus'},
      {'rating': -1},
      {'rating': 11},
      {'rating': '8'},
    ]) {
      final changed = Map<String, dynamic>.from(
        jsonDecode(utf8.decode(original)) as Map,
      );
      (((changed['entries'] as List).single as Map)['book'] as Map).addAll(
        invalid,
      );
      expect(
        () => service.validate(
          Uint8List.fromList(utf8.encode(jsonEncode(changed))),
        ),
        throwsFormatException,
      );
    }
    expect(await service.export(), original);
  });
}

LibraryBook _book(String id, {int count = 1}) => LibraryBook(
  id: id,
  title: id,
  chapters: [
    for (var index = 0; index < count; index++)
      BookChapter(id: '$id-$index', title: '$index', index: index, read: false),
  ],
);
