import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../domain/library_book.dart';
import 'document_importer.dart';
import 'library_mutation.dart';
import 'library_repository.dart';
import 'library_snapshot.dart';
import 'local_comic_files_platform.dart';
import 'local_comic_metadata.dart';

class FolderComicImportResult {
  const FolderComicImportResult(
    this.newBooks,
    this.newChapters,
    this.retainedChapters,
  );
  final int newBooks, newChapters, retainedChapters;
}

/// The user explicitly chooses which restored library title belongs to a
/// relative path in a newly selected folder. IDs are never matched by title.
class FolderComicReconnect {
  const FolderComicReconnect(this.bookId, this.previousFolderId);
  final String bookId, previousFolderId;
}

/// File bytes are staged in memory; only the final CAS snapshot modifies the
/// library. Permissions and absolute Files URLs stay in the native bookmark.
class FolderComicImporter {
  FolderComicImporter(this.platform);
  final LocalComicFilesPlatform platform;
  static bool archive(String path) =>
      ['zip', 'cbz', 'rar', 'cbr'].contains(path.toLowerCase().split('.').last);
  Future<FolderComicImportResult> scan(
    LocalComicFolder folder,
    LibraryRepository repo, {
    List<String> defaultCategories = const ['Mặc định'],
    bool Function()? isCurrent,
    Map<String, FolderComicReconnect> reconnect = const {},
    bool folderIsSingleBook = false,
  }) async {
    void checkCurrent() {
      if (isCurrent != null && !isCurrent()) {
        throw StateError(
          'Phiên nhập thư mục đã đóng hoặc ứng dụng đã khóa. Dữ liệu chưa được ghi.',
        );
      }
    }

    checkCurrent();
    final revision = repo.replacementRevision;
    final before = await repo.snapshot();
    final originalBooks = {
      for (final entry in before.entries) entry.book.id: entry.book,
    };
    final reboundIds = <String>{};
    for (final binding in reconnect.entries) {
      if (binding.key.isNotEmpty) validateLocalComicPath(binding.key);
      final original = originalBooks[binding.value.bookId];
      if (original == null ||
          original.engine != 'local' ||
          original.kind != 'manga' ||
          original.sourceName != 'Thư mục trên máy' ||
          original.sourceRef != binding.key ||
          original.sourceId != binding.value.previousFolderId ||
          !reboundIds.add(original.id)) {
        throw StateError(
          'Truyện hoặc thư mục trong bản xem trước kết nối lại đã thay đổi. Chọn lại truyện.',
        );
      }
    }
    final scan = await platform.list(folder.id);
    checkCurrent();
    final relevant = scan.files
        .where(
          (file) =>
              localImageType(file.path) != null ||
              archive(file.path) ||
              file.path.split('/').last == 'details.json',
        )
        .toList();
    final groups = <String, List<LocalComicFile>>{};
    for (final file in relevant) {
      validateLocalComicPath(file.path);
      final slash = file.path.indexOf('/');
      final bookPath = folderIsSingleBook || slash < 0
          ? ''
          : file.path.substring(0, slash);
      (groups[bookPath] ??= []).add(file);
    }
    var newBooks = 0, newChapters = 0, retainedChapters = 0, inputTotal = 0;
    var stagedImageBytes = 0;
    void boundImages(ReaderContent content) {
      for (final image in content.images) {
        stagedImageBytes += image.length;
      }
      if (stagedImageBytes > LibrarySnapshot.maxBytes) {
        throw const FormatException(
          'Ảnh đã quét vượt giới hạn snapshot 128 MB. Chọn thư mục nhỏ hơn.',
        );
      }
    }

    final replacements = <String, LibrarySnapshotEntry>{};
    final paths = groups.keys.toList()..sort(naturalFileCompare);
    for (final path in paths) {
      checkLibraryRevision(repo.replacementRevision, revision);
      checkCurrent();
      final binding = reconnect[path];
      final attached = before.entries
          .where(
            (entry) =>
                entry.book.engine == 'local' &&
                entry.book.sourceName == 'Thư mục trên máy' &&
                entry.book.sourceId == folder.id &&
                entry.book.sourceRef == path,
          )
          .toList();
      if (binding == null && attached.length > 1) {
        throw StateError(
          'Có nhiều truyện cùng đường dẫn trong thư mục. Kết nối lại từng truyện trước khi quét.',
        );
      }
      final id =
          binding?.bookId ??
          attached.firstOrNull?.book.id ??
          sha256
              .convert(utf8.encode('local-comic-folder:${folder.id}:$path'))
              .toString();
      final existing = before.entries
          .where((entry) => entry.book.id == id)
          .firstOrNull;
      if (existing != null &&
          (existing.book.engine != 'local' ||
              existing.book.sourceId !=
                  (binding?.previousFolderId ?? folder.id) ||
              existing.book.sourceRef != path)) {
        throw StateError('Truyện thư mục không còn khớp định danh nguồn.');
      }
      final raw = <String, Uint8List>{}, archiveFiles = <String, Uint8List>{};
      for (final file in groups[path]!) {
        final relative = path.isEmpty
            ? file.path
            : file.path.substring(path.length + 1);
        final bytes = await platform.read(folder.id, file);
        checkLibraryRevision(repo.replacementRevision, revision);
        checkCurrent();
        inputTotal += bytes.length;
        if (inputTotal > DocumentImporter.maxExpandedBytes) {
          throw const FormatException(
            'Một lượt quét vượt giới hạn 200 MB. Chọn thư mục nhỏ hơn.',
          );
        }
        (archive(file.path) ? archiveFiles : raw)[relative] = bytes;
      }
      final staged = MemoryLibraryRepository();
      final title = path.isEmpty ? folder.label : path;
      final incoming = <BookChapter>[],
          contentsById = <String, ReaderContent>{};
      var cover = '';
      LibraryBook? parsed;
      if (raw.keys.any((name) => localImageType(name) != null)) {
        parsed = await DocumentImporter(stableComicChapterIds: true)
            .importComicEntries(id, title, raw, staged);
        cover = parsed.cover;
        for (var i = 0; i < parsed.chapters.length; i++) {
          final c = parsed.chapters[i];
          final chapterId = 'folder:${c.id.substring('$id:folder:'.length)}';
          incoming.add(c.copyWith(id: chapterId, index: incoming.length));
          final content = (await staged.readChapter(id, i))!;
          boundImages(content);
          contentsById[chapterId] = content;
        }
      }
      final archiveNames = archiveFiles.keys.toList()..sort(naturalFileCompare);
      for (final name in archiveNames) {
        final archiveRepo = MemoryLibraryRepository();
        final book = await DocumentImporter(
          extractRar: platform.extractRar,
          stableComicChapterIds: true,
        ).import(name, archiveFiles[name]!, archiveRepo);
        if (cover.isEmpty) cover = book.cover;
        for (var i = 0; i < book.chapters.length; i++) {
          final chapter = book.chapters[i];
          final chapterPath = chapter.id.substring('${book.id}:folder:'.length);
          final chapterId = 'archive:$name:$chapterPath';
          incoming.add(
            chapter.copyWith(
              id: chapterId,
              title: chapterPath.isEmpty
                  ? name.replaceFirst(RegExp(r'\.[^.]+$'), '')
                  : '$name · ${chapter.title}',
              index: incoming.length,
            ),
          );
          final content = (await archiveRepo.readChapter(book.id, i))!;
          boundImages(content);
          contentsById[chapterId] = content;
        }
      }
      if (incoming.isEmpty) continue;
      incoming.sort((a, b) => naturalFileCompare(a.title, b.title));
      for (var i = 0; i < incoming.length; i++) {
        incoming[i] = incoming[i].copyWith(index: i);
      }
      final old = existing?.book;
      var metadata =
          old ??
          (parsed ?? LibraryBook(id: id, title: title, kind: 'manga')).copyWith(
            engine: 'local',
            sourceId: folder.id,
            sourceName: 'Thư mục trên máy',
            sourceRef: path,
            categories: defaultCategories,
            createdAt: DateTime.now(),
          );
      if (old == null && raw['details.json'] != null) {
        metadata = LocalComicMetadata.decode(raw['details.json']!)
            .apply(metadata);
      }
      final identities = incoming.map((chapter) => chapter.id).toSet();
      if (old != null) {
        for (final chapter in old.chapters.where(
          (chapter) => !identities.contains(chapter.id),
        )) {
          // A removed source file never deletes a readable copied chapter.
          incoming.add(chapter.copyWith(index: incoming.length));
          retainedChapters++;
        }
      }
      final change = remapChapterOrder(
        metadata.copyWith(chapters: old?.chapters ?? const []),
        incoming,
      );
      final contents = <int, ReaderContent>{};
      for (var i = 0; i < change.book.chapters.length; i++) {
        final chapterId = change.book.chapters[i].id;
        final oldIndex =
            old?.chapters.indexWhere((chapter) => chapter.id == chapterId) ??
            -1;
        final content = contentsById[chapterId] ?? existing?.contents[oldIndex];
        if (content != null) contents[i] = content;
      }
      final book = change.book.copyWith(
        sourceId: folder.id,
        cover: old?.customCover == true
            ? old!.cover
            : cover.isEmpty
            ? metadata.cover
            : cover,
        chapters: [
          for (final entry in change.book.chapters.indexed)
            entry.$2.copyWith(downloaded: contents.containsKey(entry.$1)),
        ],
      );
      repo.validateBook(book);
      for (final entry in contents.entries) {
        repo.validateChapter(entry.key, entry.value);
      }
      replacements[id] = LibrarySnapshotEntry(book, contents);
      newBooks += old == null ? 1 : 0;
      newChapters += change.additions;
    }
    await platform.confirm(folder.id, scan.digest);
    if (reconnect.keys.any((path) => !groups.containsKey(path))) {
      throw StateError(
        'Đường dẫn truyện được chọn không có trong thư mục mới. Không ghi dữ liệu; kiểm tra thư mục rồi chọn lại.',
      );
    }
    checkCurrent();
    checkLibraryRevision(repo.replacementRevision, revision);
    retainedChapters += before.entries
        .where(
          (entry) =>
              entry.book.engine == 'local' &&
              entry.book.sourceId == folder.id &&
              !replacements.containsKey(entry.book.id),
        )
        .fold<int>(0, (count, entry) => count + entry.book.chapters.length);
    if (replacements.isNotEmpty) {
      final next = LibrarySnapshot([
        for (final entry in before.entries)
          replacements.remove(entry.book.id) ?? entry,
        ...replacements.values,
      ]);
      next.encode(); // Bound all hydrated media before CAS/recovery/commit.
      await repo.replaceSnapshot(next, expectedFingerprint: before.fingerprint);
    }
    return FolderComicImportResult(newBooks, newChapters, retainedChapters);
  }
}
