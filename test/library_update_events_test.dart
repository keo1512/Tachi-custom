import 'dart:convert';
import 'dart:ffi' show Abi;
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:isar_community/isar.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tachi_books/core/theme/app_theme.dart';
import 'package:tachi_books/features/library/data/backup_service.dart';
import 'package:tachi_books/features/library/data/library_mutation.dart';
import 'package:tachi_books/features/library/data/library_repository.dart';
import 'package:tachi_books/features/library/domain/library_book.dart';
import 'package:tachi_books/features/library/domain/library_update_events.dart';
import 'package:tachi_books/features/library/presentation/activity_screens.dart';
import 'package:tachi_books/features/library/presentation/library_view_model.dart';
import 'package:tachi_books/features/settings/settings_controller.dart';
import 'package:tachi_books/features/sources/data/source_repository.dart';

BookChapter _chapter(String id, int index, {DateTime? found, bool? read}) =>
    BookChapter(
      id: id,
      title: 'Chương $id',
      index: index,
      discoveredAt: found,
      read: read,
    );

LibraryBook _book(
  String id,
  List<BookChapter> chapters, {
  String engine = 'vbook',
  List<String> categories = const ['Kệ A'],
}) => LibraryBook(
  id: id,
  title: 'Truyện $id',
  engine: engine,
  sourceId: 'source-$id',
  sourceRef: '/book/$id',
  categories: categories,
  chapters: chapters,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('new chapter events are independent of old unread or release dates', () {
    final found = DateTime.utc(2026, 10, 11, 4);
    final book = _book('a', [
      _chapter(
        'legacy-unread',
        0,
        read: false,
      ).copyWith(uploadedAt: DateTime.utc(2026, 10, 11, 5)),
      _chapter('found-read', 1, found: found, read: true),
      _chapter('found-unread', 2, found: found, read: false),
    ]);
    expect(libraryUpdateEntries([book]).map((e) => e.chapter.id), [
      'found-unread',
      'found-read',
    ]);
    expect(
      libraryUpdateEntries([book], unreadOnly: true).map((e) => e.chapter.id),
      ['found-unread'],
    );
    expect(book.chapters.first.discoveredAt, isNull);
  });

  test('legacy unread view honors explicit and inferred read flags', () {
    final book =
        _book('a', [
          _chapter('inferred-read', 0),
          _chapter('explicit-unread', 1, read: false),
          _chapter('found-unread', 2, found: DateTime.utc(2026, 10, 11)),
          _chapter('explicit-read', 3, read: true),
        ]).copyWith(
          currentChapter: 2,
          progress: .5,
          lastRead: DateTime.utc(2026, 10, 10),
        );
    expect(
      libraryUpdateEntries([
        book,
      ], includeExistingUnread: true).map((e) => e.chapter.id),
      ['found-unread', 'explicit-unread'],
    );
  });

  test(
    'category membership filters events and refresh IDs without local books',
    () {
      final found = DateTime.utc(2026, 10, 11);
      final books = [
        _book(
          'both',
          [_chapter('a', 0, found: found)],
          categories: ['Kệ B', 'Kệ A'],
        ),
        _book(
          'outside',
          [_chapter('b', 0, found: found)],
          categories: ['Kệ B'],
        ),
        _book('local', [_chapter('c', 0, found: found)], engine: 'local'),
      ];
      expect(updateCategoryBookIds(books, 'Kệ A'), ['both']);
      expect(updateCategoryBookIds(books, null), ['both', 'outside']);
      expect(
        libraryUpdateEntries(books, category: 'Kệ A').single.book.id,
        'both',
      );
      expect(libraryUpdateEntries(books, category: 'missing'), isEmpty);
    },
  );

  test(
    'events sort by discovered instant then stable book and chapter order',
    () {
      final earlier = DateTime.utc(2026, 10, 10, 12);
      final later = DateTime.utc(2026, 10, 11, 12);
      final entries = libraryUpdateEntries([
        _book('z', [
          _chapter('z-old', 0, found: earlier),
          _chapter('z-new', 1, found: later),
        ]),
        _book('a', [
          _chapter('a-old', 0),
          _chapter('a-new-1', 1, found: later),
          _chapter('a-new-2', 2, found: later),
        ]),
      ], includeExistingUnread: true);
      expect(entries.map((e) => e.chapter.id), [
        'a-new-2',
        'a-new-1',
        'z-new',
        'z-old',
        'a-old',
      ]);
      expect(entries.first.index, 2);
      expect(discoveredDateLabel(null), 'Chưa có ngày phát hiện');
      final local = later.toLocal();
      expect(
        discoveredDateLabel(later),
        contains('${local.day}/${local.month}/${local.year}'),
      );
    },
  );

  test(
    'reorder preserves first discovery including null for imported chapters',
    () {
      final first = DateTime.utc(2026, 10, 8);
      final refresh = DateTime.utc(2026, 10, 11);
      final book = _book('a', [
        _chapter('legacy', 0, read: false),
        _chapter(
          'known',
          1,
          found: first,
          read: true,
        ).copyWith(downloaded: true),
      ]).copyWith(currentChapter: 1, progress: .75, bookmarks: ['1:0.5000']);
      final result = remapChapterOrder(book, [
        _chapter('new', 0, found: refresh),
        _chapter('known', 1, found: refresh),
        _chapter('legacy', 2, found: refresh),
      ]);
      expect(result.additions, 1);
      expect(result.book.chapters.map((c) => c.discoveredAt), [
        refresh,
        first,
        null,
      ]);
      expect(result.book.chapters.map((c) => c.read), [false, true, false]);
      expect(result.book.chapters.map((c) => c.downloaded), [
        false,
        true,
        false,
      ]);
      expect(result.book.bookmarks, book.bookmarks);
      expect(result.previousIndices, [null, 1, 0]);
    },
  );

  test(
    'portable backup preserves discovery timestamps and legacy absence',
    () async {
      final first = DateTime.utc(2026, 10, 11, 4, 3, 2, 123);
      final repository = MemoryLibraryRepository();
      final book = _book('a', [
        _chapter('legacy', 0),
        _chapter('new', 1, found: first),
      ]);
      await repository.save(book);
      final bytes = await BackupService(repository).export();
      final decoded = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
      final chapters = decoded['entries'][0]['book']['chapters'] as List;
      expect(chapters.first.containsKey('discoveredAt'), false);
      expect(chapters.last['discoveredAt'], first.toIso8601String());
      final restored = MemoryLibraryRepository();
      expect(await BackupService(restored).merge(bytes), 1);
      expect((await restored.find('a'))!.toJson(), book.toJson());
      expect(
        libraryUpdateEntries(await restored.list()).single.chapter.id,
        'new',
      );
    },
  );

  test(
    'invalid discovery data in backup is rejected before modifying library',
    () async {
      final source = MemoryLibraryRepository();
      await source.save(_book('incoming', [_chapter('c', 0)]));
      final envelope = jsonDecode(
        utf8.decode(await BackupService(source).export()),
      ) as Map<String, dynamic>;
      final destination = MemoryLibraryRepository();
      final existing = _book('existing', [_chapter('keep', 0)]);
      await destination.save(existing);
      for (final invalid in ['not-a-date', 17, true]) {
        envelope['entries'][0]['book']['chapters'][0]['discoveredAt'] = invalid;
        await expectLater(
          BackupService(destination)
              .merge(Uint8List.fromList(utf8.encode(jsonEncode(envelope)))),
          throwsA(isA<FormatException>()),
        );
        expect((await destination.list()).single.toJson(), existing.toJson());
      }
    },
  );

  test('refresh stamps only additions and repeat refresh retains the original timestamp', () async {
    final first = DateTime.utc(2026, 10, 8);
    final repo = MemoryLibraryRepository();
    await repo.save(
      _book('a', [_chapter('legacy', 0), _chapter('known', 1, found: first)]),
    );
    final requests = <http.Request>[];
    final client = MockClient((request) async {
      requests.add(request);
      expect(request.url.path, '/v1/sources/source-a/chapters');
      return _json([
        {'ref': 'legacy', 'title': 'Chương legacy', 'index': 0},
        {'ref': 'known', 'title': 'Chương known', 'index': 1},
        {'ref': 'new', 'title': 'Chương new', 'index': 2},
      ]);
    });
    addTearDown(client.close);
    final container = ProviderContainer(
      overrides: [
        preferencesProvider.overrideWithValue(
          await SharedPreferences.getInstance(),
        ),
        libraryRepositoryProvider.overrideWithValue(repo),
        sourceRepositoryProvider.overrideWithValue(
          SourceRepository(
            vbookUrl: 'http://localhost:4570',
            tachimangaUrl: '',
            client: client,
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    await container.read(libraryProvider.future);
    final before = DateTime.now();
    final result = await container.read(libraryProvider.notifier).updateBooks([
      'a',
    ]);
    expect(result.addedChapters, 1);
    expect(result.failures, isEmpty);
    final chapters = (await repo.find('a'))!.chapters;
    expect(chapters[0].discoveredAt, isNull);
    expect(chapters[1].discoveredAt, first);
    final newTimestamp = chapters[2].discoveredAt!;
    expect(newTimestamp.isBefore(before), false);
    expect(newTimestamp.isAfter(DateTime.now()), false);
    final again = await container.read(libraryProvider.notifier).updateBooks([
      'a',
    ]);
    expect(again.addedChapters, 0);
    expect((await repo.find('a'))!.chapters[2].discoveredAt, newTimestamp);
    expect(requests, hasLength(2));
  });

  final isarLibrary = Platform.environment['TACHI_ISAR_TEST_LIBRARY'];
  test(
    'Isar reorder and reopen preserve discovery dates and matching offline bytes',
    () async {
      await Isar.initializeIsarCore(
        libraries: {Abi.current(): isarLibrary!},
        download: false,
      );
      final directory = await Directory.systemTemp.createTemp(
        'tachi-update-events-test-',
      );
      LibraryRepository? repository;
      try {
        repository = await LibraryRepository.open(
          directoryPath: directory.path,
        );
        final known = DateTime.utc(2026, 10, 8),
            added = DateTime.utc(2026, 10, 11);
        final original = _book('native', [
          _chapter('legacy', 0),
          _chapter('known', 1, found: known),
        ]);
        await repository.save(original);
        await repository.saveChapter(
          original.id,
          0,
          ReaderContent(kind: 'novel', html: '<p>Legacy offline bytes</p>'),
        );
        await repository.saveChapter(
          original.id,
          1,
          ReaderContent(kind: 'novel', html: '<p>Known offline bytes</p>'),
        );
        expect(
          await repository.updateChapterOrder(original, [
            _chapter('known', 0, found: added),
            _chapter('new', 1, found: added),
            _chapter('legacy', 2, found: added),
          ], expectedRevision: repository.replacementRevision),
          1,
        );
        await repository.close();
        repository = await LibraryRepository.open(
          directoryPath: directory.path,
        );
        final saved = (await repository.find(original.id))!;
        expect(saved.chapters.map((c) => c.discoveredAt), [known, added, null]);
        expect(
          (await repository.readChapter(original.id, 0))!.html,
          '<p>Known offline bytes</p>',
        );
        expect(await repository.readChapter(original.id, 1), isNull);
        expect(
          (await repository.readChapter(original.id, 2))!.html,
          '<p>Legacy offline bytes</p>',
        );
        expect(libraryUpdateEntries([saved]).map((e) => e.chapter.id), [
          'new',
          'known',
        ]);
        final portable = MemoryLibraryRepository();
        expect(
          await BackupService(portable)
              .merge(await BackupService(repository).export()),
          1,
        );
        expect((await portable.find(original.id))!.toJson(), saved.toJson());
      } finally {
        await repository?.close();
        await directory.delete(recursive: true);
      }
    },
    skip: isarLibrary == null
        ? 'Set TACHI_ISAR_TEST_LIBRARY for native persistence.'
        : false,
  );

  for (final size in const [Size(320, 568), Size(430, 932)]) {
    testWidgets(
      'updates category refresh sends only the selected remote book at $size',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = size;
        addTearDown(tester.view.reset);
        final repo = MemoryLibraryRepository();
        final stamp = DateTime(2026, 10, 11, 12, 30);
        for (final book in [
          _book('selected', [_chapter('old', 0, found: stamp)]),
          _book(
            'outside',
            [_chapter('old', 0, found: stamp)],
            categories: ['Kệ B'],
          ),
          _book('local', [_chapter('old', 0, found: stamp)], engine: 'local'),
        ]) {
          await repo.save(book);
        }
        final requests = <http.Request>[];
        final client = MockClient((request) async {
          requests.add(request);
          expect(request.url.path, '/v1/sources/source-selected/chapters');
          return _json([
            {'ref': 'old', 'title': 'Chương old', 'index': 0},
            {'ref': 'new', 'title': 'Chương new', 'index': 1},
          ]);
        });
        addTearDown(client.close);
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              preferencesProvider.overrideWithValue(
                await SharedPreferences.getInstance(),
              ),
              libraryRepositoryProvider.overrideWithValue(repo),
              sourceRepositoryProvider.overrideWithValue(
                SourceRepository(
                  vbookUrl: 'http://localhost:4570',
                  tachimangaUrl: '',
                  client: client,
                ),
              ),
            ],
            child: MaterialApp(
              theme: appTheme(Brightness.dark),
              home: const UpdatesScreen(),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Tùy chọn cập nhật'));
        await tester.pumpAndSettle();
        await tester.tap(
          find.widgetWithText(CheckedPopupMenuItem<String>, 'Kệ A'),
        );
        await tester.pumpAndSettle();
        expect(find.text('Truyện selected'), findsOneWidget);
        expect(find.text('Truyện outside'), findsNothing);
        expect(find.text('Truyện local'), findsNothing);
        await tester.drag(find.byType(ListView), const Offset(0, 500));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        await tester.pumpAndSettle();
        expect(requests, hasLength(1));
        expect(find.text('Chương new'), findsOneWidget);
        expect(
          find.textContaining('Phát hiện 11/10/2026 12:30'),
          findsOneWidget,
        );
        expect((await repo.find('outside'))!.chapters, hasLength(1));
        expect((await repo.find('local'))!.chapters, hasLength(1));
        await tester.longPress(find.text('Chương new'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Đánh dấu đã đọc'));
        await tester.pumpAndSettle();
        expect((await repo.find('selected'))!.chapters.last.read, true);
        expect(
          (await repo.find('selected'))!.chapters.last.discoveredAt,
          isNotNull,
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      },
    );
  }
}

http.Response _json(Object value) => http.Response(
  jsonEncode(value),
  200,
  headers: {'content-type': 'application/json'},
);
