import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../library/domain/library_book.dart';
import '../../library/domain/library_reading.dart';
import '../../library/data/library_mutation.dart';
import '../../library/presentation/library_view_model.dart';
import '../../settings/settings_controller.dart';
import '../../tasks/application/task_notifications.dart';
import '../../tasks/data/task_platform.dart';
import '../data/download_queue_repository.dart';
import '../domain/download_job.dart';

export '../domain/download_job.dart';

final downloadQueueProvider =
    NotifierProvider<DownloadQueueController, DownloadQueueState>(
      DownloadQueueController.new,
    );
typedef DownloadJobExecutor = Future<void> Function(LibraryBook, int);
typedef GuardedDownloadJobExecutor = Future<void> Function(
  LibraryBook,
  int,
  DownloadExecution,
);

/// The revision and cancellation signal belong to one execution, not a chapter
/// identity: a cancelled chapter can be enqueued again while its HTTP ends.
class DownloadExecution {
  DownloadExecution(this.revision, {this.sourceKey});
  final int revision;
  final String? sourceKey;
  bool _cancelled = false;
  bool get isCancelled => _cancelled;
  DownloadPageProgress? _progress;
  void Function()? _onProgress;

  void reportPageProgress(int completed, int total) {
    if (_cancelled ||
        total <= 0 ||
        total > 100000 ||
        completed < 0 ||
        completed > total) {
      return;
    }
    final previous = _progress;
    if (previous != null &&
        (previous.total != total || completed <= previous.completed)) {
      return;
    }
    _progress = DownloadPageProgress(completed, total);
    _onProgress?.call();
  }
}

final _defaultDownloadJobExecutorProvider = Provider<DownloadJobExecutor>((
  ref,
) {
  return (book, index) async {
    await ref
        .read(libraryProvider.notifier)
        .getContent(book, index, download: true);
  };
});
final downloadJobExecutorProvider = Provider<DownloadJobExecutor>((ref) {
  return ref.watch(_defaultDownloadJobExecutorProvider);
});
final guardedDownloadJobExecutorProvider = Provider<GuardedDownloadJobExecutor>(
  (ref) {
    final executor = ref.watch(downloadJobExecutorProvider);
    if (!identical(executor, ref.watch(_defaultDownloadJobExecutorProvider))) {
      // Preserve the existing test/custom executor contract.
      return (book, index, _) => executor(book, index);
    }
    return (book, index, execution) async {
      await ref
          .read(libraryProvider.notifier)
          .getContent(
            book,
            index,
            download: true,
            expectedRevision: execution.revision,
            isCancelled: () => execution.isCancelled || !ref.mounted,
            onPageProgress: (completed, total) {
              if (!ref.mounted || execution.isCancelled) return;
              execution.reportPageProgress(completed, total);
              final platform = ref.read(taskPlatformProvider);
              if (platform is ContinuedTaskPlatform) {
                unawaited(
                  (platform as ContinuedTaskPlatform)
                      .downloadPageProgress(completed, total)
                      .catchError((Object _) {}),
                );
              }
            },
          );
    };
  },
);

class DownloadQueueController extends Notifier<DownloadQueueState> {
  late DownloadQueueRepository repository;
  final Map<String, DownloadExecution> _active = {};
  Future<void> _writes = Future<void>.value();
  int? _sessionRevision;
  bool _scheduling = false, _pumpRequested = false;
  int _sessionCompleted = 0, _sessionFailed = 0;
  bool _privateSession = false;
  static const _restoredMessage =
      'Thư viện đã được thay đổi hoặc khôi phục. Hàng đợi đã tạm dừng; '
      'kiểm tra các truyện trước khi tiếp tục.';

  DownloadPageProgress? pageProgressFor(String identity) {
    final execution = _active[identity];
    if (execution == null ||
        execution.isCancelled ||
        ref.read(libraryRepositoryProvider).replacementRevision !=
            execution.revision) {
      return null;
    }
    return execution._progress;
  }

