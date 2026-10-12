import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:archive/archive.dart';

import '../../domain/library_book.dart';
import '../../domain/library_reading.dart';
import '../library_snapshot.dart';
import 'protobuf_writer.dart';
import 'mihon_tracking.dart';

/// A metadata-only exchange file, distinct from a full TachiBooks backup.
/// Schema evidence is the official v0.20.4 Kotlin @ProtoNumber models:
/// artifacts/mihon-official-v0.20.4-source/app/src/main/java/
/// eu/kanade/tachiyomi/data/backup/models/{Backup,BackupManga,BackupChapter,
/// BackupCategory,BackupHistory,BackupSource}.kt.
class MihonBackupExport {
  MihonBackupExport({
    required this.bytes,
    required this.books,
    required this.chapters,
    required this.categories,
    required this.skippedBooks,
    required List<String> warnings,
  }) : warnings = List.unmodifiable(warnings);

  final Uint8List bytes;
  final int books, chapters, categories, skippedBooks;
  final List<String> warnings;
}

/// No library/configuration mutation occurs. Source names are optional because
/// a saved library has exact source IDs but does not necessarily have names.
Future<MihonBackupExport> exportMihonBackup(
  LibrarySnapshot snapshot, {
  Map<String, String> sourceNames = const {},
}) => Isolate.run(() => _export(snapshot, sourceNames));

