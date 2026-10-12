import 'dart:convert';
import 'dart:ffi' show Abi;
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:isar_community/isar.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tachi_books/features/library/application/book_cover_import.dart';
import 'package:tachi_books/features/library/data/backup_validation.dart';
import 'package:tachi_books/features/library/data/library_repository.dart';
import 'package:tachi_books/features/library/data/library_snapshot.dart';
import 'package:tachi_books/features/library/domain/library_book.dart';
import 'package:tachi_books/features/library/domain/library_search.dart';
import 'package:tachi_books/features/library/presentation/book_metadata_editor.dart';
import 'package:tachi_books/features/library/presentation/library_view_model.dart';
import 'package:tachi_books/features/settings/settings_controller.dart';
import 'package:tachi_books/features/sources/data/source_repository.dart';
import 'package:tachi_books/features/sources/domain/catalogue.dart';

const image =
    'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'legacy metadata defaults remain compatible and aliases are searched',
    () {
      final old = LibraryBook(id: 'b', title: 'Original');
      final restored = LibraryBook.fromJson(old.toJson());
      expect(restored.alternativeTitles, isEmpty);
      expect(restored.customCover, isFalse);
      expect(restored.originalCover, isEmpty);
      final named = restored.copyWith(
        alternativeTitles: ['Tên tiếng Việt', 'English name'],
      );
      expect(LibrarySearch('tiếng Việt').matches(named), isTrue);
      expect(LibrarySearch('title:"english name"').matches(named), isTrue);
      expect(LibraryBook.fromJson(named.toJson()).toJson(), named.toJson());
    },
  );
  test(
    'backup rejects invalid aliases or original cover before storage changes',
    () async {
      final repo = MemoryLibraryRepository();
      final backup = LibrarySnapshot([
        LibrarySnapshotEntry(
          LibraryBook(id: 'b', title: 'B', alternativeTitles: ['A', 'B']),
          {},
        ),
      ]);
      final validator = BackupValidator(repo);
      expect(
        validator
            .validateSnapshot(backup.encode())
            .entries
            .single
            .book
            .alternativeTitles,
        ['A', 'B'],
      );
      for (final names in [
        <String>['a', 'b', 'c'],
        <String>['same', 'same'],
        <String>[''],
      ]) {
        final invalid = LibrarySnapshot([
          LibrarySnapshotEntry(
            backup.entries.single.book.copyWith(alternativeTitles: names),
            {},
          ),
        ]);
        expect(
          () => validator.validateSnapshot(invalid.encode()),
          throwsFormatException,
        );
      }
      final invalid = LibrarySnapshot([
        LibrarySnapshotEntry(
          backup.entries.single.book.copyWith(
            originalCover: 'file:///private/nope',
          ),
          {},
        ),
      ]);
      expect(
        () => validator.validateSnapshot(invalid.encode()),
        throwsFormatException,
      );
      expect(await repo.list(), isEmpty);
    },
  );
  test('custom cover retains original, survives metadata refresh and restores latest source cover', () async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    final repository = MemoryLibraryRepository();
    final book = LibraryBook(
      id: 'b',
      title: 'Old',
      engine: 'tachimanga',
      sourceId: '9223372036854775806',
      sourceRef: '/book',
      alternativeTitles: ['Alias'],
      cover: image,
      notes: 'Private',
      bookmarks: ['0:0.25'],
      progress: .5,
      chapters: const [
        BookChapter(
          id: '/chapter',
          title: 'C',
          index: 0,
          downloaded: true,
          read: true,
        ),
      ],
    );
    await repository.save(book);
    await repository.saveChapter(
      'b',
      0,
      ReaderContent(kind: 'novel', html: '<p>Offline</p>'),
    );
    final source = _MetadataSource();
    final container = ProviderContainer(
      overrides: [
        preferencesProvider.overrideWithValue(preferences),
        libraryRepositoryProvider.overrideWithValue(repository),
        sourceRepositoryProvider.overrideWithValue(source),
      ],
    );
    addTearDown(container.dispose);
    addTearDown(source.dispose);
    await container.read(libraryProvider.future);
    final vm = container.read(libraryProvider.notifier);
    await vm.updateMetadata(
      'b',
      cover: image,
      title: 'Manual',
      alternativeTitles: ['Alias', 'Second'],
    );
    expect((await repository.find('b'))!.originalCover, image);
    await vm.refreshBookDetail('b', refreshChapters: false);
    final refreshed = (await repository.find('b'))!;
    expect(refreshed.customCover, isTrue);
    expect(refreshed.cover, image);
    expect(refreshed.originalCover, 'https://source.example/new.png');
    expect(refreshed.alternativeTitles, ['Alias', 'Second']);
    expect(refreshed.sourceId, book.sourceId);
    expect(refreshed.notes, book.notes);
    expect(refreshed.progress, book.progress);
    expect(refreshed.bookmarks, book.bookmarks);
    expect(refreshed.chapters.single.downloaded, isTrue);
    expect((await repository.readChapter('b', 0))!.html, '<p>Offline</p>');
    await vm.updateMetadata('b', restoreOriginalCover: true);
    final restored = (await repository.find('b'))!;
    expect(restored.customCover, isFalse);
    expect(restored.cover, 'https://source.example/new.png');
    expect(restored.originalCover, isEmpty);
    final restoredFingerprint = (await repository.snapshot()).fingerprint;
    await vm.updateMetadata('b', restoreOriginalCover: true);
    expect((await repository.snapshot()).fingerprint, restoredFingerprint);
  });
  test(
    'image validation rejects fake bytes and preserves selected valid bytes',
    () async {
      await expectLater(
        validateBookCoverBytes(Uint8List.fromList(utf8.encode('not image'))),
        throwsFormatException,
      );
      await expectLater(
        validateBookCoverBytes(Uint8List(LibraryRepository.maxImageBytes + 1)),
        throwsFormatException,
      );
      final bytes = UriData.parse(image).contentAsBytes();
      expect(await validateBookCoverBytes(Uint8List.fromList(bytes)), image);
    },
  );
  test(
    'metadata popup captured before restore cannot overwrite restored data',
    () async {
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      final repo = MemoryLibraryRepository();
      await repo.save(LibraryBook(id: 'b', title: 'Before'));
      final container = ProviderContainer(
        overrides: [
          preferencesProvider.overrideWithValue(preferences),
          libraryRepositoryProvider.overrideWithValue(repo),
        ],
      );
      addTearDown(container.dispose);
      await container.read(libraryProvider.future);
      final revision = repo.replacementRevision;
      final before = await repo.snapshot();
      await repo.replaceSnapshot(
        LibrarySnapshot([
          LibrarySnapshotEntry(
            LibraryBook(
              id: 'b',
              title: 'Restored',
              alternativeTitles: ['Keep'],
            ),
            {},
          ),
        ]),
        expectedFingerprint: before.fingerprint,
      );
      await expectLater(
        container
            .read(libraryProvider.notifier)
            .updateMetadata(
              'b',
              title: 'Stale',
              alternativeTitles: ['No'],
              cover: image,
              expectedRevision: revision,
            ),
        throwsStateError,
      );
      expect((await repo.find('b'))!.title, 'Restored');
      expect((await repo.find('b'))!.alternativeTitles, ['Keep']);
    },
  );
  for (final width in [320.0, 430.0]) {
    testWidgets(
      'metadata editor shows only two aliases and saves valid names at $width',
      (tester) async {
        await tester.binding.setSurfaceSize(Size(width, 932));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        BookMetadataEdit? result;
        await tester.pumpWidget(
          MaterialApp(
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () async {
                    result = await showBookMetadataEditor(
                      context,
                      LibraryBook(id: 'b', title: 'Original'),
                    );
                  },
                  child: const Text('Open'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Open'));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('metadata-Tên khác 1')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('metadata-Tên khác 2')),
          findsOneWidget,
        );
        expect(find.byKey(const ValueKey('metadata-Tên khác 3')), findsNothing);
        await tester.enterText(
          find.byKey(const ValueKey('metadata-Tên khác 1')),
          ' First ',
        );
        await tester.enterText(
          find.byKey(const ValueKey('metadata-Tên khác 2')),
          'Second',
        );
        await tester.tap(find.text('Lưu'));
        await tester.pumpAndSettle();
        expect(result!.title, 'Original');
        expect(result!.alternativeTitles, ['First', 'Second']);
        expect(tester.takeException(), isNull);
      },
    );
  }
  test('native inline original cover survives full backup and fresh database restore', () async {
    final library = Platform.environment['TACHI_ISAR_TEST_LIBRARY']!;
    await Isar.initializeIsarCore(
      libraries: {Abi.current(): library},
      download: false,
    );
    final firstDirectory = await Directory.systemTemp.createTemp(
      'tachi-cover-first-',
    );
    final secondDirectory = await Directory.systemTemp.createTemp(
      'tachi-cover-second-',
    );
    LibraryRepository? first, second;
    try {
      first = await LibraryRepository.open(directoryPath: firstDirectory.path);
      final book = LibraryBook(
        id: 'b',
        title: 'B',
        alternativeTitles: ['Alias'],
        cover: image,
        originalCover: image,
        customCover: true,
      );
      await first.save(book);
      final snapshot = await first.snapshot();
      expect(snapshot.entries.single.book.originalCover, image);
      final validated = BackupValidator(first)
          .validateSnapshot(snapshot.encode());
      await first.close();
      first = null;
      second = await LibraryRepository.open(
        directoryPath: secondDirectory.path,
      );
      final empty = await second.snapshot();
      await second.replaceSnapshot(
        validated,
        expectedFingerprint: empty.fingerprint,
      );
      expect((await second.find('b'))!.toJson(), book.toJson());
      await second.close();
      second = null;
      second = await LibraryRepository.open(
        directoryPath: secondDirectory.path,
      );
      expect((await second.find('b'))!.originalCover, image);
    } finally {
      await first?.close();
      await second?.close();
      await firstDirectory.delete(recursive: true);
      await secondDirectory.delete(recursive: true);
    }
  }, skip: Platform.environment['TACHI_ISAR_TEST_LIBRARY'] == null);
}

class _MetadataSource extends SourceRepository {
  _MetadataSource()
    : super(
        tachimangaUrl: 'http://localhost:4567',
        vbookUrl: 'http://localhost:4570',
      );
  @override
  Future<CatalogueBook> detail(CatalogueBook book) async => CatalogueBook(
    ref: book.ref,
    title: 'Source title',
    sourceId: book.sourceId,
    kind: book.kind,
    engine: book.engine,
    coverUrl: 'https://source.example/new.png',
  );
}
