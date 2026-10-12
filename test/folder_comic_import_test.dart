import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tachi_books/core/theme/app_theme.dart';
import 'package:tachi_books/features/library/data/document_importer.dart';
import 'package:tachi_books/features/library/data/folder_comic_importer.dart';
import 'package:tachi_books/features/library/data/library_repository.dart';
import 'package:tachi_books/features/library/data/local_comic_files_platform.dart';
import 'package:tachi_books/features/library/domain/library_book.dart';
import 'package:tachi_books/features/library/presentation/library_view_model.dart';
import 'package:tachi_books/features/library/presentation/local_comic_library_screen.dart';
import 'package:tachi_books/features/privacy/application/app_lock_controller.dart';
import 'package:tachi_books/features/settings/settings_controller.dart';

final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jf1kAAAAASUVORK5CYII=',
);
Uint8List _json(Map<String, Object> value) =>
    Uint8List.fromList(utf8.encode(jsonEncode(value)));
const _folder = LocalComicFolder(
  'aabbccddeeff00112233445566778899',
  'Tủ truyện',
);

class _Files implements LocalComicFilesPlatform {
  _Files(this.files, {this.location = _folder});
  final Map<String, Uint8List> files;
  final LocalComicFolder location;
  LocalComicFolder? selected;
  bool cancelled = false;
  Future<void> Function()? onConfirm;
  String get digest => sha256
      .convert(
        utf8.encode(
          jsonEncode({
            for (final name in (files.keys.toList()..sort()))
              name: sha256.convert(files[name]!).toString(),
          }),
        ),
      )
      .toString();
  @override
  Future<LocalComicFolder?> current() async => selected;
  @override
  Future<LocalComicFolder?> choose() async =>
      cancelled ? null : (selected = location);
  @override
  Future<void> forget() async => selected = null;
  @override
  Future<LocalComicScan> list(String id) async {
    expect(id, location.id);
    return LocalComicScan(digest, [
      for (final file in files.entries)
        LocalComicFile(file.key, file.value.length, 1),
    ]);
  }

  @override
  Future<Uint8List> read(String id, LocalComicFile file) async =>
      Uint8List.fromList(files[file.path]!);
  @override
  Future<void> confirm(String id, String expected) async {
    if (onConfirm != null) await onConfirm!();
    if (digest != expected) throw StateError('Thư mục thay đổi khi đang quét');
  }

  @override
  Future<Map<String, Uint8List>> extractRar(Uint8List data) async => {
    '1.png': _png,
  };
}