MihonBackupExport _export(
  LibrarySnapshot snapshot,
  Map<String, String> sourceNames,
) {
  if (snapshot.entries.length > 10000) {
    throw const FormatException('Thư viện sao lưu có quá nhiều truyện.');
  }
  final excluded = <String, int>{};
  final eligible = <LibrarySnapshotEntry>[];
  final identities = <String>{};
  for (final entry in snapshot.entries) {
    final book = entry.book;
    final reason = _unrepresentable(book);
    if (reason != null) {
      excluded.update(reason, (count) => count + 1, ifAbsent: () => 1);
      continue;
    }
    _validate(book);
    if (!identities.add(jsonEncode([book.sourceId, book.sourceRef]))) {
      throw const FormatException('Thư viện có truyện trùng nguồn và URL.');
    }
    eligible.add(entry);
  }
  eligible.sort((a, b) => a.book.id.compareTo(b.book.id));
  final categoryIds = <String, BigInt>{};
  for (final entry in eligible) {
    for (final name in entry.book.categories) {
      categoryIds.putIfAbsent(name, () => BigInt.from(categoryIds.length + 1));
    }
  }
  if (categoryIds.length > 10000) {
    throw const FormatException('Thư viện có quá nhiều danh mục.');
  }
  final budget = ProtoWriteBudget();
  final root = ProtoWriter(budget);
  var chapterCount = 0, partialUnknown = 0, coverOmitted = 0;
  var chapterNumbersRounded = 0, chapterNumbersUnknown = 0;
  var positionBookmarks = 0, historyUnknown = 0;
  var memoOmitted = 0, trackerCount = 0;
  var trackerFloatConversion = 0;
  final sources = <String>{};
  for (final entry in eligible) {
    final book = entry.book;
    final manga = ProtoWriter(budget)
      ..integer(1, BigInt.parse(book.sourceId))
      ..string(2, book.sourceRef)
      ..string(3, book.title)
      ..string(4, book.artist)
      ..string(5, book.author)
      ..string(6, book.description)
      ..int64(8, book.status)
      ..int64(13, _date(book.createdAt))
      // In Mihon this means library membership, not TachiBooks' star flag.
      ..boolean(100, true)
      ..int64(106, _date(book.lastUpdated))
      ..string(110, book.notes);
    final compatibility = book.externalBackupMetadata;
    if (compatibility != null) {
      if (compatibility.format == 'tachimanga-build511') {
        trackerFloatConversion += compatibility.tracking.length;
      }
      for (final encoded in compatibility.tracking) {
        final bytes = base64Decode(encoded);
        validateMihonTracking(bytes);
        manga.message(18, bytes);
        trackerCount++;
      }
      if (compatibility.memo != null) {
        if (compatibility.belongsTo(
          book.engine,
          book.sourceId,
          book.sourceRef,
        )) {
          manga.message(112, base64Decode(compatibility.memo!));
        } else {
          memoOmitted++;
        }
      }
    }
    for (final genre in book.genres) {
      manga.string(7, genre);
    }
    if (book.cover.isNotEmpty) {
      final uri = Uri.tryParse(book.cover);
      if (book.cover.startsWith('/') ||
          (uri != null && ['http', 'https'].contains(uri.scheme))) {
        manga.string(9, book.cover);
      } else {
        coverOmitted++;
      }
    }
    final markCounts = <int, int>{};
    for (final mark in book.bookmarks) {
      final index = int.parse(mark.split(':').first);
      markCounts.update(index, (count) => count + 1, ifAbsent: () => 1);
    }
    final marked = <int>{};
    for (final mark in book.bookmarks) {
      final values = mark.split(':');
      final index = int.parse(values[0]);
      marked.add(index);
      if (double.parse(values[1]) != 0 || markCounts[index]! > 1) {
        positionBookmarks++;
      }
    }
    final fraction =
        (book.progress * book.chapters.length - book.currentChapter).clamp(
          0.0,
          1.0,
        );
    for (final (index, chapter) in book.chapters.indexed) {
      final read = chapterIsRead(book, index);
      final content = entry.contents[index];
      final pages = content?.kind == 'manga' ? content!.images.length : 0;
      var lastPage = 0;
      if (pages > 0) {
        lastPage = read
            ? pages - 1
            : index == book.currentChapter
            ? (fraction * pages).floor().clamp(0, pages - 1)
            : 0;
      } else if (index == book.currentChapter && fraction > 0 && !read) {
        partialUnknown++;
      }
      final item = ProtoWriter(budget)
        ..string(1, chapter.id)
        ..string(2, chapter.title)
        ..string(3, chapter.scanlator)
        ..boolean(4, read)
        ..boolean(5, marked.contains(index))
        ..int64(6, lastPage)
        ..int64(7, _date(chapter.discoveredAt))
        ..int64(8, _date(chapter.uploadedAt))
        // Mihon assigns sourceOrder=0 to the newest chapter. TachiBooks keeps
        // canonical oldest-first indices, independent of presentation sorting.
        ..int64(10, book.chapters.length - index - 1);
      final number = chapter.number;
      if (number != null) {
        final encoded = ByteData(4)..setFloat32(0, number, Endian.little);
        final rounded = encoded.getFloat32(0, Endian.little);
        if (rounded.isFinite) {
          item.float32(9, number);
          if (rounded != number) chapterNumbersRounded++;
        } else {
          chapterNumbersUnknown++;
        }
      } else {
        chapterNumbersUnknown++;
      }
      manga.message(16, item.finish());
      chapterCount++;
    }
    manga.packedIntegers(17, [
      for (final name in book.categories) categoryIds[name]!,
    ]);
    if (book.lastRead != null) {
      if (book.chapters.isNotEmpty) {
        final history = ProtoWriter(budget)
          ..string(1, book.chapters[book.currentChapter].id)
          ..int64(2, _date(book.lastRead));
        manga.message(104, history.finish());
      } else {
        historyUnknown++;
      }
    }
    root.message(1, manga.finish());
    sources.add(book.sourceId);
  }
  for (final (index, entry) in categoryIds.entries.indexed) {
    final category = ProtoWriter(budget)
      ..string(1, entry.key)
      ..int64(2, index)
      ..integer(3, entry.value);
    root.message(2, category.finish());
  }
  for (final id in sources) {
    final source = ProtoWriter(budget)
      ..string(1, sourceNames[id] ?? '')
      ..integer(2, BigInt.parse(id));
    root.message(101, source.finish());
  }
  final bytes = Uint8List.fromList(GZipEncoder().encode(root.finish()));
  if (bytes.length > ProtoWriter.maxBytes) {
    throw const FormatException('Bản sao lưu vượt giới hạn 128 MB.');
  }
  return MihonBackupExport(
    bytes: bytes,
    books: eligible.length,
    chapters: chapterCount,
    categories: categoryIds.length,
    skippedBooks: snapshot.entries.length - eligible.length,
    warnings: [
      'Đây là bản trao đổi metadata Mihon/Tachiyomi (.tachibk): chỉ chứa '
          'truyện từ nguồn Tachi, chương, danh mục, trạng thái đọc, đánh dấu '
          'chương, ghi chú và lịch sử gần nhất. Cần cài extension tương ứng ở app nhận.',
      'File EPUB/TXT/CBZ, trang tải offline, extension, tài khoản, '
          'thiết lập, sao yêu thích, bộ truyện và thời gian đọc chi tiết không nằm '
          'trong file này. Dùng sao lưu đầy đủ TachiBooks để chuyển toàn bộ dữ liệu sang máy khác.',
      if (trackerCount > 0)
        '$trackerCount liên kết tracker được xuất theo BackupTracking chính thức; '
            'app nhận vẫn cần đăng nhập dịch vụ theo dõi.',
      if (trackerFloatConversion > 0)
        '$trackerFloatConversion tracker từ Tachimanga dùng số thực float32 '
            'khi xuất Mihon; dữ liệu REAL gốc còn nguyên trong sao lưu đầy đủ TachiBooks.',
      if (memoOmitted > 0)
        '$memoOmitted memo thuộc nguồn trước khi chuyển được giữ trong sao lưu đầy đủ '
            'TachiBooks, không xuất thành memo của nguồn mới.',
      for (final entry in excluded.entries)
        '${entry.value} truyện ${entry.key}.',
      if (positionBookmarks > 0)
        '$positionBookmarks dấu trang chỉ giữ đánh dấu chương; Mihon không lưu vị trí '
            'cuộn hay nhiều dấu trang trong cùng chương bằng trường bookmark.',
      if (partialUnknown > 0)
        '$partialUnknown chương đang đọc thiếu số trang đã tải nên không thể '
            'đổi phần trăm thành số trang; vị trí trong chương không được xuất.',
      if (coverOmitted > 0)
        '$coverOmitted ảnh bìa lưu trên máy không được xuất; Mihon cần lấy lại bìa từ nguồn.',
      if (chapterNumbersRounded > 0)
        '$chapterNumbersRounded số chương được làm tròn theo kiểu float32 của Mihon.',
      if (chapterNumbersUnknown > 0)
        '$chapterNumbersUnknown chương chưa có số chương hợp lệ theo float32; '
            'Mihon có thể dùng số 0 mặc định, tên và URL chương vẫn được giữ.',
      if (historyUnknown > 0)
        '$historyUnknown truyện chưa có chương nên không thể xuất lịch sử gắn với URL chương.',
    ],
  );
}

