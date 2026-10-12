import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../library/data/library_mutation.dart';
import '../../library/domain/library_book.dart';
import '../../library/presentation/library_view_model.dart';
import '../../settings/settings_controller.dart';
import 'download_queue_controller.dart';

enum DownloadDeletionEvent { readerLeft, manuallyMarkedRead }

class DownloadDeletionPolicy {
  const DownloadDeletionPolicy({
    this.afterReading = false,
    this.afterManualRead = false,
    this.protectBookmarks = true,
  });
  final bool afterReading, afterManualRead, protectBookmarks;
  Map<String, bool> toJson() => {
    'afterReading': afterReading,
    'afterManualRead': afterManualRead,
    'protectBookmarks': protectBookmarks,
  };
  factory DownloadDeletionPolicy.fromJson(Map<String, dynamic> value) =>
      DownloadDeletionPolicy(
        afterReading: value['afterReading'] == true,
        afterManualRead: value['afterManualRead'] == true,
        protectBookmarks: value['protectBookmarks'] != false,
      );
}

final downloadDeletionProvider =
    NotifierProvider<DownloadDeletionController, DownloadDeletionPolicy>(
      DownloadDeletionController.new,
    );

class DownloadDeletionController extends Notifier<DownloadDeletionPolicy> {
  static const preferenceKey = 'downloadDeletionPolicyV1';
  Future<void> _writes = Future.value();
  @override
  DownloadDeletionPolicy build() {
    final raw = ref.watch(preferencesProvider).getString(preferenceKey);
    try {
      return raw == null
          ? const DownloadDeletionPolicy()
          : DownloadDeletionPolicy.fromJson(
              Map<String, dynamic>.from(jsonDecode(raw) as Map),
            );
    } catch (_) {
      return const DownloadDeletionPolicy();
    }
  }

  Future<void> update({
    bool? afterReading,
    bool? afterManualRead,
    bool? protectBookmarks,
  }) {
    final operation = _writes.then((_) async {
      if (!ref.mounted) return;
      final next = DownloadDeletionPolicy.fromJson({
        ...state.toJson(),
        'afterReading': ?afterReading,
        'afterManualRead': ?afterManualRead,
        'protectBookmarks': ?protectBookmarks,
      });
      if (!await ref
          .read(preferencesProvider)
          .setString(preferenceKey, jsonEncode(next.toJson()))) {
        throw StateError('Không lưu được thiết lập xóa chương.');
      }
      if (ref.mounted) state = next;
    });
    _writes = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return operation;
  }

  Future<int> deleteChapters(
    LibraryBook selection,
    Iterable<String> chapterIds, {
    int? expectedRevision,
  }) => _delete(selection, chapterIds, expectedRevision: expectedRevision);

  /// Invoke after leaving the reader or completing an explicit read action.
  /// Never delete during the reader's live session: deletion invalidates reads.
  Future<int> deleteReadChapters(
    LibraryBook selection,
    Iterable<String> chapterIds, {
    required DownloadDeletionEvent event,
    required int expectedRevision,
  }) {
    if (!ref.mounted) return Future.value(0);
    final enabled = event == DownloadDeletionEvent.readerLeft
        ? state.afterReading
        : state.afterManualRead;
    if (!enabled) return Future.value(0);
    if (selection.engine == 'local') return Future.value(0);
    return _delete(
      selection,
      chapterIds,
      expectedRevision: expectedRevision,
      readOnly: true,
    );
  }

  Future<int> _delete(
    LibraryBook selection,
    Iterable<String> chapterIds, {
    int? expectedRevision,
    bool readOnly = false,
  }) async {
    if (!ref.mounted) return 0;
    final repository = ref.read(libraryRepositoryProvider);
    final revision = expectedRevision ?? repository.replacementRevision;
    checkLibraryRevision(repository.replacementRevision, revision);
    // Cancellation precedes the atomic delete; late HTTP cannot resurrect it.
    await ref.read(downloadQueueProvider.notifier).cancelBook(selection.id);
    if (!ref.mounted) return 0;
    checkLibraryRevision(repository.replacementRevision, revision);
    final deleted = await repository.deleteDownloadedChapters(
      selection,
      chapterIds,
      expectedRevision: revision,
      protectBookmarks: state.protectBookmarks,
      readOnly: readOnly,
    );
    if (ref.mounted && deleted > 0) {
      await ref.read(libraryProvider.notifier).refresh();
    }
    return deleted;
  }
}
