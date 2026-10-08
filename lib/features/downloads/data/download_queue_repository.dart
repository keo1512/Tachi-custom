import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../domain/download_job.dart';

class DownloadQueueRepository {
  DownloadQueueRepository(this.preferences);
  final SharedPreferences preferences;
  static const key = 'downloadQueueV1';

  List<DownloadJob> load() {
    if (!preferences.containsKey(key)) return [];
    Object? envelope;
    try {
      final raw = preferences.getString(key);
      envelope = raw == null ? null : jsonDecode(raw);
    } catch (_) {
      throw const FormatException(
        'Không đọc được hàng đợi tải xuống. Dữ liệu gốc được giữ nguyên.',
      );
    }
    if (envelope is! Map ||
        envelope['version'] != 1 ||
        envelope['tasks'] is! List) {
      throw const FormatException(
        'Định dạng hàng đợi tải xuống không hợp lệ. Dữ liệu gốc được giữ nguyên.',
      );
    }
    final result = <DownloadJob>[];
    final identities = <String>{};
    for (final item in envelope['tasks'] as List) {
      if (item is! Map ||
          item['bookId'] is! String ||
          (item['bookId'] as String).isEmpty ||
          item['chapterId'] is! String ||
          (item['chapterId'] as String).isEmpty ||
          !DownloadJobStatus.values.any(
            (status) => status.name == item['status'],
          ) ||
          (item['error'] != null && item['error'] is! String)) {
        throw const FormatException(
          'Mục tải xuống không hợp lệ. Dữ liệu gốc được giữ nguyên.',
        );
      }
      final status = DownloadJobStatus.values.firstWhere(
        (status) => status.name == item['status'],
      );
      final job = DownloadJob(
        bookId: item['bookId'] as String,
        chapterId: item['chapterId'] as String,
        status: status == DownloadJobStatus.active
            ? DownloadJobStatus.pending
            : status,
        error: item['error'] as String?,
      );
      if (!identities.add(job.identity)) {
        throw const FormatException(
          'Mã chương trong hàng đợi bị trùng. Dữ liệu gốc được giữ nguyên.',
        );
      }
      result.add(job);
    }
    return result;
  }

  Future<void> save(List<DownloadJob> tasks) async {
    final saved = await preferences.setString(
      key,
      jsonEncode({
        'version': 1,
        'tasks': tasks.map((task) => task.toJson()).toList(),
      }),
    );
    if (!saved) throw StateError('Không lưu được hàng đợi tải xuống');
  }
}
