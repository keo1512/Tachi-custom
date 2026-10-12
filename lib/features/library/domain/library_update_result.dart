class LibraryUpdateFailure {
  const LibraryUpdateFailure({
    required this.bookId,
    required this.title,
    required this.message,
    this.sourceIdentity = '',
    this.sourceName = '',
  });

  final String bookId, title, message;
  final String sourceIdentity;
  final String sourceName;
}

class LibraryUpdateSkipped {
  const LibraryUpdateSkipped({
    required this.bookId,
    required this.title,
    required this.reason,
  });
  final String bookId, title, reason;
}

class LibraryUpdateProgress {
  const LibraryUpdateProgress({
    required this.requestedBooks,
    required this.processedBooks,
    required this.checkedBooks,
    required this.addedChapters,
    required this.skippedBooks,
    required this.failedBooks,
    this.currentTitle = '',
  });
  final int requestedBooks,
      processedBooks,
      checkedBooks,
      addedChapters,
      skippedBooks,
      failedBooks;
  final String currentTitle;
  double get fraction =>
      requestedBooks == 0 ? 1 : processedBooks / requestedBooks;
}

class LibraryUpdateResult {
  LibraryUpdateResult({
    required this.requestedBooks,
    required this.checkedBooks,
    required this.addedChapters,
    required this.skippedBooks,
    List<LibraryUpdateFailure> failures = const [],
    List<LibraryUpdateSkipped> skipped = const [],
    this.revision,
  }) : failures = List.unmodifiable(failures),
       skipped = List.unmodifiable(skipped);

  final int requestedBooks, checkedBooks, addedChapters, skippedBooks;
  final List<LibraryUpdateFailure> failures;
  final List<LibraryUpdateSkipped> skipped;
  final int? revision;
  bool get hasErrors => failures.isNotEmpty;
  Map<String, List<LibraryUpdateFailure>> get failuresBySource {
    final grouped = <String, List<LibraryUpdateFailure>>{};
    for (final failure in failures) {
      grouped.putIfAbsent(failure.sourceIdentity, () => []).add(failure);
    }
    return grouped;
  }
}