  @override
  DownloadQueueState build() {
    repository = DownloadQueueRepository(ref.read(preferencesProvider));
    ref.onDispose(() {
      for (final execution in _active.values) {
        execution._cancelled = true;
      }
    });
    ref.listen(
      settingsProvider.select((settings) => settings.downloadConcurrency),
      (_, _) => _pump(),
    );
    ref.listen(settingsProvider.select((settings) => settings.incognitoMode), (
      _,
      value,
    ) {
      if (value) _privateSession = true;
    });
    try {
      return DownloadQueueState(tasks: repository.load());
    } catch (error) {
      return DownloadQueueState(storageError: '$error');
    }
  }

  Future<void> _change(
    List<DownloadJob> Function(List<DownloadJob>) transform,
  ) {
    final operation = _writes.then((_) async {
      if (!ref.mounted) return;
      if (state.storageError != null) throw StateError(state.storageError!);
      final tasks = transform(state.tasks);
      await repository.save(tasks);
      if (ref.mounted) {
        state = DownloadQueueState(
          tasks: tasks,
          running: state.running,
          pauseReason: state.pauseReason,
        );
      }
    });
    _writes = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return operation;
  }

  Future<void> enqueue(
    String bookId,
    Iterable<String> chapterIds, {
    int? expectedRevision,
  }) async {
    if (bookId.isEmpty) throw ArgumentError('Thiếu mã sách');
    final ids = chapterIds.toList();
    if (ids.any((id) => id.isEmpty)) throw ArgumentError('Thiếu mã chương');
    // A paused queue can be edited before the library is opened. Readers pass
    // an explicit revision; initialized app callers capture the current one.
    final library =
        expectedRevision != null || ref.exists(libraryRepositoryProvider)
        ? ref.read(libraryRepositoryProvider)
        : null;
    final revision = expectedRevision ?? library?.replacementRevision;
    await _change((current) {
      if (library != null && revision != null) {
        checkLibraryRevision(library.replacementRevision, revision);
      }
      final tasks = [...current];
      final identities = current.map((task) => task.identity).toSet();
      for (final chapterId in ids) {
        final job = DownloadJob(bookId: bookId, chapterId: chapterId);
        if (identities.add(job.identity)) tasks.add(job);
      }
      return tasks;
    });
    _pump();
  }

  /// One durable batch using current chapter flags and stable identities.
  Future<int> enqueueBooks(
    Iterable<LibraryBook> books, {
    bool unreadOnly = false,
    int? expectedRevision,
  }) async {
    final library = ref.read(libraryRepositoryProvider);
    final revision = expectedRevision ?? library.replacementRevision;
    final selected = {for (final book in books) book.id: book};
    final jobs = <DownloadJob>[];
    for (final selection in selected.values) {
      checkLibraryRevision(library.replacementRevision, revision);
      final book = await library.find(selection.id);
      checkLibraryRevision(library.replacementRevision, revision);
      if (book == null) continue;
      if (bookSourceIdentity(book) != bookSourceIdentity(selection)) {
        throw StateError('Nguồn của truyện đã thay đổi. Hãy chọn lại truyện.');
      }
      if (book.engine == 'local') continue;
      for (final entry in book.chapters.indexed) {
        if (entry.$2.downloaded ||
            (unreadOnly && chapterIsRead(book, entry.$1))) {
          continue;
        }
        if (book.id.isEmpty || entry.$2.id.isEmpty) {
          throw ArgumentError('Thiếu mã truyện hoặc chương');
        }
        jobs.add(DownloadJob(bookId: book.id, chapterId: entry.$2.id));
      }
    }
    var added = 0;
    await _change((current) {
      checkLibraryRevision(library.replacementRevision, revision);
      final tasks = [...current];
      final identities = current.map((task) => task.identity).toSet();
      for (final job in jobs) {
        if (identities.add(job.identity)) {
          tasks.add(job);
          added++;
        }
      }
      return tasks;
    });
    _pump();
    return added;
  }

