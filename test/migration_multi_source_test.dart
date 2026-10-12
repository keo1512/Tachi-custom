import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tachi_books/features/library/data/library_repository.dart';
import 'package:tachi_books/features/library/domain/library_book.dart';
import 'package:tachi_books/features/library/presentation/library_view_model.dart';
import 'package:tachi_books/features/sources/application/migration_search.dart';
import 'package:tachi_books/features/sources/data/source_repository.dart';
import 'package:tachi_books/features/sources/domain/catalogue.dart';
import 'package:tachi_books/features/sources/presentation/source_migration_screen.dart';

CatalogueSource source(int id) => CatalogueSource(
  id: '$id',
  name: 'Nguồn $id',
  lang: 'vi',
  baseUrl: 'https://example.org',
  kind: ContentKind.novel,
  engine: SourceEngine.vbook,
);
CatalogueBook target(int id) => CatalogueBook(
  ref: '/$id',
  title: 'Truyện $id',
  sourceId: '$id',
  kind: ContentKind.novel,
  engine: SourceEngine.vbook,
);

class Sources extends SourceRepository {
  Sources(this.respond) : super(tachimangaUrl: '', vbookUrl: '');
  final Future<List<CatalogueBook>> Function(CatalogueSource) respond;
  final calls = <String>[];
  @override
  Future<List<CatalogueBook>> search(
    CatalogueSource source,
    String query, {
    int page = 1,
  }) {
    calls.add(source.id);
    return respond(source);
  }
}

void main() {
  test('multi-source search keeps successful sources, deduplicates results and isolates failures', () async {
    final repository = Sources((source) async {
      if (source.id == '2') throw StateError('Nguồn đang bảo trì');
      return [target(int.parse(source.id)), target(int.parse(source.id))];
    });
    addTearDown(repository.dispose);
    final changes = <MigrationSearchProgress>[];
    final result = (await MigrationSearch(repository).search(
      [source(1), source(2), source(3)],
      ' Tên ',
      onProgress: changes.add,
    ))!;
    expect(result.results.map((result) => result.source.id), ['1', '2', '3']);
    expect(result.results.first.books.length, 1);
    expect(result.results[1].error, contains('bảo trì'));
    expect(result.results.last.books.single.sourceId, '3');
    expect(changes.first.completed, 0);
    expect(changes.last.fraction, 1);
  });
  test(
    'cancellation suppresses late results and prevents queued source work',
    () async {
      final held = {
        for (var id = 1; id <= 4; id++) '$id': Completer<List<CatalogueBook>>(),
      };
      final repository = Sources((source) => held[source.id]!.future);
      addTearDown(repository.dispose);
      final progress = <MigrationSearchProgress>[];
      final searches = MigrationSearch(repository);
      final result = searches.search(
        [for (var id = 1; id <= 4; id++) source(id)],
        'Tên',
        onProgress: progress.add,
      );
      await Future<void>.delayed(Duration.zero);
      expect(repository.calls, ['1', '2', '3']);
      searches.cancel();
      for (var id = 1; id <= 3; id++) {
        held['$id']!.complete([target(id)]);
      }
      expect(await result, isNull);
      expect(repository.calls, ['1', '2', '3']);
      expect(progress.length, 1);
    },
  );
  test('wrong source identity and timeout are reported without accepting unsafe results', () async {
    final repository = Sources((source) async => [target(99)]);
    addTearDown(repository.dispose);
    final result = (await MigrationSearch(repository)
        .search([source(1)], 'Tên'))!;
    expect(result.results.single.books, isEmpty);
    expect(result.results.single.error, contains('danh tính'));
    final slow = Sources((source) => Completer<List<CatalogueBook>>().future);
    addTearDown(slow.dispose);
    final timeout = (await MigrationSearch(
      slow,
      timeout: const Duration(milliseconds: 1),
    ).search([source(1)], 'Tên'))!;
    expect(timeout.results.single.error, contains('Timeout'));
  });

  for (final size in [const Size(320, 568), const Size(430, 932)]) {
    testWidgets(
      'migration shows multi-source progress and cancel is read-only at $size',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = size;
        addTearDown(tester.view.reset);
        final repository = MemoryLibraryRepository();
        await repository.save(
          LibraryBook(
            id: 'old',
            title: 'Tên cũ',
            engine: 'vbook',
            sourceId: 'old',
            chapters: const [BookChapter(id: 'a', title: 'A', index: 0)],
          ),
        );
        final before = (await repository.snapshot()).fingerprint;
        final held = Completer<List<CatalogueBook>>();
        final sources = Sources((source) async {
          if (source.id == '1') return held.future;
          return [target(2)];
        });
        addTearDown(sources.dispose);
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              libraryRepositoryProvider.overrideWithValue(repository),
              sourceRepositoryProvider.overrideWithValue(sources),
            ],
            child: MaterialApp(
              home: SourceMigrationScreen(
                bookId: 'old',
                source: source(1),
                alternatives: [source(2)],
              ),
            ),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 10));
        expect(find.text('Đã tìm 1/2 nguồn'), findsOneWidget);
        await tester.tap(find.text('Hủy tìm kiếm'));
        await tester.pump();
        held.complete([target(1)]);
        await tester.pumpAndSettle();
        expect(find.widgetWithText(ListTile, 'Truyện 1'), findsNothing);
        expect((await repository.snapshot()).fingerprint, before);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }
}
