import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:html/parser.dart' as html_parser;

import '../data/backup_validation.dart';
import '../data/library_mutation.dart';
import '../data/library_repository.dart';
import '../data/library_snapshot.dart';

class LibraryHealthReport {
  const LibraryHealthReport({
    required this.snapshot,
    required this.revision,
    required this.checkedAt,
    required this.missingDownloads,
    this.validationError,
    this.storageUnreadable = false,
    this.damagedCovers = 0,
    this.checkedImages = 0,
    this.unreadableChapters = const [],
    this.repairSummary = const LibraryRepairSummary(),
    this.repairBlockedReason,
  });
  final LibrarySnapshot? snapshot;
  final int revision;
  final DateTime checkedAt;
  final int missingDownloads;
  final String? validationError;
  final bool storageUnreadable;
  final int damagedCovers, checkedImages;
  final List<UnreadableLibraryChapter> unreadableChapters;
  final LibraryRepairSummary repairSummary;
  final String? repairBlockedReason;
  bool get canRepair =>
      snapshot != null &&
      !storageUnreadable &&
      repairBlockedReason == null &&
      repairSummary.hasChanges;
  int get books => snapshot?.entries.length ?? 0;
  int get chapters =>
      snapshot?.entries.fold<int>(0, (n, e) => n + e.book.chapters.length) ?? 0;
  int get cachedChapters =>
      snapshot?.entries.fold<int>(0, (n, e) => n + e.contents.length) ?? 0;
  Uint8List exportSummary() => Uint8List.fromList(
    utf8.encode(
      jsonEncode({
        'schema': 'tachi-books-library-health', 'version': 1,
        'checkedAt': checkedAt.toUtc().toIso8601String(), 'books': books,
        'chapters': chapters, 'cachedChapters': cachedChapters,
        'missingDownloads': missingDownloads,
        'storageUnreadable': storageUnreadable,
        'checkedImages': checkedImages,
        'unreadableCovers': damagedCovers,
        'unreadableChapters': unreadableChapters.length,
        'repair': repairSummary.toJson(),
        'automaticRepair': canRepair ? 'available' : 'unavailable',
        // Never export title/URL/account/cookie or full library contents as logs.
        'validation': validationError == null ? 'passed' : 'failed',
      }),
    ),
  );
}

/// Counts are safe to export; the actual library remains in the recovery file.
class LibraryRepairSummary {
  const LibraryRepairSummary({
    this.missingDownloads = 0,
    this.incompleteDownloads = 0,
    this.chapterIndexes = 0,
    this.readingLocations = 0,
    this.duplicateBookmarks = 0,
    this.canonicalBookmarks = 0,
  });
  final int missingDownloads, incompleteDownloads, chapterIndexes;
  final int readingLocations, duplicateBookmarks, canonicalBookmarks;
  int get total =>
      missingDownloads +
      incompleteDownloads +
      chapterIndexes +
      readingLocations +
      duplicateBookmarks +
      canonicalBookmarks;
  bool get hasChanges => total > 0;
  Map<String, int> toJson() => {
    'missingDownloads': missingDownloads,
    'incompleteDownloads': incompleteDownloads,
    'chapterIndexes': chapterIndexes,
    'readingLocations': readingLocations,
    'duplicateBookmarks': duplicateBookmarks,
    'canonicalBookmarks': canonicalBookmarks,
  };
}

class LibraryRepairResult {
  const LibraryRepairResult({
    required this.summary,
    required this.reportAfterRepair,
    required this.verified,
    required this.recoveryAvailable,
  });
  final LibraryRepairSummary summary;
  final LibraryHealthReport reportAfterRepair;
  final bool verified, recoveryAvailable;
}

class LibraryRepairVerificationException implements Exception {
  const LibraryRepairVerificationException();
  @override
  String toString() =>
      'Đã ghi dữ liệu sửa nhưng chưa xác minh được kết quả. '
      'Bản phục hồi trước khi sửa được giữ nguyên; hãy kiểm tra lại '
      'hoặc khôi phục từ bản sao lưu.';
}

class UnreadableLibraryChapter {
  const UnreadableLibraryChapter({
    required this.bookId,
    required this.bookTitle,
    required this.chapterIndex,
    required this.chapterTitle,
  });
  final String bookId, bookTitle, chapterTitle;
  final int chapterIndex;
}

