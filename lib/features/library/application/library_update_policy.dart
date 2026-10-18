import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../settings/settings_controller.dart';
import '../../../core/format/task_intervals.dart';
import '../domain/library_book.dart';
import '../domain/library_reading.dart';
import '../domain/release_prediction.dart';

class LibraryUpdatePolicy {
  const LibraryUpdatePolicy({
    this.hours = 0,
    this.skipCompleted = true,
    this.skipUnstarted = false,
    this.skipUnread = false,
    this.skipEarly = false,
    this.downloadNew = false,
    this.downloadAhead = 0,
    this.wifiOnly = false,
    this.chargingOnly = false,
    this.checkAll = false,
  });
  static const intervals = automaticTaskIntervalHours;
  final int hours, downloadAhead;
  final bool skipCompleted,
      skipUnstarted,
      skipUnread,
      skipEarly,
      downloadNew,
      wifiOnly,
      chargingOnly,
      checkAll;
  Map<String, dynamic> toJson() => {
    'hours': hours,
    'skipCompleted': skipCompleted,
    'skipUnstarted': skipUnstarted,
    'skipUnread': skipUnread,
    'skipEarly': skipEarly,
    'downloadNew': downloadNew,
    'downloadAhead': downloadAhead,
    'wifiOnly': wifiOnly,
    'chargingOnly': chargingOnly,
    'checkAll': checkAll,
  };
  factory LibraryUpdatePolicy.fromJson(Map<String, dynamic> json) =>
      LibraryUpdatePolicy(
        hours: intervals.contains(json['hours']) ? json['hours'] as int : 0,
        downloadAhead: json['downloadAhead'] is int
            ? (json['downloadAhead'] as int).clamp(0, 10)
            : 0,
        skipCompleted: json['skipCompleted'] is bool
            ? json['skipCompleted'] as bool
            : true,
        skipUnstarted: json['skipUnstarted'] == true,
        skipUnread: json['skipUnread'] == true,
        skipEarly: json['skipEarly'] == true,
        downloadNew: json['downloadNew'] == true,
        wifiOnly: json['wifiOnly'] == true,
        chargingOnly: json['chargingOnly'] == true,
        checkAll: json['checkAll'] == true,
      );
  String? skipReason(LibraryBook book, DateTime now) {
    if (book.engine == 'local') return 'Truyện trên máy';
    if (checkAll) return null;
    if (skipCompleted && (book.completed || [2, 4, 5].contains(book.status))) {
      return 'Đã hoàn thành hoặc ngừng phát hành';
    }
    if (skipUnstarted && book.lastRead == null && readChapterCount(book) == 0) {
      return 'Chưa bắt đầu đọc';
    }
    if (skipUnread && readChapterCount(book) < book.chapters.length) {
      return 'Còn chương chưa đọc';
    }
    final prediction = ReleasePrediction.forBook(book);
    if (skipEarly && prediction != null && now.isBefore(prediction.next)) {
      return 'Chưa đến ngày dự kiến';
    }
    return null;
  }
}

final libraryUpdatePolicyProvider =
    NotifierProvider<LibraryUpdatePolicyController, LibraryUpdatePolicy>(
      LibraryUpdatePolicyController.new,
    );

class LibraryUpdatePolicyController extends Notifier<LibraryUpdatePolicy> {
  Future<void> _pending = Future<void>.value();
  @override
  LibraryUpdatePolicy build() {
    final raw = ref
        .watch(preferencesProvider)
        .getString('libraryUpdatePolicyV1');
    try {
      return raw == null
          ? const LibraryUpdatePolicy()
          : LibraryUpdatePolicy.fromJson(
              Map<String, dynamic>.from(jsonDecode(raw) as Map),
            );
    } catch (_) {
      return const LibraryUpdatePolicy();
    }
  }

  Future<void> patch(Map<String, dynamic> values) {
    final result = _pending.then((_) async {
      final next = LibraryUpdatePolicy.fromJson({...state.toJson(), ...values});
      if (!await ref
          .read(preferencesProvider)
          .setString('libraryUpdatePolicyV1', jsonEncode(next.toJson()))) {
        throw StateError('Không lưu được thiết lập cập nhật.');
      }
      if (ref.mounted) state = next;
    });
    _pending = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }
}
