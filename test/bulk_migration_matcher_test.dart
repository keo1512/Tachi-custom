import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:tachi_books/features/library/data/library_repository.dart';
import 'package:tachi_books/features/library/data/library_snapshot.dart';
import 'package:tachi_books/features/library/domain/library_book.dart';
import 'package:tachi_books/features/sources/application/bulk_migration_matcher.dart';
import 'package:tachi_books/features/sources/data/source_repository.dart';
import 'package:tachi_books/features/sources/domain/catalogue.dart';
import 'package:tachi_books/features/sources/domain/source_migration.dart';

CatalogueSource source(String id) => CatalogueSource(
  id: id,
  name: 'Nguồn $id',
  lang: 'vi',
  baseUrl: '',
  kind: ContentKind.manga,
  engine: SourceEngine.tachimanga,
);
CatalogueBook target(String source, String title, {String? ref}) =>
    CatalogueBook(
      ref: ref ?? '/$title',
      title: title,
      sourceId: source,
      kind: ContentKind.manga,
      engine: SourceEngine.tachimanga,
    );

class Books extends MemoryLibraryRepository {
  int captures = 0;
  @override
  Future<LibrarySnapshot> snapshot() {
    captures++;
    return super.snapshot();
  }
}

class Sources extends SourceRepository {
  Sources() : super(tachimangaUrl: '', vbookUrl: '');
  final calls = <String>[];
  Future<List<CatalogueBook>> Function(CatalogueSource, String, int)? respond;
  Future<CatalogueBook> Function(CatalogueBook)? details;
  final counts = <String, int>{};
  @override
  Future<List<CatalogueBook>> search(
    CatalogueSource source,
    String query, {
    int page = 1,
  }) async {
    calls.add('${source.id}:$query:$page');
    return respond == null
        ? CataloguePage([target(source.id, query)], hasNextPage: false)
        : respond!(source, query, page);
  }

  @override
  Future<CatalogueBook> detail(CatalogueBook book) async =>
      details == null ? book : details!(book);
  @override
  Future<List<CatalogueChapter>> chapters(CatalogueBook book) async => [
    for (var i = 0; i < (counts[book.sourceId] ?? 2); i++)
      CatalogueChapter(
        ref: '${book.ref}/$i',
        title: 'Chương ${i + 1}',
        number: i + 1,
        index: i,
      ),
  ];
}

Future<Books> library([
  List<String> titles = const ['Tên Một', 'Tên Hai'],
]) async {
  final books = Books();
  for (final (index, title) in titles.indexed) {
    await books.save(
      LibraryBook(
        id: '$index',
        title: title,
        sourceId: 'old',
        sourceName: 'Cũ',
        sourceRef: '/$index',
        kind: 'manga',
        engine: 'tachimanga',
        categories: const ['manga'],
        bookmarks: const ['0:0.5000'],
        currentChapter: 0,
        chapters: const [
          BookChapter(
            id: '/old/1',
            title: 'Chương 1',
            index: 0,
            number: 1,
            read: true,
          ),
        ],
      ),
    );
  }
  return books;
}

