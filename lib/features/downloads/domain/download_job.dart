import 'dart:convert';

enum DownloadJobStatus { pending, active, failed }

class DownloadJob {
  const DownloadJob({
    required this.bookId,
    required this.chapterId,
    this.status = DownloadJobStatus.pending,
    this.error,
    this.attempts = 0,
  });
  final String bookId, chapterId;
  final DownloadJobStatus status;
  final String? error;
  final int attempts;
  String get identity => jsonEncode([bookId, chapterId]);

  DownloadJob copyWith({
    DownloadJobStatus? status,
    String? error,
    int? attempts,
  }) => DownloadJob(
    bookId: bookId,
    chapterId: chapterId,
    status: status ?? this.status,
    error: error,
    attempts: attempts ?? this.attempts,
  );

  Map<String, dynamic> toJson() => {
    'bookId': bookId,
    'chapterId': chapterId,
    'status': status.name,
    'attempts': attempts,
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
