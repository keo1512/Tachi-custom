import 'package:flutter_test/flutter_test.dart';
import 'package:tachi_books/features/library/application/library_diagnostics.dart';
import 'package:tachi_books/features/library/data/library_repository.dart';
import 'package:tachi_books/features/library/data/library_snapshot.dart';
import 'package:tachi_books/features/library/domain/library_book.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('safe proposal fixes finite reading/index/offline metadata, preserves contents and recovery, verifies committed image', () async {
    final repo = MemoryLibraryRepository();
    await repo.save(
      LibraryBook(
        id: 'a',
        title: 'A',
        kind: 'manga',
        notes: 'Private notes',
        sourceId: '9223372036854775807',
        sourceRef: '/opaque',
        chapters: const [
          BookChapter(
            id: 'c',
            title: 'C',
            index: 0,
            downloaded: true,
            read: true,
          ),
        ],
        currentChapter: 7,
        progress: 1.5,
        completed: true,
        bookmarks: ['00:0.25', '0:0.25'],
        readerPreferences: {'future': 'kept'},
      ),
    );
    await repo.saveChapter(
      'a',
      0,
      ReaderContent(kind: 'manga', images: ['https://example.test/page.jpg']),
    );
    await repo.save(
      LibraryBook(
        id: 'b',
        title: 'B',
        chapters: const [
          BookChapter(id: 'c2', title: 'C2', index: 3, downloaded: true),
        ],
      ),
    );
    final original = await repo.snapshot();
    final diagnostics = LibraryDiagnostics(repo);
    final preview = await diagnostics.inspect();
    expect(preview.canRepair, true);
    expect(preview.repairSummary.incompleteDownloads, 1);
    expect(preview.repairSummary.chapterIndexes, 1);
    expect(preview.repairSummary.readingLocations, 1);
    final result = await diagnostics.repair(preview);
    expect(result.verified, true);
    expect(result.recoveryAvailable, true);
    expect(await repo.recoverySnapshot(), original.encode());
    final saved = (await repo.find('a'))!;
    expect(saved.currentChapter, 0);
    expect(saved.progress, 0);
    expect(saved.bookmarks, ['0:0.25']);
    expect(saved.notes, 'Private notes');
    expect(saved.sourceId, '9223372036854775807');
    expect(saved.readerPreferences, {'future': 'kept'});
    expect(saved.chapters.single.read, true);
    expect((await repo.readChapter('a', 0))!.images, [
      'https://example.test/page.jpg',
    ]);
    expect(result.reportAfterRepair.validationError, isNull);
    expect(result.reportAfterRepair.repairSummary.hasChanges, false);
  });
  test('ambiguous index and invalid bookmark are reported, never silently discarded', () async {
    for (final book in [
      LibraryBook(
        id: 'b',
        title: 'B',
        chapters: const [BookChapter(id: 'c', title: 'C', index: 1)],
        progress: .5,
      ),
      LibraryBook(
        id: 'b',
        title: 'B',
        chapters: const [BookChapter(id: 'c', title: 'C', index: 0)],
        bookmarks: ['7:0.5'],
      ),
    ]) {
      final repo = MemoryLibraryRepository();
      await repo.save(book);
      final original = (await repo.snapshot()).fingerprint;
      final diagnostics = LibraryDiagnostics(repo);
      final report = await diagnostics.inspect();
      expect(report.canRepair, false);
      expect(report.repairBlockedReason, isNotNull);
      await expectLater(diagnostics.repair(report), throwsStateError);
      expect((await repo.snapshot()).fingerprint, original);
      expect(await repo.recoverySnapshot(), isNull);
    }
  });
  test('hidden orphan cache blocks repair/export and stays readable by its original key', () async {
    final repo = MemoryLibraryRepository();
    await repo.saveChapter(
      'orphan',
      0,
      ReaderContent(kind: 'novel', html: 'keep bytes'),
    );
    await expectLater(repo.snapshot(), throwsFormatException);
    final report = await LibraryDiagnostics(repo).inspect();
    expect(report.storageUnreadable, true);
    await expectLater(
      LibraryDiagnostics(repo).repair(report),
      throwsStateError,
    );
    expect((await repo.readChapter('orphan', 0))!.html, 'keep bytes');
  });
  test('recovery write failure does not change data; postcommit read failure never announces verified success', () async {
    for (final repo in [_FailRepair(), _FailVerification()]) {
      await repo.save(
        LibraryBook(
          id: 'b',
          title: 'B',
          chapters: const [
            BookChapter(id: 'c', title: 'C', index: 0, downloaded: true),
          ],
        ),
      );
      final diagnostics = LibraryDiagnostics(repo);
      final report = await diagnostics.inspect();
      await expectLater(diagnostics.repair(report), throwsA(isA<Exception>()));
      if (repo is _FailRepair) {
        expect((await repo.find('b'))!.chapters.single.downloaded, true);
        expect(await repo.recoverySnapshot(), isNull);
      } else {
        expect((await repo.find('b'))!.chapters.single.downloaded, false);
        expect(await repo.recoverySnapshot(), isNotNull);
      }
    }
  });
}

class _FailRepair extends MemoryLibraryRepository {
  @override
  Future<void> replaceSnapshot(
    LibrarySnapshot incoming, {
    required String expectedFingerprint,
  }) async => throw const FormatException('Không ghi được bản phục hồi.');
}

class _FailVerification extends MemoryLibraryRepository {
  bool changed = false;
  @override
  Future<void> replaceSnapshot(
    LibrarySnapshot incoming, {
    required String expectedFingerprint,
  }) async {
    await super.replaceSnapshot(
      incoming,
      expectedFingerprint: expectedFingerprint,
    );
    changed = true;
  }

  @override
  Future<LibrarySnapshot> snapshot() async {
    if (changed) throw const FormatException('Không đọc được kết quả.');
    return super.snapshot();
  }
}