  /// N unread, uncached chapters from the latest resume chapter onward.
  Future<int> enqueueNext(
    LibraryBook selection,
    int count, {
    int? expectedRevision,
  }) async {
    if (count < 1 || count > 10000) {
      throw ArgumentError('Số chương phải từ 1 đến 10.000');
    }
    final library = ref.read(libraryRepositoryProvider);
    final revision = expectedRevision ?? library.replacementRevision;
    checkLibraryRevision(library.replacementRevision, revision);
    final book = await library.find(selection.id);
    checkLibraryRevision(library.replacementRevision, revision);
    if (book == null) throw StateError('Sách đã được xóa khỏi thư viện');
    if (bookSourceIdentity(book) != bookSourceIdentity(selection)) {
      throw StateError('Nguồn của truyện đã thay đổi. Hãy chọn lại truyện.');
    }
    if (book.engine == 'local' || book.chapters.isEmpty) return 0;
    final ids = <String>[];
    for (
      var index = book.currentChapter.clamp(0, book.chapters.length - 1);
      index < book.chapters.length && ids.length < count;
      index++
    ) {
      if (!book.chapters[index].downloaded && !chapterIsRead(book, index)) {
        ids.add(book.chapters[index].id);
      }
    }
    var added = 0;
    await _change((current) {
      checkLibraryRevision(library.replacementRevision, revision);
      final identities = current.map((job) => job.identity).toSet();
      final tasks = [...current];
      for (final id in ids) {
        final job = DownloadJob(bookId: book.id, chapterId: id);
        if (id.isEmpty) throw ArgumentError('Thiếu mã chương');
        if (identities.add(job.identity)) {
          tasks.add(job);
          added++;
        }
      }
      return tasks;
    });
    _pump();
    return added;
  }

  Future<void> cancel(String identity) =>
      _cancelWhere((job) => job.identity == identity);

  Future<void> cancelBook(String bookId) =>
      _cancelWhere((job) => job.bookId == bookId);

  Future<void> cancelAll() => _cancelWhere((_) => true);

  /// Capture the chosen identities now, before an earlier durable write settles.
  /// A selection made before a library restore must never target its replacement.
  Future<void> cancelMany(
    Iterable<String> identities, {
    int? expectedRevision,
    void Function()? guard,
  }) {
    final selected = identities.toSet();
    if (selected.any((identity) => identity.isEmpty)) {
      throw ArgumentError('Thiếu mã tác vụ tải xuống');
    }
    if (selected.isEmpty) return Future<void>.value();
    return _cancelWhere(
      (job) => selected.contains(job.identity),
      expectedRevision: expectedRevision,
      guard: guard,
    );
  }

  /// Pauses one durable identity without cancelling independent queued work.
  /// A physical request already issued may finish staging bytes, but its old
  /// execution cannot remove the paused job or mark it complete.
  Future<void> pauseJob(String identity) async {
    try {
      await _change((tasks) {
        final found = tasks.any(
          (task) =>
              task.identity == identity &&
              (task.status == DownloadJobStatus.pending ||
                  task.status == DownloadJobStatus.active),
        );
        if (!found) return tasks;
        _active[identity]?._cancelled = true;
        return [
          for (final task in tasks)
            task.identity == identity
                ? task.copyWith(status: DownloadJobStatus.paused)
                : task,
        ];
      });
    } catch (error) {
      if (ref.mounted) {
        state = DownloadQueueState(tasks: state.tasks, storageError: '$error');
      }
      rethrow;
    }
    _pump();
  }

  /// An explicit single resume while the whole queue is stopped keeps other
  /// waiting jobs paused. Ordinary scheduler.start never resumes these jobs.
  Future<void> resumeJob(String identity) async {
    var found = false;
    await _change((tasks) {
      found = tasks.any(
        (task) =>
            task.identity == identity &&
            task.status == DownloadJobStatus.paused,
      );
      if (!found) return tasks;
      return [
        for (final task in tasks)
          if (task.identity == identity)
            task.copyWith(status: DownloadJobStatus.pending)
          else if (!state.running && task.status == DownloadJobStatus.pending)
            task.copyWith(status: DownloadJobStatus.paused)
          else
            task,
      ];
    });
    if (found) await start();
  }

