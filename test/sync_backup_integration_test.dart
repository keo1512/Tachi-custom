import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tachi_books/features/library/data/backup_service.dart';
import 'package:tachi_books/features/library/data/library_repository.dart';
import 'package:tachi_books/features/library/domain/library_book.dart';
import 'package:tachi_books/features/sync/data/backup_sync_local.dart';
import 'package:tachi_books/features/sync/data/sync_link_store.dart';
import 'package:tachi_books/features/sync/domain/sync_engine.dart';

import 'support/sync_fakes.dart';

LibraryBook libraryBook({
  double progress = .1,
  String title = 'Truyện chữ',
}) => LibraryBook(
  id: 'book-1',
  title: title,
  series: 'Bộ truyện',
  progress: progress,
  currentChapter: 1,
  favorite: true,
  bookmarks: ['1:0.5'],
  lastRead: DateTime.utc(2026, 10, 8),
  chapters: const [
    BookChapter(id: 'chapter-a', title: 'Chương 1', index: 0, downloaded: true),
    BookChapter(id: 'chapter-b', title: 'Chương 2', index: 1, downloaded: true),
  ],
);

Future<void> seedLibrary(
  MemoryLibraryRepository repository,
  LibraryBook book, {
  String prefix = 'local',
}) async {
  for (final chapter in book.chapters) {
    await repository.saveChapter(
      book.id,
      chapter.index,
      ReaderContent(
        kind: 'novel',
        html: '<p>$prefix ${chapter.id}</p>',
        headers: const {'Referer': 'https://example.org/'},
      ),
    );
  }
  await repository.save(book);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('cloud choice updates existing books and every cache, keeping an exact full recovery backup', () async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    final repository = MemoryLibraryRepository();
    await seedLibrary(repository, libraryBook());
    final backup = BackupService(repository);
    final original = await backup.export();
    final incomingRepository = MemoryLibraryRepository();
    await seedLibrary(
      incomingRepository,
      libraryBook(progress: .8, title: 'Bản cloud'),
      prefix: 'remote',
    );
    final incoming = await BackupService(incomingRepository).export();
    final remote = FakeSyncRemote()..seed(incoming);
    final engine = SyncEngine(
      uid: 'alice',
      local: BackupSyncLocal(backup: backup, links: SyncLinkStore(preferences)),
      remote: remote,
    );

    expect(await engine.run(enable: true), SyncOutcome.conflict);
    expect((await repository.find('book-1'))!.progress, .1);
    expect(await engine.resolve(keepLocal: false), SyncOutcome.downloaded);
    final restored = (await repository.find('book-1'))!;
    expect(restored.progress, .8);
    expect(restored.title, 'Bản cloud');
    expect(restored.series, 'Bộ truyện');
    expect(restored.bookmarks, ['1:0.5']);
    expect(restored.chapters.map((chapter) => chapter.id), [
      'chapter-a',
      'chapter-b',
    ]);
    expect(
      (await repository.readChapter('book-1', 0))!.html,
      '<p>remote chapter-a</p>',
    );
    expect(
      (await repository.readChapter('book-1', 1))!.html,
      '<p>remote chapter-b</p>',
    );
    expect(
      backup.fingerprint((await backup.exportRecovery())!),
      backup.fingerprint(original),
    );
    expect(
      backup.fingerprint(await backup.export()),
      backup.fingerprint(incoming),
    );
  });

  test('changing cached chapter text alone is detected and uploaded with no metadata-only shortcut', () async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    final repository = MemoryLibraryRepository();
    await seedLibrary(repository, libraryBook());
    final backup = BackupService(repository);
    final remote = FakeSyncRemote();
    final engine = SyncEngine(
      uid: 'alice',
      local: BackupSyncLocal(backup: backup, links: SyncLinkStore(preferences)),
      remote: remote,
    );
    expect(await engine.run(enable: true), SyncOutcome.uploaded);
    final previous = remote.bytes!;
    await repository.saveChapter(
      'book-1',
      1,
      ReaderContent(
        kind: 'novel',
        html: '<p>Nội dung vừa sửa trong cache</p>',
      ),
    );
    remote.nextId = '44444444444444444444444444444444';
    expect(await engine.run(), SyncOutcome.uploaded);
    expect(
      backup.fingerprint(remote.bytes!),
      isNot(backup.fingerprint(previous)),
    );
    final restored = MemoryLibraryRepository();
    await BackupService(restored).merge(remote.bytes!);
    expect(
      (await restored.readChapter('book-1', 1))!.html,
      '<p>Nội dung vừa sửa trong cache</p>',
    );
    expect((await restored.find('book-1'))!.progress, .1);
  });
}