class LibraryDiagnostics {
  LibraryDiagnostics(this.repository);
  final LibraryRepository repository;
  Future<LibraryHealthReport> inspect({
    void Function(int checked, int total)? onProgress,
  }) async {
    final revision = repository.replacementRevision;
    LibrarySnapshot snapshot;
    try {
      // Native snapshots verify attachment hashes before returning bytes.
      snapshot = await repository.snapshot();
    } catch (_) {
      checkLibraryRevision(repository.replacementRevision, revision);
      return LibraryHealthReport(
        snapshot: null,
        revision: revision,
        checkedAt: DateTime.now(),
        missingDownloads: 0,
        storageUnreadable: true,
        validationError: 'Không đọc được cơ sở dữ liệu hoặc tệp đính kèm. Chưa thay đổi dữ liệu. Hãy khôi phục từ bản sao lưu hợp lệ.',
        repairBlockedReason:
            'Không thể tự sửa khi chưa đọc được toàn bộ dữ liệu. '
            'Hãy khôi phục từ bản sao lưu đã kiểm tra.',
      );
    }
    checkLibraryRevision(repository.replacementRevision, revision);
    final proposal = _proposeRepair(snapshot);
    String? error;
    try {
      BackupValidator(repository).validateSnapshot(snapshot.encode());
    } catch (_) {
      error = 'Định dạng dữ liệu không hợp lệ. Chưa thay đổi thư viện.';
    }
    var damagedCovers = 0, checkedImages = 0, checkedBooks = 0;
    final unreadable = <UnreadableLibraryChapter>[];
    final verified = <String, bool>{};
    Future<bool> image(String value) async {
      if (!value.startsWith('data:image/')) return true;
      final digest = sha256.convert(utf8.encode(value)).toString();
      final previous = verified[digest];
      if (previous != null) return previous;
      checkedImages++;
      var valid = false;
      ui.Codec? codec;
      ui.FrameInfo? frame;
      try {
        final bytes = UriData.parse(value).contentAsBytes();
        if (bytes.isEmpty || bytes.length > LibraryRepository.maxImageBytes) {
          throw const FormatException('Ảnh trống hoặc quá lớn.');
        }
        codec = await ui.instantiateImageCodec(
          Uint8List.fromList(bytes),
          targetWidth: 32,
          targetHeight: 32,
          allowUpscaling: false,
        );
        frame = await codec.getNextFrame();
        valid = frame.image.width > 0 && frame.image.height > 0;
      } catch (_) {
        // Decode failure can also mean this device lacks the image codec.
        // Report unreadable media; never delete or label bytes as repairable.
      } finally {
        frame?.image.dispose();
        codec?.dispose();
      }
      verified[digest] = valid;
      return valid;
    }

    for (final entry in snapshot.entries) {
      checkLibraryRevision(repository.replacementRevision, revision);
      if (!await image(entry.book.cover)) damagedCovers++;
      for (final chapter in entry.contents.entries) {
        var readable = true;
        final content = chapter.value;
        final images = [
          ...content.images,
          for (final img
              in html_parser
                  .parseFragment(content.html)
                  .querySelectorAll('img[src]'))
            img.attributes['src']!,
        ];
        for (final value in images) {
          if (!await image(value)) readable = false;
        }
        if (!readable) {
          unreadable.add(
            UnreadableLibraryChapter(
              bookId: entry.book.id,
              bookTitle: entry.book.title,
              chapterIndex: chapter.key,
              chapterTitle:
                  chapter.key >= 0 && chapter.key < entry.book.chapters.length
                  ? entry.book.chapters[chapter.key].title
                  : 'Chương không thuộc mục lục',
            ),
          );
        }
      }
      checkedBooks++;
      onProgress?.call(checkedBooks, snapshot.entries.length);
      await Future<void>.delayed(Duration.zero);
    }
    checkLibraryRevision(repository.replacementRevision, revision);
    return LibraryHealthReport(
      snapshot: snapshot,
      revision: revision,
      checkedAt: DateTime.now(),
      validationError: error,
      damagedCovers: damagedCovers,
      checkedImages: checkedImages,
      unreadableChapters: List.unmodifiable(unreadable),
      repairSummary: proposal.summary,
      repairBlockedReason: proposal.blockedReason,
      missingDownloads: snapshot.entries.fold(
        0,
        (total, entry) =>
            total +
            List.generate(entry.book.chapters.length, (index) => index)
                .where(
                  (index) =>
                      entry.book.chapters[index].downloaded &&
                      !entry.contents.containsKey(index),
                )
                .length,
      ),
    );
  }