  /// Explicit user action; policy-driven starts preserve manual job pauses.
  Future<void> resumeAll() async {
    await _change(
      (tasks) => [
        for (final task in tasks)
          if (task.status == DownloadJobStatus.paused)
            task.copyWith(status: DownloadJobStatus.pending)
          else if (task.status == DownloadJobStatus.failed)
            task.copyWith(status: DownloadJobStatus.pending, attempts: 0)
          else
            task,
      ],
    );
    await start();
  }

  Future<void> _cancelWhere(
    bool Function(DownloadJob) matches, {
    int? expectedRevision,
    void Function()? guard,
  }) async {
    final library = expectedRevision == null
        ? null
        : ref.read(libraryRepositoryProvider);
    var validated = false;
    try {
      await _change((tasks) {
        guard?.call();
        if (library != null) {
          checkLibraryRevision(library.replacementRevision, expectedRevision);
        }
        validated = true;
        for (final task in tasks.where(matches)) {
          _active[task.identity]?._cancelled = true;
        }
        return tasks.where((task) => !matches(task)).toList();
      });
    } catch (error) {
      // Stop active requests even when the durable cancellation fails. Preserve
      // the persisted queue and expose the write error instead of leaving a
      // cancelled execution displayed as working indefinitely.
      if (ref.mounted && validated) {
        state = DownloadQueueState(tasks: state.tasks, storageError: '$error');
      }
      rethrow;
    }
    _pump();
  }

  /// Identity-based moves remain correct when a download finishes during drag.
  /// A null destination moves to the end; a vanished destination rejects a
  /// stale gesture rather than guessing an index in the shorter queue.
  Future<void> moveBefore(String identity, String? beforeIdentity) async {
    await _change((tasks) {
      if (identity == beforeIdentity) return tasks;
      final index = tasks.indexWhere((job) => job.identity == identity);
      if (index < 0) return tasks;
      final moved = tasks[index];
      final reordered = [...tasks]..removeAt(index);
      final target = beforeIdentity == null
          ? reordered.length
          : reordered.indexWhere((job) => job.identity == beforeIdentity);
      if (target < 0) throw StateError('Hàng đợi đã thay đổi. Hãy kéo lại.');
      reordered.insert(target, moved);
      return reordered;
    });
    _pump();
  }

  Future<void> moveBookBefore(String bookId, String? beforeBookId) async {
    await _change((tasks) {
      if (bookId == beforeBookId) return tasks;
      final moved = tasks.where((job) => job.bookId == bookId).toList();
      if (moved.isEmpty) return tasks;
      final reordered = tasks.where((job) => job.bookId != bookId).toList();
      final target = beforeBookId == null
          ? reordered.length
          : reordered.indexWhere((job) => job.bookId == beforeBookId);
      if (target < 0) throw StateError('Hàng đợi đã thay đổi. Hãy kéo lại.');
      reordered.insertAll(target, moved);
      return reordered;
    });
    _pump();
  }

  Future<void> downloadNow(String identity) =>
      _prioritize((job) => job.identity == identity);

  Future<void> downloadBookNow(String bookId) =>
      _prioritize((job) => job.bookId == bookId);

  Future<void> _prioritize(bool Function(DownloadJob) matches) async {
    var found = false;
    await _change((tasks) {
      found = tasks.any(matches);
      return [
        for (final task in tasks.where(matches))
          task.status == DownloadJobStatus.failed ||
                  task.status == DownloadJobStatus.paused
              ? task.copyWith(status: DownloadJobStatus.pending, attempts: 0)
              : task,
        ...tasks.where((task) => !matches(task)),
      ];
    });
    if (found) await start();
  }

