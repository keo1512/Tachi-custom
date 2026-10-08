import 'dart:convert';

enum DownloadJobStatus { pending, active, failed }

class DownloadJob {
  const DownloadJob({
    required this.bookId,
    required this.chapterId,
    this.status = DownloadJobStatus.pending,
    this.error,
  });
  final String bookId, chapterId;
  final DownloadJobStatus status;
  final String? error;
  String get identity => jsonEncode([bookId, chapterId]);

  DownloadJob copyWith({DownloadJobStatus? status, String? error}) =>
      DownloadJob(
        bookId: bookId,
        chapterId: chapterId,
        status: status ?? this.status,
        error: error,
      );

  Map<String, dynamic> toJson() => {
    'bookId': bookId,
    'chapterId': chapterId,
    'status': status.name,
    if (error != null) 'error': error,
  };
}

class DownloadQueueState {
  DownloadQueueState({
    List<DownloadJob> tasks = const [],
    this.running = false,
    this.storageError,
  }) : tasks = List.unmodifiable(tasks);
  final List<DownloadJob> tasks;
  final bool running;
  final String? storageError;
}
