import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tachi_books/features/library/application/backup_source_availability.dart';
import 'package:tachi_books/features/library/data/backup_service.dart';
import 'package:tachi_books/features/library/data/library_snapshot.dart';
import 'package:tachi_books/features/library/domain/library_book.dart';
import 'package:tachi_books/features/library/presentation/library_view_model.dart';
import 'package:tachi_books/features/settings/presentation/backup_settings_screen.dart';
import 'package:tachi_books/features/sources/data/source_repository.dart';
import 'package:tachi_books/features/sources/domain/catalogue.dart';

const largeId = '9223372036854775001';

LibrarySnapshot snapshot(List<LibraryBook> books) =>
    LibrarySnapshot([for (final book in books) LibrarySnapshotEntry(book, {})]);

LibraryBook remote(
  String id,
  String sourceId, {
  String engine = 'tachimanga',
}) => LibraryBook(
  id: id,
  title: 'Truyện $id',
  engine: engine,
  sourceId: sourceId,
);

CatalogueSource source(String id, SourceEngine engine) => CatalogueSource(
  id: id,
  name: 'Nguồn mẫu $id',
  lang: 'vi',
  baseUrl: 'https://source.invalid',
  kind: ContentKind.manga,
  engine: engine,
);

BackupPreview preview(LibrarySnapshot value, {int additions = 1}) =>
    BackupPreview(
      format: 'TachiBooks',
      snapshot: value,
      warnings: const [],
      expectedFingerprint: 'unchanged-restore-fingerprint',
      additions: additions,
    );

class InventoryRepository extends SourceRepository {
  InventoryRepository(this.inventory) : super(tachimangaUrl: '', vbookUrl: '');
  final Future<List<CatalogueSource>> Function(SourceEngine) inventory;
  @override
  Future<List<CatalogueSource>> listSources(SourceEngine engine) =>
      inventory(engine);
}

