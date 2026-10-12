import 'dart:typed_data';

import 'package:archive/archive.dart';

import '../../library/data/library_mutation.dart';
import '../../library/data/library_repository.dart';
import '../../library/domain/library_book.dart';

class CbzExport {
  const CbzExport({
    required this.bytes,
    required this.fileName,
    required this.chapters,
    required this.pages,
  });
  final Uint8List bytes;
  final String fileName;
  final int chapters, pages;
}

/// Exports hydrated local chapter bytes; it never fetches or reencodes images.
class CbzExportService {
  CbzExportService(this.repository);
  final LibraryRepository repository;
  static const maxExportBytes = 64 * 1024 * 1024;
  static const maxPages = 10000;

  Future<CbzExport> exportBook(
    LibraryBook selection, {
    int? expectedRevision,
    Iterable<String>? chapterIds,
  }) async {
    final revision = expectedRevision ?? repository.replacementRevision;
    checkLibraryRevision(repository.replacementRevision, revision);
    final book = await repository.find(selection.id);
    checkLibraryRevision(repository.replacementRevision, revision);
    if (book == null) throw StateError('Sách đã được xóa khỏi thư viện');
    if (bookSourceIdentity(book) != bookSourceIdentity(selection)) {
      throw StateError('Nguồn của truyện đã thay đổi. Hãy mở lại truyện.');
    }
    if (book.kind != 'manga') {
      throw StateError('CBZ chỉ dùng cho truyện tranh đã tải.');
    }
    final requested = chapterIds?.toSet();
    if (requested != null &&
        (requested.isEmpty || requested.any((id) => id.isEmpty))) {
      throw ArgumentError('Chưa chọn chương để xuất');
    }
    final chapters = book.chapters
        .where(
          (chapter) => requested?.contains(chapter.id) ?? chapter.downloaded,
        )
        .toList();
    if (requested != null && chapters.length != requested.length) {
      throw StateError('Chương đã chọn không còn trong mục lục.');
    }
    if (chapters.isEmpty) {
      throw StateError('Chưa có chương truyện tranh đã tải.');
    }
    if (chapters.map((chapter) => chapter.id).toSet().length !=
        chapters.length) {
      throw StateError('Mục lục có mã chương trùng. Không thể xuất an toàn.');
    }
    final archive = Archive();
    var totalBytes = 0, pages = 0;
    for (final entry in chapters.indexed) {
      final chapter = entry.$2;
      if (!chapter.downloaded) {
        throw StateError('Chương ${chapter.title} chưa được tải đầy đủ.');
      }
      final read = await repository.openChapter(book.id, chapter.id);
      checkLibraryRevision(repository.replacementRevision, revision);
      if (read == null ||
          read.revision != revision ||
          bookSourceIdentity(read.book) != bookSourceIdentity(book) ||
          !read.book.chapters[read.index].downloaded ||
          read.content == null) {
        throw StateError(
          'Nội dung đã tải của chương ${chapter.title} không còn.',
        );
      }
      final content = read.content!;
      checkChapterContent(read.book, content);
      if (!chapterIsOffline(content)) {
        throw StateError('Chương ${chapter.title} vẫn còn ảnh chưa tải.');
      }
      for (final image in content.images.indexed) {
        if (++pages > maxPages) {
          throw const FormatException('CBZ vượt giới hạn 10.000 trang.');
        }
        final bytes = _localImage(image.$2);
        totalBytes += bytes.length;
        if (totalBytes > maxExportBytes) {
          throw const FormatException(
            'CBZ vượt giới hạn 64 MB. Hãy chọn ít chương hơn.',
          );
        }
        final folder = '${entry.$1 + 1}'.padLeft(5, '0');
        final page = '${image.$1 + 1}'.padLeft(5, '0');
        archive.add(
          ArchiveFile.noCompress(
            '$folder/$page.${_extension(bytes)}',
            bytes.length,
            bytes,
          ),
        );
      }
    }
    checkLibraryRevision(repository.replacementRevision, revision);
    final bytes = Uint8List.fromList(ZipEncoder().encode(archive));
    if (bytes.length > maxExportBytes) {
      throw const FormatException(
        'CBZ vượt giới hạn 64 MB. Hãy chọn ít chương hơn.',
      );
    }
    checkLibraryRevision(repository.replacementRevision, revision);
    final title = book.title
        .replaceAll(RegExp(r'[\x00-\x1f<>:"/\\|?*]'), '_')
        .replaceAll(RegExp(r'[. ]+$'), '')
        .trim();
    final safeTitle = String.fromCharCodes(title.runes.take(100));
    return CbzExport(
      bytes: bytes,
      fileName: '${safeTitle.isEmpty ? 'Truyen' : safeTitle}.cbz',
      chapters: chapters.length,
      pages: pages,
    );
  }

  Uint8List _localImage(String source) {
    // Native readChapter/openChapter hydrates tachi-asset references. Refuse an
    // unresolved reference or remote URL instead of silently exporting a link.
    if (!source.startsWith('data:image/') ||
        source.length > LibraryRepository.maxImageBytes * 4 ~/ 3 + 1024) {
      throw const FormatException(
        'Ảnh đã tải không hợp lệ hoặc vượt giới hạn 8 MB.',
      );
    }
    final bytes = UriData.parse(source).contentAsBytes();
    if (bytes.isEmpty || bytes.length > LibraryRepository.maxImageBytes) {
      throw const FormatException('Ảnh đã tải trống hoặc vượt giới hạn 8 MB.');
    }
    return bytes;
  }

  String _extension(Uint8List bytes) {
    bool starts(List<int> prefix) =>
        bytes.length >= prefix.length &&
        prefix.indexed.every((entry) => bytes[entry.$1] == entry.$2);
    if (starts([137, 80, 78, 71, 13, 10, 26, 10])) return 'png';
    if (starts([255, 216, 255])) return 'jpg';
    if (starts([71, 73, 70, 56, 55, 97]) || starts([71, 73, 70, 56, 57, 97])) {
      return 'gif';
    }
    if (bytes.length >= 12 &&
        starts([82, 73, 70, 70]) &&
        bytes[8] == 87 &&
        bytes[9] == 69 &&
        bytes[10] == 66 &&
        bytes[11] == 80) {
      return 'webp';
    }
    if (bytes.length >= 16 &&
        bytes[4] == 102 &&
        bytes[5] == 116 &&
        bytes[6] == 121 &&
        bytes[7] == 112) {
      for (var i = 8; i + 3 < bytes.length.clamp(0, 64); i += 4) {
        if (bytes[i] == 97 &&
            bytes[i + 1] == 118 &&
            bytes[i + 2] == 105 &&
            (bytes[i + 3] == 102 || bytes[i + 3] == 115)) {
          return 'avif';
        }
      }
    }
    if (bytes.length >= 14 && starts([66, 77])) return 'bmp';
    throw const FormatException(
      'Định dạng byte ảnh đã tải chưa được hỗ trợ trong CBZ.',
    );
  }
}
