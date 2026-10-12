import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../../library/data/library_repository.dart';
import '../../library/data/library_snapshot.dart';
import '../../library/data/backup_validation.dart';
import '../../library/domain/chapter_list_options.dart';
import '../../library/domain/library_book.dart';
import '../../library/domain/library_reading.dart';
import 'catalogue.dart';

/// A reviewed, immutable proposal. No cache is copied between source identities.
class SourceMigrationPreview {
  SourceMigrationPreview._({
    required this.before,
    required this.original,
    required this.replacement,
    required Map<int, int> matches,
    required this.unmatchedBookmarks,
  }) : matches = Map.unmodifiable(matches),
       beforeFingerprint = before.fingerprint;
  final LibrarySnapshot before;
  final String beforeFingerprint;
  final LibraryBook original, replacement;

  /// Original chapter index -> replacement chapter index.
  final Map<int, int> matches;
  final int unmatchedBookmarks;
  int get oldOfflineChapters =>
      original.chapters.where((c) => c.downloaded).length;
  int get unmatchedChapters => original.chapters.length - matches.length;
  int get mappedReadChapters =>
      replacement.chapters.where((c) => c.read == true).length;

  /// Bulk review retains one hydrated backup image, not one copy per title.
  SourceMigrationPreview sharingSnapshot(SourceMigrationPreview other) {
    if (other.beforeFingerprint != beforeFingerprint) {
      throw StateError(
        'Thư viện đã thay đổi trong lúc chọn kết quả. Bỏ chọn để tạo lại bản xem trước trước khi chuyển.',
      );
    }
    return SourceMigrationPreview._(
      before: other.before,
      original: original,
      replacement: replacement,
      matches: matches,
      unmatchedBookmarks: unmatchedBookmarks,
    );
  }
}

class SourceMigration {
  SourceMigration(this.repository);
  final LibraryRepository repository;

  Future<SourceMigrationPreview> preview(
    String originalId,
    CatalogueBook target,
    List<CatalogueChapter> incoming, {
    String sourceName = '',
  }) async {
    final before = await repository.snapshot();
    final old = before.entries
        .where((e) => e.book.id == originalId)
        .firstOrNull
        ?.book;
    if (old == null || old.engine == 'local') {
      throw StateError('Truyện nguồn cũ không còn trong thư viện.');
    }
    if (old.kind != target.kind.name ||
        '${old.engine}:${old.sourceId}' ==
            '${target.engine.name}:${target.sourceId}') {
      throw const FormatException('Hãy chọn nguồn khác có cùng loại truyện.');
    }
    if (target.ref.isEmpty || target.title.trim().isEmpty || incoming.isEmpty) {
      throw const FormatException(
        'Nguồn mới chưa có thông tin hoặc danh sách chương hợp lệ.',
      );
    }
    final id = sha256.convert(utf8.encode(target.identity)).toString();
    if (before.entries.any(
      (e) =>
          e.book.id == id ||
          '${e.book.engine}:${e.book.sourceId}:${e.book.sourceRef}' ==
              target.identity,
    )) {
      throw StateError(
        'Truyện ở nguồn mới đã có trong thư viện. Không ghi đè dữ liệu của truyện đó.',
      );
    }
    final chapters = [
      for (final (index, c) in incoming.indexed)
        BookChapter(
          id: c.ref,
          title: c.title,
          index: index,
          number: c.number,
          scanlator: c.scanlator,
          uploadedAt: c.uploadedAt,
          read: false,
        ),
    ];
    final matches = matchMigrationChapters(old.chapters, chapters);
    final marks = <String>[];
    var unmatchedBookmarks = 0;
    for (final mark in old.bookmarks) {
      final parts = mark.split(':');
      final oldIndex = parts.length == 2 ? int.tryParse(parts.first) : null;
      final index = matches[oldIndex];
      if (index == null) {
        unmatchedBookmarks++;
      } else {
        // Page counts/content may differ across sources. Preserve the chapter
        // bookmark, but do not misrepresent the old page fraction as equivalent.
        final translated = '$index:0.0000';
        if (!marks.contains(translated)) marks.add(translated);
      }
    }
    final reverse = {for (final e in matches.entries) e.value: e.key};
    final current = matches[old.currentChapter] ?? 0;
    final replacement = LibraryBook(
      id: id,
      title: target.title,
      alternativeTitles: old.alternativeTitles,
      author: target.author,
      artist: target.artist,
      genres: target.genres,
      description: target.description,
      cover: old.customCover ? old.cover : target.coverUrl,
      originalCover: old.customCover ? target.coverUrl : '',
      customCover: old.customCover,
      kind: target.kind.name,
      engine: target.engine.name,
      sourceId: target.sourceId,
      sourceName: sourceName,
      sourceRef: target.ref,
      status: target.status,
      readingState: old.readingState,
      rating: old.rating,
      categories: old.categories,
      favorite: old.favorite,
      notes: old.notes,
      externalBackupMetadata: old.externalBackupMetadata,
      series: old.series,
      readerPreferences: old.readerPreferences,
      chapterListPreferences: old.chapterListPreferences,
      createdAt: old.createdAt,
      lastUpdated: DateTime.now(),
      lastRead: old.lastRead,
      currentChapter: current,
      progress: current / chapters.length,
      bookmarks: marks,
      chapters: [
        for (final (index, c) in chapters.indexed)
          c.copyWith(
            read: reverse[index] != null && chapterIsRead(old, reverse[index]!),
          ),
      ],
    );
    final candidate = SourceMigrationPreview._(
      before: before,
      original: old,
      replacement: replacement,
      matches: matches,
      unmatchedBookmarks: unmatchedBookmarks,
    );
    // Reuse full backup validation, including IDs, numbers, media and indices.
    BackupValidator(repository)
        .validateSnapshot(_snapshot(candidate, false).encode());
    return candidate;
  }