void main() {
  test('exact engine and 64-bit source identities; unique groups and immutable backup', () async {
    final value = snapshot([
      remote('a', largeId),
      remote('b', largeId),
      remote('c', largeId, engine: 'vbook'),
      remote('d', '9223372036854775002'),
      LibraryBook(id: 'local', title: 'EPUB cục bộ'),
    ]);
    final before = value.encode();
    final calls = <SourceEngine>[];
    final result = await checkBackupSourceAvailability(value, (engine) async {
      calls.add(engine);
      return engine == SourceEngine.tachimanga
          ? [source(largeId, engine)]
          : [source(largeId, SourceEngine.tachimanga)];
    });
    expect(calls.toSet(), SourceEngine.values.toSet());
    expect(result.sources.length, 3);
    expect(result.availableCount, 1);
    expect(result.sources.first.bookTitles, ['Truyện a', 'Truyện b']);
    expect(result.sources.first.sourceName, 'Nguồn mẫu $largeId');
    expect(result.missing.map((source) => source.identity), [
      'vbook:$largeId',
      'tachimanga:9223372036854775002',
    ]);
    expect(result.unverified, isEmpty);
    expect(value.encode(), orderedEquals(before));
  });

  test(
    'local backups query no engine; one failed engine does not hide another',
    () async {
      final local = await checkBackupSourceAvailability(
        snapshot([LibraryBook(id: 'local', title: 'TXT')]),
        (_) => throw StateError('Local restore must not query engines'),
      );
      expect(local.sources, isEmpty);
      final result = await checkBackupSourceAvailability(
        snapshot([
          remote('a', largeId),
          remote('b', 'plugin', engine: 'vbook'),
        ]),
        (engine) async => engine == SourceEngine.tachimanga
            ? throw StateError('No engine')
            : [source('plugin', engine)],
      );
      expect(result.availableCount, 1);
      expect(result.missing, isEmpty);
      expect(result.unverified.single.identity, 'tachimanga:$largeId');
    },
  );

  test(
    'timeout cannot be reported as missing or block future restore',
    () async {
      final result = await checkBackupSourceAvailability(
        snapshot([remote('a', largeId)]),
        (_) => Completer<List<CatalogueSource>>().future,
        timeout: const Duration(milliseconds: 1),
      );
      expect(result.missing, isEmpty);
      expect(result.unverified.single.sourceId, largeId);
    },
  );

  testWidgets(
    'preview uses configured source repository and shows missing titles',
    (tester) async {
      final repository = InventoryRepository(
        (engine) async =>
            engine == SourceEngine.tachimanga ? [source(largeId, engine)] : [],
      );
      addTearDown(repository.dispose);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [sourceRepositoryProvider.overrideWithValue(repository)],
          child: MaterialApp(
            home: BackupPreviewScreen(
              preview: preview(
                snapshot([
                  remote('a', largeId),
                  remote('b', 'missing', engine: 'vbook'),
                ]),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.text('1 nguồn đã có · 1 nguồn thiếu · 0 nguồn chưa xác minh'),
        findsOneWidget,
      );
      expect(find.text('Thiếu nguồn · vBook · missing'), findsOneWidget);
      expect(find.text('1 truyện: Truyện b'), findsOneWidget);
      expect(find.textContaining('không cản khôi phục'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'failed inventory stays unverified; restore remains available offline',
    (tester) async {
      final value = preview(snapshot([remote('a', largeId)]));
      BackupRestoreChoice? result;
      final repository = InventoryRepository(
        (_) => Future.error(StateError('secret engine URL')),
      );
      addTearDown(repository.dispose);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [sourceRepositoryProvider.overrideWithValue(repository)],
          child: MaterialApp(
            home: Builder(
              builder: (context) => TextButton(
                onPressed: () async {
                  result = await Navigator.push<BackupRestoreChoice>(
                    context,
                    MaterialPageRoute(
                      builder: (_) => BackupPreviewScreen(preview: value),
                    ),
                  );
                },
                child: const Text('Mở'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Mở'));
      await tester.pumpAndSettle();
      expect(
        find.text('0 nguồn đã có · 0 nguồn thiếu · 1 nguồn chưa xác minh'),
        findsOneWidget,
      );
      expect(find.textContaining('Engine chưa trả'), findsOneWidget);
      expect(find.textContaining('secret engine URL'), findsNothing);
      await tester.scrollUntilVisible(find.text('Khôi phục 1 sách mới'), 100);
      await tester.tap(find.text('Khôi phục 1 sách mới'));
      await tester.pumpAndSettle();
      expect(result?.restoreConfiguration, false);
      expect(value.expectedFingerprint, 'unchanged-restore-fingerprint');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'late check from a replaced preview cannot overwrite current result',
    (tester) async {
      final first = Completer<BackupSourceAvailability>();
      final old = preview(snapshot([remote('old', 'old-source')]));
      final latest = preview(
        snapshot([remote('new', 'new-source')]),
        additions: 2,
      );
      Future<BackupSourceAvailability> checker(LibrarySnapshot value) =>
          identical(value, old.snapshot)
          ? first.future
          : checkBackupSourceAvailability(value, (_) async => []);
      Widget build(BackupPreview value) => MaterialApp(
        home: BackupPreviewScreen(
          key: const ValueKey('same-preview'),
          preview: value,
          sourceAvailabilityChecker: checker,
        ),
      );
      await tester.pumpWidget(build(old));
      await tester.pump();
      expect(find.text('Đang kiểm tra danh sách nguồn…'), findsOneWidget);
      await tester.pumpWidget(build(latest));
      await tester.pumpAndSettle();
      first.complete(
        await checkBackupSourceAvailability(old.snapshot, (_) async => []),
      );
      await tester.pumpAndSettle();
      expect(
        find.text('Thiếu nguồn · Tachimanga · new-source'),
        findsOneWidget,
      );
      expect(find.textContaining('old-source'), findsNothing);
      await tester.scrollUntilVisible(find.text('Khôi phục 2 sách mới'), 100);
      expect(find.text('Khôi phục 2 sách mới'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