class _OpenLock extends AppLockController {
  @override
  AppLockState build() => const AppLockState(initialized: true);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'folder scan uses natural order details cover and complete offline media',
    () async {
      final files = _Files({
        'Truyện/Chương 10/2.png': _png,
        'Truyện/Chương 2/10.png': _png,
        'Truyện/Chương 2/2.png': _png,
        'Truyện/cover.jpg': _png,
        'Truyện/details.json': _json({
          'title': 'Tên từ details',
          'author': 'Tác giả',
          'series': 'Bộ truyện',
        }),
      });
      final repo = MemoryLibraryRepository();
      final result = await FolderComicImporter(files)
          .scan(_folder, repo, defaultCategories: ['Manga']);
      expect(result.newBooks, 1);
      expect(result.newChapters, 2);
      final book = (await repo.list()).single;
      expect(book.title, 'Tên từ details');
      expect(book.author, 'Tác giả');
      expect(book.series, 'Bộ truyện');
      expect(book.categories, ['Manga']);
      expect(book.chapters.map((c) => c.id), [
        'folder:Chương 2',
        'folder:Chương 10',
      ]);
      expect((await repo.readChapter(book.id, 0))!.images.length, 2);
      expect(book.chapters.every((c) => c.downloaded), true);
      final backup = await repo.snapshot();
      expect(
        utf8.decode(backup.encode()),
        isNot(contains('securityScopedBookmark')),
      );
      final other = MemoryLibraryRepository(),
          empty = await MemoryLibraryRepository().snapshot();
      await other.replaceSnapshot(
        backup,
        expectedFingerprint: empty.fingerprint,
      );
      expect(
        (await other.readChapter(book.id, 1))!.images.single,
        startsWith('data:image/'),
      );
      expect((await other.find(book.id))!.cover, startsWith('data:image/'));
    },
  );

  test('rescan preserves stable progress bookmarks metadata and removed offline chapters', () async {
    final files = _Files({
      'Truyện/Chương 2/1.png': _png,
      'Truyện/Chương 10/1.png': _png,
    });
    final repo = MemoryLibraryRepository(),
        importer = FolderComicImporter(files);
    await importer.scan(_folder, repo);
    final old = (await repo.list()).single;
    await repo.save(
      old.copyWith(
        currentChapter: 1,
        progress: .75,
        bookmarks: ['1:0.5000'],
        notes: 'Giữ ghi chú',
        favorite: true,
        chapters: [
          old.chapters[0].copyWith(read: true),
          old.chapters[1].copyWith(read: false),
        ],
      ),
    );
    files.files.remove('Truyện/Chương 2/1.png');
    files.files['Truyện/Chương 1/1.png'] = _png;
    final result = await importer.scan(_folder, repo);
    expect(result.newBooks, 0);
    expect(result.newChapters, 1);
    expect(result.retainedChapters, 1);
    final book = (await repo.list()).single;
    expect(book.id, old.id);
    expect(book.notes, 'Giữ ghi chú');
    expect(book.favorite, true);
    expect(book.chapters[book.currentChapter].id, 'folder:Chương 10');
    expect(book.bookmarks, ['1:0.5000']);
    final removedIndex = book.chapters.indexWhere(
      (c) => c.id == 'folder:Chương 2',
    );
    expect(book.chapters[removedIndex].read, true);
    expect(await repo.readChapter(book.id, removedIndex), isNotNull);
    files.files.clear();
    final retained = await importer.scan(_folder, repo);
    expect(retained.retainedChapters, 3);
    expect((await repo.list()).single.chapters.length, 3);
  });

  test('folder changes or concurrent library edits reject the staged scan without overwriting', () async {
    final files = _Files({'Truyện/1.png': _png}),
        repo = MemoryLibraryRepository();
    files.onConfirm = () async => files.files['Truyện/2.png'] = _png;
    await expectLater(
      FolderComicImporter(files).scan(_folder, repo),
      throwsStateError,
    );
    expect(await repo.list(), isEmpty);
    expect(await repo.recoverySnapshot(), null);
    files.onConfirm = () async => repo.save(
      LibraryBook(id: 'new-user-edit', title: 'Giữ thao tác người dùng'),
    );
    await expectLater(
      FolderComicImporter(files).scan(_folder, repo),
      throwsStateError,
    );
    expect((await repo.list()).single.id, 'new-user-edit');
  });

  test(
    'invalid metadata paths or cancelled scan do not publish any book',
    () async {
      for (final entries in [
        {'../1.png': _png},
        {
          'Truyện/1.png': _png,
          'Truyện/details.json': _json({'title': 1}),
        },
      ]) {
        final repo = MemoryLibraryRepository();
        await expectLater(
          FolderComicImporter(_Files(entries)).scan(_folder, repo),
          throwsFormatException,
        );
        expect(await repo.list(), isEmpty);
      }
      final repo = MemoryLibraryRepository();
      await expectLater(
        FolderComicImporter(_Files({'1.png': _png}))
            .scan(_folder, repo, isCurrent: () => false),
        throwsStateError,
      );
      expect(await repo.list(), isEmpty);
    },
  );

  test('explicit reconnect after backup restore to another device keeps old book identity and progress', () async {
    final first = MemoryLibraryRepository();
    await FolderComicImporter(_Files({'Truyện/Chương 2/1.png': _png}))
        .scan(_folder, first);
    final saved = (await first.list()).single;
    await first.save(
      saved.copyWith(
        notes: 'Giữ ghi chú',
        favorite: true,
        progress: .6,
        bookmarks: ['0:0.6000'],
        customCover: true,
        originalCover: saved.cover,
        chapters: [saved.chapters.single.copyWith(read: true)],
      ),
    );
    final backup = await first.snapshot();
    final restored = MemoryLibraryRepository(),
        empty = await MemoryLibraryRepository().snapshot();
    await restored.replaceSnapshot(
      backup,
      expectedFingerprint: empty.fingerprint,
    );
    const otherFolder = LocalComicFolder(
      'ffeeddccbbaa99887766554433221100',
      'Máy khác',
    );
    final files = _Files({
      'Truyện/Chương 2/1.png': _png,
      'Truyện/Chương 10/1.png': _png,
    }, location: otherFolder);
    final result = await FolderComicImporter(files).scan(
      otherFolder,
      restored,
      reconnect: {'Truyện': FolderComicReconnect(saved.id, _folder.id)},
    );
    expect(result.newBooks, 0);
    expect(result.newChapters, 1);
    final connected = (await restored.list()).single;
    expect(connected.id, saved.id);
    expect(connected.sourceId, otherFolder.id);
    expect(connected.notes, 'Giữ ghi chú');
    expect(connected.favorite, true);
    expect(connected.customCover, true);
    expect(connected.originalCover, saved.cover);
    expect(
      connected.chapters
          .singleWhere((chapter) => chapter.id == 'folder:Chương 2')
          .read,
      true,
    );
    expect(connected.progress, .3);
    expect(connected.bookmarks, ['0:0.6000']);
    final repeated = await FolderComicImporter(files)
        .scan(otherFolder, restored);
    expect(repeated.newBooks, 0);
    expect(repeated.newChapters, 0);
    expect((await restored.list()).length, 1);
  });

  test('explicit single book folder groups chapter subdirectories with root metadata and cover', () async {
    final files = _Files({
      'Chương 2/1.png': _png,
      'Chương 10/1.png': _png,
      'cover.jpg': _png,
      'details.json': _json({'title': 'Một truyện duy nhất'}),
    });
    final repo = MemoryLibraryRepository();
    await FolderComicImporter(files)
        .scan(_folder, repo, folderIsSingleBook: true);
    final book = (await repo.list()).single;
    expect(book.title, 'Một truyện duy nhất');
    expect(book.sourceRef, '');
    expect(book.chapters.map((chapter) => chapter.id), [
      'folder:Chương 2',
      'folder:Chương 10',
    ]);
    expect((await repo.readChapter(book.id, 0))!.images.length, 1);
    expect(book.cover, startsWith('data:image/'));
  });

  test('reconnect refuses stale source or absent path without changing restored data', () async {
    final repo = MemoryLibraryRepository();
    await FolderComicImporter(_Files({'Truyện/1.png': _png}))
        .scan(_folder, repo);
    final original = (await repo.list()).single,
        before = (await repo.snapshot()).fingerprint;
    const other = LocalComicFolder('ffeeddccbbaa99887766554433221100', 'Khác');
    for (final binding in [
      FolderComicReconnect(original.id, 'wrong-source'),
      FolderComicReconnect('missing', _folder.id),
    ]) {
      await expectLater(
        FolderComicImporter(_Files({'Truyện/1.png': _png}, location: other))
            .scan(other, repo, reconnect: {'Truyện': binding}),
        throwsStateError,
      );
      expect((await repo.snapshot()).fingerprint, before);
    }
    await expectLater(
      FolderComicImporter(_Files({'Khác/1.png': _png}, location: other)).scan(
        other,
        repo,
        reconnect: {'Truyện': FolderComicReconnect(original.id, _folder.id)},
      ),
      throwsStateError,
    );
    expect((await repo.snapshot()).fingerprint, before);
  });

  test('CBZ and RAR chapters in folder share stable archive paths and offline import', () async {
    final zip = Archive()..add(ArchiveFile('1.png', _png.length, _png));
    final files = _Files({
      'Truyện/Chương 2.cbz': Uint8List.fromList(ZipEncoder().encode(zip)),
      'Truyện/Chương 10.cbr': Uint8List.fromList([1, 2, 3]),
    });
    final repo = MemoryLibraryRepository();
    await FolderComicImporter(files).scan(_folder, repo);
    final book = (await repo.list()).single;
    expect(book.chapters.map((c) => c.id), [
      'archive:Chương 2.cbz:',
      'archive:Chương 10.cbr:',
    ]);
    expect(
      (await repo.readChapter(book.id, 1))!.images.single,
      startsWith('data:image/'),
    );
    final direct = MemoryLibraryRepository();
    final imported = await DocumentImporter(extractRar: files.extractRar)
        .import('Truyện.cbr', Uint8List.fromList([1, 2, 3]), direct);
    expect(imported.chapters.single.id, '${imported.id}:0');
    expect(
      (await direct.readChapter(imported.id, 0))!.images.single,
      startsWith('data:image/'),
    );
  });

  for (final width in [320.0, 430.0]) {
    testWidgets(
      'folder picker cancellation select rescan and forget are reachable at $width',
      (tester) async {
        SharedPreferences.setMockInitialValues({});
        final prefs = await SharedPreferences.getInstance(),
            repo = MemoryLibraryRepository(),
            files = _Files({'Truyện/Chương 1/1.png': _png})..cancelled = true;
        final container = ProviderContainer(
          overrides: [
            preferencesProvider.overrideWithValue(prefs),
            libraryRepositoryProvider.overrideWithValue(repo),
            localComicFilesPlatformProvider.overrideWithValue(files),
            appLockProvider.overrideWith(_OpenLock.new),
          ],
        );
        addTearDown(container.dispose);
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = Size(width, 1000);
        addTearDown(tester.view.reset);
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              theme: appTheme(Brightness.dark),
              home: const LocalComicLibraryScreen(),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Chọn thư mục và quét'));
        await tester.pumpAndSettle();
        expect(await repo.list(), isEmpty);
        files.cancelled = false;
        await tester.tap(find.text('Chọn thư mục và quét'));
        await tester.pumpAndSettle();
        expect((await repo.list()).single.chapters.length, 1);
        files.files['Truyện/Chương 2/1.png'] = _png;
        await tester.ensureVisible(find.text('Quét lại chương mới'));
        await tester.tap(find.text('Quét lại chương mới'));
        await tester.pumpAndSettle();
        expect((await repo.list()).single.chapters.length, 2);
        await tester.ensureVisible(find.text('Ngừng theo dõi thư mục'));
        await tester.tap(find.text('Ngừng theo dõi thư mục'));
        await tester.pumpAndSettle();
        expect(files.selected, null);
        expect((await repo.list()).single.chapters.length, 2);
        expect(tester.takeException(), null);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
}
