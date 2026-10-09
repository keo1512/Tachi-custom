import 'dart:typed_data';

import 'backup_compatibility/backup_reader.dart';
import 'backup_validation.dart';
import 'library_repository.dart';
import 'library_snapshot.dart';

class BackupService {
  BackupService(this.repository);
  final LibraryRepository repository;
  static const maxBackupBytes = LibrarySnapshot.maxBytes;

  Future<Uint8List> export() async {
    final bytes = (await repository.snapshot()).encode();
    // Never emit a backup that this version cannot validate and restore.
    _validate(bytes);
    return bytes;
  }

  void validate(Uint8List bytes) => _validate(bytes);

  String fingerprint(Uint8List bytes) =>
      LibrarySnapshot(_validate(bytes)).fingerprint;

  Future<void> replace(
    Uint8List bytes, {
    required String expectedFingerprint,
  }) async {
    final incoming = LibrarySnapshot(_validate(bytes));
    await repository.replaceSnapshot(
      incoming,
      expectedFingerprint: expectedFingerprint,
    );
  }

  Future<Uint8List?> exportRecovery() async {
    final bytes = await repository.recoverySnapshot();
    if (bytes != null) validate(bytes);
    return bytes;
  }

  Future<int> merge(Uint8List bytes) async {
    return mergePreview(await preview(bytes));
  }

  Future<BackupPreview> preview(Uint8List bytes) async {
    final converted = await readCompatibleBackup(bytes, repository);
    final current = await repository.snapshot();
    final ids = current.entries.map((entry) => entry.book.id).toSet();
    return BackupPreview(
      format: converted.format,
      snapshot: converted.snapshot,
      warnings: List.unmodifiable(converted.warnings),
      expectedFingerprint: current.fingerprint,
      additions: converted.snapshot.entries
          .where((entry) => !ids.contains(entry.book.id))
          .length,
    );
  }

  Future<int> mergePreview(BackupPreview preview) async {
    _validate(preview.snapshot.encode());
    final current = await repository.snapshot();
    if (current.fingerprint != preview.expectedFingerprint) {
      throw StateError(
        'Thư viện đã thay đổi sau khi xem trước. Hãy chọn lại bản sao lưu.',
      );
    }
    final ids = current.entries.map((entry) => entry.book.id).toSet();
    final additions = preview.snapshot.entries
        .where((entry) => !ids.contains(entry.book.id))
        .toList();
    if (additions.isEmpty) return 0;
    // A single CAS transaction replaces the combined image. Existing metadata,
    // caches and attachment bytes are retained; a failure exposes no partial books.
    final combined = LibrarySnapshot([...current.entries, ...additions]);
    combined.encode();
    await repository.replaceSnapshot(
      combined,
      expectedFingerprint: preview.expectedFingerprint,
    );
    return additions.length;
  }

  List<LibrarySnapshotEntry> _validate(Uint8List bytes) =>
      BackupValidator(repository).validate(bytes);
}

class BackupPreview {
  const BackupPreview({
    required this.format,
    required this.snapshot,
    required this.warnings,
    required this.expectedFingerprint,
    required this.additions,
  });
  final String format, expectedFingerprint;
  final LibrarySnapshot snapshot;
  final List<String> warnings;
  final int additions;
  int get books => snapshot.entries.length;
  int get cachedChapters => snapshot.entries.fold<int>(
    0,
    (total, entry) => total + entry.contents.length,
  );
}
