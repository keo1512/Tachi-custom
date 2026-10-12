import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:archive/archive.dart';

import 'bounded_archive.dart';
import 'external_library.dart';
import 'protobuf_reader.dart';
import 'mihon_tracking.dart';
import '../../domain/external_backup_metadata.dart';

// Schema: Mihon official Kotlin @ProtoNumber models, pinned at
// https://github.com/mihonapp/mihon/tree/dd46413e1017c145df660f0ac714fe30bff69d0e/app/src/main/java/eu/kanade/tachiyomi/data/backup/models
Future<ConvertedBackup> readMihonBackup(Uint8List bytes) =>
    Isolate.run(() => _read(_gunzip(bytes)));

ConvertedBackup _read(Uint8List bytes) {
  final root = ProtoMessage(bytes);
  if (root.fields.isNotEmpty &&
      !root.fields.keys.any([1, 2, 101, 103, 104].contains)) {
    throw const FormatException(
      'Không tìm thấy thư viện trong protobuf Mihon/Tachiyomi.',
    );
  }
  final categories = <BigInt, String>{};
  for (final category in root.messages(2)) {
    final id = category.one(3) == null
        ? category.integer(2)
        : category.integer(3);
    if (categories.containsKey(id)) {
      throw const FormatException('ID danh mục protobuf bị trùng.');
    }
    categories[id] = category.string(1, required: true);
  }
  final titles = <ExternalTitle>[];
  var historyOnly = 0;
  var unknownCategories = 0;
  var sourceMemos = 0;
  var trackers = 0;
  for (final manga in root.messages(1)) {
    if (!manga.boolean(100, fallback: true)) {
      historyOnly++;
      continue;
    }
    final source = manga.integer(1, required: true).toString();
    final history = manga.messages(104)
      ..sort((a, b) => b.integer(2).compareTo(a.integer(2)));
    final categoryNames = <String>[];
    for (final id in manga.integers(17)) {
      final name = categories[id];
      if (name != null) {
        categoryNames.add(name);
      } else {
        unknownCategories++;
      }
    }
    final last = history.firstOrNull;
    final url = manga.string(2, required: true);
    final trackingFields = manga.fields[18] ?? const <ProtoField>[];
    if (trackingFields.length > ExternalBackupMetadata.maxTrackers) {
      throw const FormatException(
        'Sao lưu có quá nhiều tracker cho một truyện.',
      );
    }
    final tracking = <String>[];
    for (final field in trackingFields) {
      if (field.wire != 2) {
        throw const FormatException('Message tracker protobuf không hợp lệ.');
      }
      final bytes = field.value as Uint8List;
      validateMihonTracking(bytes, manga.budget);
      tracking.add(base64Encode(bytes));
    }
    trackers += tracking.length;
    final memoField = manga.one(112);
    if (memoField != null && memoField.wire != 2) {
      throw const FormatException('Memo nguồn protobuf không hợp lệ.');
    }
    final memo = memoField == null
        ? null
        : base64Encode(memoField.value as Uint8List);
    if (memo != null) sourceMemos++;
    titles.add(
      ExternalTitle(
        source: source,
        url: url,
        title: manga.string(3),
        author: manga.string(5),
        artist: manga.string(4),
        genres: manga.strings(7),
        notes: manga.string(110),
        externalBackupMetadata: tracking.isEmpty && memo == null
            ? null
            : ExternalBackupMetadata(
                format: 'mihon-protobuf-v0.20.4',
                engine: 'tachimanga',
                sourceId: source,
                sourceRef: url,
                tracking: tracking,
                memo: memo,
              ),
        description: manga.string(6),
        status: manga.integer(8).toInt(),
        createdAt: manga.integer(13).toInt(),
        cover: manga.string(9),
        categories: categoryNames,
        lastRead: last?.integer(2, required: true).toInt() ?? 0,
        lastChapter: last?.string(1, required: true) ?? '',
        chapters: manga
            .messages(16)
            .map(
              (chapter) => ExternalChapter(
                url: chapter.string(1, required: true),
                title: chapter.string(2, required: true),
                order: chapter.integer(10).toInt(),
                read: chapter.boolean(4),
                bookmarked: chapter.boolean(5),
                lastPage: chapter.integer(6).toInt(),
                fetchedAt: chapter.integer(7).toInt(),
                uploadedAt: chapter.integer(8).toInt(),
                scanlator: chapter.string(3),
                number: chapter.floatingPoint(9),
              ),
            )
            .toList(),
      ),
    );
  }
  return convertExternalLibrary(
    'Mihon / Tachiyomi protobuf gzip',
    titles,
    warnings: [
      if (historyOnly > 0)
        '$historyOnly truyện chỉ có trong lịch sử, không thuộc thư viện gốc, được bỏ qua.',
      if (unknownCategories > 0)
        '$unknownCategories liên kết danh mục không tìm thấy tên, được bỏ qua.',
      if (sourceMemos > 0)
        '$sourceMemos memo riêng của nguồn được giữ nguyên bytes cùng nguồn gốc, '
            'không thực thi hoặc áp dụng cho nguồn khác.',
      if (trackers > 0)
        '$trackers liên kết tracker được giữ trong sao lưu; chưa tự đồng bộ '
            'với dịch vụ theo dõi.',
    ],
  );
}

Uint8List _gunzip(Uint8List bytes) {
  if (bytes.length < 20 ||
      bytes[0] != 31 ||
      bytes[1] != 139 ||
      bytes[2] != 8 ||
      bytes[3] & 0xe0 != 0) {
    throw const FormatException('Header gzip sao lưu không hợp lệ.');
  }
  final input = InputMemoryStream(bytes);
  input.readBytes(10);
  final flags = bytes[3];
  if (flags & 4 != 0) {
    if (input.length < 2) {
      throw const FormatException('Header gzip bị cắt ngắn.');
    }
    final length = input.readUint16();
    if (length > input.length) {
      throw const FormatException('Header gzip bị cắt ngắn.');
    }
    input.readBytes(length);
  }
  for (final flag in [8, 16]) {
    if (flags & flag != 0) {
      var ended = false;
      while (!input.isEOS) {
        if (input.readByte() == 0) {
          ended = true;
          break;
        }
      }
      if (!ended) throw const FormatException('Header gzip bị cắt ngắn.');
    }
  }
  if (flags & 2 != 0) {
    if (input.length < 2) {
      throw const FormatException('Header gzip bị cắt ngắn.');
    }
    final expected = getCrc32(bytes.sublist(0, input.position)) & 0xffff;
    if (input.readUint16() != expected) {
      throw const FormatException('CRC header gzip không đúng.');
    }
  }
  if (input.length < 10) throw const FormatException('Gzip bị cắt ngắn.');
  final output = BoundedBackupOutput(128 * 1024 * 1024);
  Inflate.stream(input, output: output);
  if (input.length != 8) {
    throw const FormatException(
      'Gzip bị cắt ngắn hoặc có nhiều member chưa hỗ trợ.',
    );
  }
  final crc = input.readUint32();
  final size = input.readUint32();
  final result = output.getBytes();
  if (size != result.length || getCrc32(result) != crc) {
    throw const FormatException('CRC hoặc kích thước gzip không đúng.');
  }
  return result;
}