  Future<void> start() async {
    if (state.storageError != null) throw StateError(state.storageError!);
    if (!state.running) {
      _sessionRevision = ref
          .read(libraryRepositoryProvider)
          .replacementRevision;
      _sessionCompleted = 0;
      _sessionFailed = 0;
      _privateSession = ref.read(settingsProvider).incognitoMode;
    }
    state = DownloadQueueState(tasks: state.tasks, running: true);
    _pump();
  }

  void pause({String? reason}) {
    state = DownloadQueueState(
      tasks: state.tasks,
      storageError: state.storageError,
      pauseReason: reason,
    );
  }

  /// End a finite iOS execution window without deleting queued work or cache.
  /// In-flight requests observe cancellation; persisted active jobs also reload
  /// as pending if iOS suspends before this write completes.
  Future<void> suspendForBackground({String? reason}) async {
    pause(
      reason:
          reason ?? 'iOS đã hết thời gian chạy nền. Bấm Tiếp tục để tải tiếp.',
    );
    for (final execution in _active.values) {
      execution._cancelled = true;
    }
    try {
      await _change(
        (tasks) => [
          for (final task in tasks)
            task.status == DownloadJobStatus.active
                ? task.copyWith(status: DownloadJobStatus.pending)
                : task,
        ],
      );
    } catch (error) {
      if (ref.mounted) {
        state = DownloadQueueState(tasks: state.tasks, storageError: '$error');
      }
      rethrow;
    }
  }

  Future<void> retry({int? expectedRevision, void Function()? guard}) async {
    final library = expectedRevision == null
        ? null
        : ref.read(libraryRepositoryProvider);
    void check() {
      guard?.call();
      if (library != null) {
        checkLibraryRevision(library.replacementRevision, expectedRevision);
      }
    }

    await _change((tasks) {
      check();
      return tasks
          .map(
            (task) => task.status == DownloadJobStatus.failed
                ? task.copyWith(status: DownloadJobStatus.pending, attempts: 0)
                : task,
          )
          .toList();
    });
    check();
    await start();
  }

  void _pump() {
    if (!ref.mounted || !state.running || state.storageError != null) return;
    if (_scheduling) {
      _pumpRequested = true;
      return;
    }
    if (_sessionRevision !=
        ref.read(libraryRepositoryProvider).replacementRevision) {
      pause(reason: _restoredMessage);
      return;
    }
    _scheduling = true;
    unawaited(_schedule());
  }

  String _sourceKey(LibraryBook book) =>
      jsonEncode([book.engine, book.sourceId]);

  Future<void> _schedule() async {
    try {
      final library = ref.read(libraryRepositoryProvider);
      final revision = library.replacementRevision;
      final books = <String, LibraryBook?>{};
      for (final task in [...state.tasks]) {
        if (!ref.mounted || !state.running || state.storageError != null) {
          return;
        }
        // A logically paused request still occupies a physical HTTP slot until
        // it settles. Keep both total and per-source concurrency bounds.
        if (_active.length >= ref.read(settingsProvider).downloadConcurrency) {
          break;
        }
        if (task.status != DownloadJobStatus.pending ||
            _active.containsKey(task.identity)) {
          continue;
        }
        LibraryBook? book;
        try {
          if (!books.containsKey(task.bookId)) {
            books[task.bookId] = await library.find(task.bookId);
          }
          book = books[task.bookId];
        } catch (_) {
          // Let the ordinary execution surface/retry this lookup failure.
        }
        if (!ref.mounted || !state.running || state.storageError != null) {
          return;
        }
        if (library.replacementRevision != revision) {
          pause(reason: _restoredMessage);
          return;
        }
        if (!state.tasks.any(
              (current) =>
                  current.identity == task.identity &&
                  current.status == DownloadJobStatus.pending,
            ) ||
            _active.containsKey(task.identity)) {
          continue;
        }
        final sourceKey = book == null ? task.identity : _sourceKey(book);
        // A saturated source never blocks independent sources behind it.
        if (_active.values.any((active) => active.sourceKey == sourceKey)) {
          continue;
        }
        final execution = DownloadExecution(revision, sourceKey: sourceKey);
        _active[task.identity] = execution;
        unawaited(_run(task, execution));
      }
      if (ref.mounted &&
          _active.isEmpty &&
          !state.tasks.any(
            (task) => task.status == DownloadJobStatus.pending,
          )) {
        pause();
        final completed = _sessionCompleted, failed = _sessionFailed;
        _sessionCompleted = 0;
        _sessionFailed = 0;
        await ref
            .read(taskNotificationsProvider.notifier)
            .summary(
              'downloads',
              completed,
              failed,
              privateSession: _privateSession,
            );
      }
    } finally {
      _scheduling = false;
      if (_pumpRequested) {
        _pumpRequested = false;
        _pump();
      }
    }
  }

