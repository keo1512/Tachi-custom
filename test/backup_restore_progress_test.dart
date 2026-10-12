import 'package:flutter_test/flutter_test.dart';
import 'package:tachi_books/features/library/data/backup_restore_progress.dart';
import 'package:tachi_books/features/library/data/backup_service.dart';
import 'package:tachi_books/features/library/data/library_repository.dart';
import 'package:tachi_books/features/library/domain/library_book.dart';

void main() {
  Future<BackupPreview> preview(BackupService service) async {
    final source = MemoryLibraryRepository();
    for (var i = 0; i < 3; i++) {
      await source.save(LibraryBook(id: 'new$i', title: 'Mới $i'));
    }
    return service.preview(await BackupService(source).export());
  }

  test('preparation emits real book counts before one atomic commit', () async {
    final target = MemoryLibraryRepository();
    final service = BackupService(target);
    final incoming = await preview(service);
    final events = <BackupRestoreProgress>[];
    expect(await service.mergePreview(incoming, onProgress: events.add), 3);
    expect(
      events
          .where((p) => p.stage == BackupRestoreStage.preparing)
          .map((p) => p.completedBooks),
      [0, 1, 2, 3],
    );
    expect(
      events
          .where((p) => p.stage == BackupRestoreStage.preparing)
          .every((p) => p.totalBooks == 3),
      true,
    );
    expect(events.last.stage, BackupRestoreStage.completed);
    expect((await target.list()).length, 3);
    expect(await target.recoverySnapshot(), isNotNull);
  });

  test(
    'cancel during per-title preparation leaves library and recovery untouched',
    () async {
      final target = MemoryLibraryRepository();
      await target.save(
        LibraryBook(id: 'old', title: 'Giữ nguyên', notes: 'Private'),
      );
      final service = BackupService(target);
      final incoming = await preview(service);
      final before = (await target.snapshot()).fingerprint;
      final cancellation = BackupRestoreCancellation();
      await expectLater(
        service.mergePreview(
          incoming,
          cancellation: cancellation,
          onProgress: (progress) {
            if (progress.stage == BackupRestoreStage.preparing &&
                progress.completedBooks == 1) {
              cancellation.cancel();
            }
          },
        ),
        throwsA(isA<BackupRestoreCancelled>()),
      );
      expect((await target.snapshot()).fingerprint, before);
      expect(await target.recoverySnapshot(), isNull);
    },
  );

  test(
    'edit during progress is rejected by final CAS without losing the edit',
    () async {
      final target = MemoryLibraryRepository();
      await target.save(LibraryBook(id: 'old', title: 'Cũ'));
      final service = BackupService(target);
      final incoming = await preview(service);
      await expectLater(
        service.mergePreview(
          incoming,
          onProgress: (progress) {
            if (progress.stage == BackupRestoreStage.preparing &&
                progress.completedBooks == 1) {
              target.mutateBook(
                'old',
                (book) => book.copyWith(notes: 'New edit'),
              );
            }
          },
        ),
        throwsStateError,
      );
      expect((await target.find('old'))!.notes, 'New edit');
      expect((await target.list()).length, 1);
      expect(await target.recoverySnapshot(), isNull);
    },
  );

  test('cancel or throwing detached observer after commit begins does not report a failed atomic write', () async {
    final target = MemoryLibraryRepository();
    final service = BackupService(target);
    final incoming = await preview(service);
    final cancellation = BackupRestoreCancellation();
    expect(
      await service.mergePreview(
        incoming,
        cancellation: cancellation,
        onProgress: (progress) {
          if (!progress.canCancel) {
            cancellation.cancel();
            throw StateError('Detached UI');
          }
        },
      ),
      3,
    );
    expect((await target.list()).length, 3);
  });
}