String? _unrepresentable(LibraryBook book) {
  if (book.engine == 'local' || book.sourceId == '0') {
    return 'local được bỏ qua vì cần file nội dung trong bản sao lưu đầy đủ';
  }
  if (book.engine == 'vbook') {
    return 'vBook được bỏ qua vì không dùng nguồn APK của Mihon';
  }
  final source = BigInt.tryParse(book.sourceId);
  if (book.engine != 'tachimanga' ||
      source == null ||
      source < -(BigInt.one << 63) ||
      source > (BigInt.one << 63) - BigInt.one ||
      source.toString() != book.sourceId) {
    return 'không có ID nguồn Tachi kiểu Long hợp lệ, được bỏ qua';
  }
  // Old companion numeric database references are not a verified extension URL.
  if (book.sourceRef.isEmpty ||
      RegExp(r'^-?\d+$').hasMatch(book.sourceRef) ||
      book.chapters.any(
        (chapter) =>
            chapter.id.isEmpty || RegExp(r'^-?\d+$').hasMatch(chapter.id),
      )) {
    return 'chưa có URL truyện/chương ổn định từ extension, được bỏ qua';
  }
  return null;
}

void _validate(LibraryBook book) {
  final count = book.chapters.length;
  if (book.title.trim().isEmpty ||
      count > 10000 ||
      book.currentChapter < 0 ||
      (count == 0 && book.currentChapter != 0) ||
      (count > 0 && book.currentChapter >= count) ||
      !book.progress.isFinite ||
      book.progress < 0 ||
      book.progress > 1 ||
      book.status < 0 ||
      book.status > 0x7fffffff ||
      book.genres.length > 10000 ||
      book.bookmarks.length > 10000) {
    throw const FormatException('Thông tin truyện sao lưu không hợp lệ.');
  }
  final ids = <String>{};
  for (final (index, chapter) in book.chapters.indexed) {
    if (chapter.index != index ||
        chapter.title.trim().isEmpty ||
        !ids.add(chapter.id) ||
        (chapter.number != null && !chapter.number!.isFinite)) {
      throw const FormatException('Mục lục truyện sao lưu không hợp lệ.');
    }
  }
  for (final mark in book.bookmarks) {
    final values = mark.split(':');
    final index = int.tryParse(values.first);
    final fraction = values.length == 2 ? double.tryParse(values.last) : null;
    if (index == null ||
        index < 0 ||
        index >= count ||
        fraction == null ||
        !fraction.isFinite ||
        fraction < 0 ||
        fraction > 1) {
      throw const FormatException('Dấu trang sao lưu không hợp lệ.');
    }
  }
}

int _date(DateTime? date) => date?.millisecondsSinceEpoch ?? 0;