  /// Applies only the displayed corrections, with a recovery before CAS commit.
  /// Book/chapter identities, source data, cache bytes and explicit read flags
  /// are retained. Failed media decoding never authorizes removing media.
  Future<LibraryRepairResult> repair(LibraryHealthReport report) async {
    checkLibraryRevision(repository.replacementRevision, report.revision);
    final original = report.snapshot;
    if (original == null || report.storageUnreadable) {
      throw StateError('Chưa đọc được toàn bộ dữ liệu để sửa an toàn.');
    }
    final proposal = _proposeRepair(original);
    if (proposal.blockedReason != null) {
      throw StateError(proposal.blockedReason!);
    }
    if (!proposal.summary.hasChanges) {
      return LibraryRepairResult(
        summary: proposal.summary,
        reportAfterRepair: report,
        verified: report.validationError == null,
        recoveryAvailable: false,
      );
    }
    // Validate both encodability of the original recovery and the complete
    // proposed library before delegating the recovery-first atomic write.
    original.encode();
    BackupValidator(repository).validateSnapshot(proposal.snapshot.encode());
    final expected = proposal.snapshot.fingerprint;
    await repository.replaceSnapshot(
      proposal.snapshot,
      expectedFingerprint: original.fingerprint,
    );
    final committedRevision = repository.replacementRevision;
    try {
      final after = await inspect();
      checkLibraryRevision(repository.replacementRevision, committedRevision);
      final recovery = await repository.recoverySnapshot();
      checkLibraryRevision(repository.replacementRevision, committedRevision);
      if (after.snapshot?.fingerprint != expected ||
          after.validationError != null ||
          after.repairSummary.hasChanges ||
          recovery == null ||
          sha256.convert(recovery).toString() !=
              sha256.convert(original.encode()).toString()) {
        throw const LibraryRepairVerificationException();
      }
      return LibraryRepairResult(
        summary: proposal.summary,
        reportAfterRepair: after,
        verified: true,
        recoveryAvailable: true,
      );
    } catch (_) {
      // Never claim rollback after the atomic commit. Recovery remains available.
      throw const LibraryRepairVerificationException();
    }
  }