void main() {
  test('ordered first-match stages all books with one immutable snapshot and no writes', () async {
    final books = await library();
    final before = (await books.snapshot()).fingerprint;
    final sources = Sources();
    addTearDown(sources.dispose);
    final service = SourceMigration(books);
    books.captures = 0;
    final results = (await BulkMigrationMatcher(sources, service).match(
      bookIds: ['0', '1'],
      targets: [source('2'), source('1')],
      strategy: BulkMigrationStrategy.firstMatch,
    ))!;
    expect(books.captures, 1);
    expect(results.map((e) => e.state), everyElement(BulkMatchState.matched));
    expect(sources.calls, ['2:Tên Một:1', '2:Tên Hai:1']);
    expect(
      identical(results.first.preview!.before, results.last.preview!.before),
      isTrue,
    );
    expect((await books.snapshot()).fingerprint, before);
    expect(results.first.preview!.replacement.chapters.first.read, isTrue);
    await service.commitBatch(
      results.map((e) => e.preview!).toList(),
      replaceOld: true,
      expectedRevision: books.replacementRevision,
    );
    expect((await books.list()).map((e) => e.sourceId), everyElement('2'));
  });
  test('most-chapters checks every target and retains ordered tie preference despite source failure', () async {
    final books = await library(['A']);
    final sources = Sources()..counts.addAll({'1': 2, '2': 4, '3': 4});
    sources.respond = (s, q, p) async {
      if (s.id == 'bad') throw StateError('Không kết nối');
      return CataloguePage([target(s.id, q)], hasNextPage: false);
    };
    addTearDown(sources.dispose);
    final result =
        (await BulkMigrationMatcher(sources, SourceMigration(books)).match(
          bookIds: ['0'],
          targets: [source('1'), source('bad'), source('2'), source('3')],
          strategy: BulkMigrationStrategy.mostChapters,
        ))!.single;
    expect(result.preview!.replacement.sourceId, '2');
    expect(result.preview!.replacement.chapters.length, 4);
    expect(sources.calls.length, 4);
    expect(result.message, contains('Không kết nối'));
  });
  test(
    'ambiguous titles and bounded incomplete pages require manual selection',
    () async {
      final books = await library(['A']);
      final sources = Sources();
      addTearDown(sources.dispose);
      sources.respond = (s, q, p) async => CataloguePage([
        target(s.id, q, ref: '/1'),
        target(s.id, q, ref: '/2'),
      ], hasNextPage: false);
      final matcher = BulkMigrationMatcher(sources, SourceMigration(books));
      final ambiguous = (await matcher.match(
        bookIds: ['0'],
        targets: [source('1')],
        strategy: BulkMigrationStrategy.firstMatch,
      ))!.single;
      expect(ambiguous.state, BulkMatchState.ambiguous);
      expect(ambiguous.preview, isNull);
      sources.calls.clear();
      sources.respond = (s, q, p) async =>
          CataloguePage([target(s.id, q)], hasNextPage: true);
      final incomplete = (await matcher.match(
        bookIds: ['0'],
        targets: [source('1')],
        strategy: BulkMigrationStrategy.firstMatch,
      ))!.single;
      expect(incomplete.state, BulkMatchState.ambiguous);
      expect(sources.calls.length, 3);
    },
  );
  test(
    'aliases are fallback queries, unrelated results are never staged',
    () async {
      final books = await library(['A']);
      await books.save(
        (await books.find('0'))!.copyWith(alternativeTitles: ['Other title']),
      );
      final sources = Sources();
      addTearDown(sources.dispose);
      sources.respond = (s, q, p) async => CataloguePage([
        target(s.id, q == 'Other title' ? q : 'Something else'),
      ], hasNextPage: false);
      final result =
          (await BulkMigrationMatcher(sources, SourceMigration(books)).match(
            bookIds: ['0'],
            targets: [source('1')],
            strategy: BulkMigrationStrategy.firstMatch,
          ))!.single;
      expect(result.preview!.replacement.title, 'Other title');
      expect(sources.calls, ['1:A:1', '1:Other title:1']);
    },
  );
  test('cancel returns immediately and ignores late work without starting next source/book', () async {
    final books = await library();
    final sources = Sources();
    addTearDown(sources.dispose);
    final pending = Completer<List<CatalogueBook>>(),
        entered = Completer<void>();
    sources.respond = (s, q, p) {
      entered.complete();
      return pending.future;
    };
    final results = <BulkMigrationMatch>[];
    final matcher = BulkMigrationMatcher(sources, SourceMigration(books));
    final running = matcher.match(
      bookIds: ['0', '1'],
      targets: [source('1'), source('2')],
      strategy: BulkMigrationStrategy.firstMatch,
      onResult: results.add,
    );
    await entered.future;
    matcher.cancel();
    expect(await running.timeout(const Duration(seconds: 1)), isNull);
    pending.complete(
      CataloguePage([target('1', 'Tên Một')], hasNextPage: false),
    );
    await Future<void>.delayed(Duration.zero);
    expect(results, isEmpty);
    expect(sources.calls.length, 1);
  });
  test(
    'same-byte restore invalidates matching session and late result',
    () async {
      final books = await library(['A']);
      final service = SourceMigration(books);
      final session = await service.beginSession();
      final sources = Sources();
      addTearDown(sources.dispose);
      final pending = Completer<List<CatalogueBook>>(),
          entered = Completer<void>();
      sources.respond = (s, q, p) {
        entered.complete();
        return pending.future;
      };
      final running = BulkMigrationMatcher(sources, service).match(
        bookIds: ['0'],
        targets: [source('1')],
        strategy: BulkMigrationStrategy.firstMatch,
        session: session,
      );
      final rejected = expectLater(running, throwsStateError);
      await entered.future;
      await books.replaceSnapshot(
        session.before,
        expectedFingerprint: session.fingerprint,
      );
      pending.complete(CataloguePage([target('1', 'A')], hasNextPage: false));
      await rejected;
      expect((await books.list()).single.sourceId, 'old');
    },
  );
  test('wrong identities, timeouts, empty chapter lists and duplicate destinations are isolated', () async {
    final books = await library(['A', 'A']);
    final sources = Sources();
    addTearDown(sources.dispose);
    sources.respond = (s, q, p) async =>
        CataloguePage([target('wrong', q)], hasNextPage: false);
    final matcher = BulkMigrationMatcher(
      sources,
      SourceMigration(books),
      timeout: const Duration(milliseconds: 100),
    );
    final wrong = (await matcher.match(
      bookIds: ['0'],
      targets: [source('1')],
      strategy: BulkMigrationStrategy.firstMatch,
    ))!.single;
    expect(wrong.state, BulkMatchState.failed);
    expect(wrong.message, contains('danh tính'));
    sources.respond = (s, q, p) => Completer<List<CatalogueBook>>().future;
    final slow = (await matcher.match(
      bookIds: ['0'],
      targets: [source('1')],
      strategy: BulkMigrationStrategy.firstMatch,
    ))!.single;
    expect(slow.state, BulkMatchState.failed);
    sources.respond = null;
    sources.counts['1'] = 0;
    final empty = (await matcher.match(
      bookIds: ['0'],
      targets: [source('1')],
      strategy: BulkMigrationStrategy.firstMatch,
    ))!.single;
    expect(empty.state, BulkMatchState.failed);
    sources.counts['1'] = 2;
    final duplicate = (await matcher.match(
      bookIds: ['0', '1'],
      targets: [source('1')],
      strategy: BulkMigrationStrategy.firstMatch,
    ))!;
    expect(duplicate.map((r) => r.state), [
      BulkMatchState.matched,
      BulkMatchState.duplicate,
    ]);
  });
  test('disabled chapter/category options reset only requested data and can be toggled back', () async {
    final books = await library(['A']);
    final service = SourceMigration(books);
    final preview = await service.preview(
      '0',
      target('1', 'A'),
      const [
        CatalogueChapter(ref: '/one', title: 'Chương 1', index: 0, number: 1),
      ],
      options: const SourceMigrationOptions(chapters: false, categories: false),
    );
    expect(preview.replacement.chapters.single.read, isFalse);
    expect(preview.replacement.bookmarks, isEmpty);
    expect(preview.replacement.categories, ['Mặc định']);
    final restored = preview.withOptions(const SourceMigrationOptions());
    expect(restored.replacement.chapters.single.read, isTrue);
    expect(restored.replacement.bookmarks, ['0:0.0000']);
    expect(restored.replacement.categories, ['manga']);
  });
}