  Future<LibraryBook> commit(
    SourceMigrationPreview preview, {
    bool replaceOld = false,
  }) async {
    final incoming = _snapshot(preview, replaceOld);
    BackupValidator(repository).validateSnapshot(incoming.encode());
    // Repository performs atomic fingerprint CAS and saves the hydrated recovery
    // image before writing. Edits/downloads since preview reject the entire commit.
    await repository.replaceSnapshot(
      incoming,
      expectedFingerprint: preview.beforeFingerprint,
    );
    return preview.replacement;
  }

  Future<List<LibraryBook>> commitBatch(
    List<SourceMigrationPreview> previews, {
    bool replaceOld = false,
  }) async {
    if (previews.isEmpty || previews.length > 10000) {
      throw const FormatException('Danh sách chuyển nguồn trống hoặc quá lớn.');
    }
    final before = previews.first.before;
    final fingerprint = previews.first.beforeFingerprint;
    final oldIds = <String>{}, newIds = <String>{};
    for (final preview in previews) {
      if (preview.beforeFingerprint != fingerprint) {
        throw StateError(
          'Thư viện đã thay đổi giữa các lượt xem trước. Hãy chọn lại kết quả để bảo toàn dữ liệu mới.',
        );
      }
      if (!oldIds.add(preview.original.id) ||
          !newIds.add(preview.replacement.id)) {
        throw StateError(
          'Có truyện cũ hoặc truyện đích được ghép nhiều lần. Hãy sửa các kết quả bị trùng.',
        );
      }
    }
    final incoming = LibrarySnapshot([
      for (final entry in before.entries)
        if (!replaceOld || !oldIds.contains(entry.book.id)) entry,
      for (final preview in previews)
        LibrarySnapshotEntry(preview.replacement, const {}),
    ]);
    BackupValidator(repository).validateSnapshot(incoming.encode());
    await repository.replaceSnapshot(
      incoming,
      expectedFingerprint: fingerprint,
    );
    return [for (final preview in previews) preview.replacement];
  }

  LibrarySnapshot _snapshot(SourceMigrationPreview preview, bool replaceOld) =>
      LibrarySnapshot([
        for (final entry in preview.before.entries)
          if (!replaceOld || entry.book.id != preview.original.id) entry,
        LibrarySnapshotEntry(preview.replacement, const {}),
      ]);
}

/// Numbers must be unique on BOTH sources. Exact normalized titles are a
/// fallback only when no conflicting valid numbers exist. Ambiguity stays unmapped.
Map<int, int> matchMigrationChapters(
  List<BookChapter> from,
  List<BookChapter> to,
) {
  Map<T, List<int>> groups<T>(
    List<BookChapter> chapters,
    T? Function(BookChapter) key,
  ) {
    final result = <T, List<int>>{};
    for (final (i, chapter) in chapters.indexed) {
      final value = key(chapter);
      if (value != null) (result[value] ??= []).add(i);
    }
    return result;
  }

  final oldNumbers = groups(from, validChapterNumber),
      newNumbers = groups(to, validChapterNumber);
  final result = <int, int>{};
  for (final entry in oldNumbers.entries) {
    final next = newNumbers[entry.key];
    if (entry.value.length == 1 && next?.length == 1) {
      result[entry.value.single] = next!.single;
    }
  }
  String? title(BookChapter chapter) {
    final value = chapter.title.trim().toLowerCase().replaceAll(
      RegExp(r'\s+'),
      ' ',
    );
    return value.isEmpty ? null : value;
  }

  final oldTitles = groups(from, title), newTitles = groups(to, title);
  for (final entry in oldTitles.entries) {
    final next = newTitles[entry.key];
    if (entry.value.length != 1 || next?.length != 1) continue;
    final a = entry.value.single, b = next!.single;
    if (result.containsKey(a) || result.containsValue(b)) continue;
    final an = validChapterNumber(from[a]), bn = validChapterNumber(to[b]);
    if (an != null && bn != null && an != bn) continue;
    if ((an != null && oldNumbers[an]!.length > 1) ||
        (bn != null && newNumbers[bn]!.length > 1)) {
      continue;
    }
    result[a] = b;
  }
  return result;
}