  _LibraryRepairProposal _proposeRepair(LibrarySnapshot original) {
    var missing = 0, incomplete = 0, indexes = 0, reading = 0;
    var duplicates = 0, canonical = 0;
    String? blocked;
    final repairedEntries = <LibrarySnapshotEntry>[];
    for (final entry in original.entries) {
      final book = entry.book;
      var next = book;
      final mismatched = [
        for (var i = 0; i < book.chapters.length; i++)
          if (book.chapters[i].index != i) i,
      ];
      // A mismatch with existing cache/resume information is ambiguous. Do not
      // guess which old position belongs to which stable chapter identity.
      final safeIndexRepair =
          entry.contents.isEmpty &&
          book.bookmarks.isEmpty &&
          book.currentChapter == 0 &&
          book.progress == 0 &&
          !book.completed &&
          book.chapters.map((chapter) => chapter.id).toSet().length ==
              book.chapters.length;
      if (mismatched.isNotEmpty && !safeIndexRepair) {
        blocked ??=
            'Thứ tự chương bị lỗi và có nội dung hoặc vị trí đọc liên quan. '
            'Không thể đoán ánh xạ chương; hãy khôi phục từ bản sao lưu hợp lệ.';
      }
      final chapters = [
        for (var i = 0; i < book.chapters.length; i++)
          (() {
            var chapter = book.chapters[i];
            if (chapter.index != i && safeIndexRepair) {
              indexes++;
              chapter = chapter.copyWith(index: i);
            }
            if (chapter.downloaded) {
              final content = entry.contents[i];
              if (content == null) {
                missing++;
                chapter = chapter.copyWith(downloaded: false);
              } else if (!chapterIsOffline(content)) {
                incomplete++;
                chapter = chapter.copyWith(downloaded: false);
              }
            }
            return chapter;
          })(),
      ];
      final invalidCurrent =
          book.currentChapter < 0 ||
          (chapters.isEmpty
              ? book.currentChapter != 0
              : book.currentChapter >= chapters.length);
      final invalidProgress =
          !book.progress.isFinite || book.progress < 0 || book.progress > 1;
      if (invalidCurrent || invalidProgress) {
        reading++;
        next = next.copyWith(
          currentChapter: invalidCurrent ? 0 : book.currentChapter,
          progress: 0,
          completed: false,
        );
      }
      final bookmarks = <String>[];
      final seenBookmarks = <String>{};
      for (final bookmark in book.bookmarks) {
        final parts = bookmark.split(':');
        final index = parts.length == 2 ? int.tryParse(parts[0].trim()) : null;
        final position = parts.length == 2
            ? double.tryParse(parts[1].trim())
            : null;
        final valid =
            index != null &&
            index >= 0 &&
            index < chapters.length &&
            position != null &&
            position.isFinite &&
            position >= 0 &&
            position <= 1;
        // Preserve unknown/out-of-range bookmarks instead of discarding them.
        final value = valid ? '$index:${parts[1].trim()}' : bookmark;
        if (value != bookmark) canonical++;
        if (!seenBookmarks.add(value)) {
          duplicates++;
        } else {
          bookmarks.add(value);
        }
      }
      next = next.copyWith(chapters: chapters, bookmarks: bookmarks);
      repairedEntries.add(LibrarySnapshotEntry(next, entry.contents));
    }
    final summary = LibraryRepairSummary(
      missingDownloads: missing,
      incompleteDownloads: incomplete,
      chapterIndexes: indexes,
      readingLocations: reading,
      duplicateBookmarks: duplicates,
      canonicalBookmarks: canonical,
    );
    final repaired = LibrarySnapshot(
      repairedEntries,
      configuration: original.configuration,
      extensions: original.extensions,
    );
    try {
      // NaN/Infinity or non-JSON source metadata cannot produce a byte-faithful
      // recovery in this format, so even a normalized proposal is not applied.
      original.encode();
      BackupValidator(repository).validateSnapshot(repaired.encode());
    } catch (_) {
      blocked ??=
          'Có dữ liệu không thể sửa hoặc sao lưu an toàn bằng các bước này. '
          'Chưa thay đổi thư viện; hãy khôi phục từ bản sao lưu hợp lệ.';
    }
    return _LibraryRepairProposal(repaired, summary, blocked);
  }

  /// Only repairs missing-cache flags. It never guesses metadata, fabricates
  /// media, deletes files or changes reading state. CAS writes a recovery first.
  Future<int> repairMissingDownloads(LibraryHealthReport report) async {
    checkLibraryRevision(repository.replacementRevision, report.revision);
    if (report.missingDownloads == 0) return 0;
    final snapshot = report.snapshot;
    if (snapshot == null || report.storageUnreadable) {
      throw StateError('Chưa có dữ liệu hợp lệ để sửa trạng thái.');
    }
    final repaired = LibrarySnapshot(
      snapshot.entries.map(
        (entry) => LibrarySnapshotEntry(
          entry.book.copyWith(
            chapters: [
              for (var index = 0; index < entry.book.chapters.length; index++)
                entry.book.chapters[index].downloaded &&
                        !entry.contents.containsKey(index)
                    ? entry.book.chapters[index].copyWith(downloaded: false)
                    : entry.book.chapters[index],
            ],
          ),
          entry.contents,
        ),
      ),
      configuration: snapshot.configuration,
      extensions: snapshot.extensions,
    );
    // Refuse broader corruption before the first write.
    BackupValidator(repository).validateSnapshot(repaired.encode());
    await repository.replaceSnapshot(
      repaired,
      expectedFingerprint: snapshot.fingerprint,
    );
    return report.missingDownloads;
  }
}

class _LibraryRepairProposal {
  const _LibraryRepairProposal(this.snapshot, this.summary, this.blockedReason);
  final LibrarySnapshot snapshot;
  final LibraryRepairSummary summary;
  final String? blockedReason;
}
