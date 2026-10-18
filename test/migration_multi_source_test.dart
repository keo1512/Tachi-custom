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
  testWidgets(
    'cancelled migration page cannot close a source from a late result',
    (tester) async {
      final repository = MemoryLibraryRepository();
      await repository.save(
        LibraryBook(
          id: 'old',
          title: 'Tên cũ',
          engine: 'vbook',
          sourceId: 'old',
        ),
      );
      final pending = Completer<List<CatalogueBook>>();
      var calls = 0;
      final sources = Sources((s) async {
        calls++;
        if (calls == 2) return pending.future;
        return CataloguePage([target(1)], hasNextPage: calls == 1);
      });
      addTearDown(sources.dispose);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            libraryRepositoryProvider.overrideWithValue(repository),
            sourceRepositoryProvider.overrideWithValue(sources),
          ],
          child: MaterialApp(
            home: SourceMigrationScreen(bookId: 'old', source: source(1)),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Tải thêm'));
      await tester.pump();
      expect(calls, 2);
      await tester.tap(find.text('Hủy tìm kiếm'));
      await tester.pump();
      pending.complete(CataloguePage([], hasNextPage: false));
      await tester.pumpAndSettle();
      expect(find.text('Tải thêm'), findsOneWidget);
      await tester.tap(find.text('Tải thêm'));
      await tester.pumpAndSettle();
      expect(calls, 3);
      expect(find.text('Tải thêm'), findsNothing);
      expect(find.widgetWithText(ListTile, 'Truyện 1'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  testWidgets(
    'mixed migration sources request more only from unfinished sources',
    (tester) async {
      final repository = MemoryLibraryRepository();
      await repository.save(
        LibraryBook(
          id: 'old',
          title: 'Tên cũ',
          engine: 'vbook',
          sourceId: 'old',
        ),
      );
      final requests = <String, int>{};
      final sources = Sources((s) async {
        final count = requests.update(
          s.id,
          (count) => count + 1,
          ifAbsent: () => 1,
        );
        return CataloguePage([
          target(int.parse(s.id)),
        ], hasNextPage: s.id == '2' && count == 1);
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
      await tester.pumpAndSettle();
      expect(requests, {'1': 1, '2': 1});
      await tester.tap(find.text('Tải thêm'));
      await tester.pumpAndSettle();
      expect(requests, {'1': 1, '2': 2});
      expect(find.text('Tải thêm'), findsNothing);
      expect(find.widgetWithText(ListTile, 'Truyện 1'), findsOneWidget);
      expect(find.widgetWithText(ListTile, 'Truyện 2'), findsOneWidget);
      // Submitting another query resets the set of eligible source identities.
      await tester.enterText(find.byType(TextField), 'Tên khác');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(requests, {'1': 2, '2': 3});
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  test('multi-source migration retains explicit page flags without inventing metadata for legacy results or errors', () async {
    final repository = Sources((s) async {
      if (s.id == '1') return CataloguePage([target(1)], hasNextPage: false);
      if (s.id == '2') return CataloguePage([], hasNextPage: true);
      if (s.id == '3') return [target(3)];
      throw StateError('Fixture error');
    });
    addTearDown(repository.dispose);
    final result = (await MigrationSearch(repository)
        .search([for (var id = 1; id <= 4; id++) source(id)], 'Tên'))!;
    expect(result.results[0].hasNextPage, false);
    expect(result.results[1].hasNextPage, true);
    expect(result.results[1].books, isEmpty);
    expect(result.results[2].hasNextPage, isNull);
    expect(result.results[3].hasNextPage, isNull);
    expect(result.results[3].error, contains('Fixture error'));
  });
  for (final finalFlag in [false, true, null]) {
    testWidgets(
      'migration page control honors $finalFlag and legacy nonempty fallback',
      (tester) async {
        final repository = MemoryLibraryRepository();
        await repository.save(
          LibraryBook(
            id: 'old',
            title: 'Tên cũ',
            engine: 'vbook',
            sourceId: 'old',
          ),
        );
        var count = 0;
        final sources = Sources((s) async {
          count++;
          if (count > 1) return CataloguePage([], hasNextPage: false);
          return finalFlag == null
              ? [target(1)]
              : CataloguePage([target(1)], hasNextPage: finalFlag);
        });
        addTearDown(sources.dispose);
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              libraryRepositoryProvider.overrideWithValue(repository),
              sourceRepositoryProvider.overrideWithValue(sources),
            ],
            child: MaterialApp(
              home: SourceMigrationScreen(bookId: 'old', source: source(1)),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          find.text('Tải thêm'),
          finalFlag == false ? findsNothing : findsOneWidget,
        );
        if (finalFlag != false) {
          await tester.tap(find.text('Tải thêm'));
          await tester.pumpAndSettle();
          expect(find.text('Tải thêm'), findsNothing);
          expect(find.widgetWithText(ListTile, 'Truyện 1'), findsOneWidget);
        }
        expect(count, finalFlag == false ? 1 : 2);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }
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
