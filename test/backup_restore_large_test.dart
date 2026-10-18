import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:tachi_books/features/library/data/backup_restore_progress.dart';
import 'package:tachi_books/features/library/data/backup_service.dart';
import 'package:tachi_books/features/library/data/library_repository.dart';
import 'package:tachi_books/features/library/data/library_snapshot.dart';
import 'package:tachi_books/features/library/domain/library_book.dart';

class _CountingRepository extends MemoryLibraryRepository {
  int validations = 0;

  @override
  void validateBook(LibraryBook book) {
    validations++;
    super.validateBook(book);
  }
}

LibrarySnapshot _library() => LibrarySnapshot([
  for (var i = 0; i < 748; i++)
    LibrarySnapshotEntry(
      LibraryBook(
        id: 'large-$i',
        title: 'Truyện kiểm tra $i',
        kind: 'manga',
        chapters: [
          for (var j = 0; j < (i == 0 ? 1228 : 30); j++)
            BookChapter(id: '/book/$i/$j', title: 'Chương $j', index: j),
        ],
      ),
      {},
    ),
]);

void main() {
  test('cancelling initial validation yields before validating a whole large library', () async {
    final repository = _CountingRepository();
    final service = BackupService(repository);
    final cancellation = BackupRestoreCancellation();
    final incoming = _library();
    final preview = BackupPreview(
      format: 'large test',
      snapshot: incoming,
      warnings: const [],
      expectedFingerprint: (await repository.snapshot()).fingerprint,
      additions: incoming.entries.length,
    );
    Timer? cancel;
    try {
      await expectLater(
        service.mergePreview(
          preview,
          cancellation: cancellation,
          onProgress: (progress) {
            if (progress.stage == BackupRestoreStage.validating) {
              cancel = Timer(Duration.zero, cancellation.cancel);
            }
          },
        ),
        throwsA(isA<BackupRestoreCancelled>()),
      );
      expect(repository.validations, lessThan(incoming.entries.length));
      expect(await repository.list(), isEmpty);
      expect(await repository.recoverySnapshot(), isNull);
    } finally {
      cancel?.cancel();
    }
  });

  test('duplicate preview identities are rejected even when already in the target library', () async {
    final repository = MemoryLibraryRepository();
    final book = LibraryBook(id: 'existing', title: 'Giữ nguyên');
    await repository.save(book);
    final before = (await repository.snapshot()).fingerprint;
    final entry = LibrarySnapshotEntry(book, {});
    final preview = BackupPreview(
      format: 'duplicate test',
      snapshot: LibrarySnapshot([entry, entry]),
      warnings: const [],
      expectedFingerprint: before,
      additions: 0,
    );
    await expectLater(
      BackupService(repository).mergePreview(preview),
      throwsFormatException,
    );
    expect((await repository.snapshot()).fingerprint, before);
    expect(await repository.recoverySnapshot(), isNull);
  });
}
