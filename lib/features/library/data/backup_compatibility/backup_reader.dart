import 'dart:typed_data';

import '../backup_validation.dart';
import '../library_repository.dart';
import '../library_snapshot.dart';
import 'external_library.dart';
import 'mihon_backup.dart';
import 'tachimanga_backup.dart';

/// Format detection is based on bytes, never on an untrusted filename.
Future<ConvertedBackup> readCompatibleBackup(
  Uint8List bytes,
  LibraryRepository repository,
) async {
  if (bytes.isEmpty || bytes.length > LibrarySnapshot.maxBytes) {
    throw const FormatException('Bản sao lưu trống hoặc vượt giới hạn 128 MB.');
  }
  final ConvertedBackup converted;
  if (bytes.length >= 4 &&
      bytes[0] == 80 &&
      bytes[1] == 75 &&
      bytes[2] == 3 &&
      bytes[3] == 4) {
    converted = await readTachimangaBackup(bytes);
  } else if (bytes.length >= 2 && bytes[0] == 31 && bytes[1] == 139) {
    converted = await readMihonBackup(bytes);
  } else {
    try {
      final entries = BackupValidator(repository).validate(bytes);
      return ConvertedBackup(
        'TachiBooks JSON v1',
        LibrarySnapshot(entries),
        const [
          'Nhập toàn bộ nội dung đã lưu trong bản sao lưu, gồm EPUB/TXT/CBZ đã nhập. '
              'Sách đã có trong thư viện hiện tại được giữ nguyên.',
        ],
      );
    } on FormatException catch (error) {
      throw FormatException(
        '${error.message} '
        'Hỗ trợ TachiBooks JSON v1, Tachimanga .tmb build511/type0 và '
        'protobuf gzip Mihon/Tachiyomi. Chưa có mẫu sao lưu vBook để kiểm chứng.',
      );
    }
  }
  // External adapters must obey the same validation as native backup files.
  BackupValidator(repository).validate(converted.snapshot.encode());
  return converted;
}