  Future<void> _run(DownloadJob job, DownloadExecution execution) async {
    var sourceChanged = false;
    bool current() =>
        ref.mounted &&
        !execution.isCancelled &&
        identical(_active[job.identity], execution);
    execution._onProgress = () {
      if (!current() ||
          ref.read(libraryRepositoryProvider).replacementRevision !=
              execution.revision) {
        return;
      }
      state = DownloadQueueState(
        tasks: state.tasks,
        running: state.running,
        storageError: state.storageError,
        pauseReason: state.pauseReason,
      );
    };
    try {
      await _change(
        (tasks) => !current()
            ? tasks
            : tasks
                  .map(
                    (task) => task.identity == job.identity
                        ? task.copyWith(status: DownloadJobStatus.active)
                        : task,
                  )
                  .toList(),
      );
      if (!current()) return;
      final library = ref.read(libraryRepositoryProvider);
      checkLibraryRevision(library.replacementRevision, execution.revision);
      final book = await library.find(job.bookId);
      if (!current()) return;
      checkLibraryRevision(library.replacementRevision, execution.revision);
      if (book == null) throw StateError('Sách đã được xóa khỏi thư viện');
      if (_sourceKey(book) != execution.sourceKey) {
        sourceChanged = true;
        throw StateError('Nguồn của truyện đã thay đổi. Hãy tải lại truyện.');
      }
      final index = book.chapters.indexWhere(
        (chapter) => chapter.id == job.chapterId,
      );
      if (index < 0) throw StateError('Chương không còn trong mục lục');
      if (!book.chapters[index].downloaded) {
        await ref.read(guardedDownloadJobExecutorProvider)(
          book,
          index,
          execution,
        );
      }
      if (!current()) return;
      await _change(
        (tasks) => !current()
            ? tasks
            : tasks.where((task) => task.identity != job.identity).toList(),
      );
      if (current()) _sessionCompleted++;
    } catch (error) {
      if (!current()) return;
      final stale =
          ref.read(libraryRepositoryProvider).replacementRevision !=
          execution.revision;
      if (stale) pause(reason: _restoredMessage);
      try {
        await _change(
          (tasks) => !current()
              ? tasks
              : tasks
                    .map(
                      (task) => task.identity == job.identity
                          ? task.copyWith(
                              status:
                                  !stale &&
                                      !sourceChanged &&
                                      task.attempts + 1 < 3
                                  ? DownloadJobStatus.pending
                                  : DownloadJobStatus.failed,
                              error: '$error',
                              attempts: task.attempts + 1,
                            )
                          : task,
                    )
                    .toList(),
        );
        if (current() &&
            state.tasks.any(
              (task) =>
                  task.identity == job.identity &&
                  task.status == DownloadJobStatus.failed,
            )) {
          _sessionFailed++;
        }
      } catch (writeError) {
        if (ref.mounted) {
          state = DownloadQueueState(
            tasks: state.tasks,
            storageError: '$writeError',
          );
        }
      }
    } finally {
      execution._onProgress = null;
      if (identical(_active[job.identity], execution)) {
        _active.remove(job.identity);
      }
      _pump();
    }
  }
}
