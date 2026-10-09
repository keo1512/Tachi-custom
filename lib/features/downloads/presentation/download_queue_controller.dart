import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../library/domain/library_book.dart';
import '../../library/domain/library_reading.dart';
import '../../library/data/library_mutation.dart';
import '../../library/presentation/library_view_model.dart';
import '../../settings/settings_controller.dart';
import '../data/download_queue_repository.dart';
import '../domain/download_job.dart';

export '../domain/download_job.dart';

final downloadQueueProvider =
    NotifierProvider<DownloadQueueController, DownloadQueueState>(
      DownloadQueueController.new,
    );
final downloadJobExecutorProvider =
    Provider<Future<void> Function(LibraryBook, int)>((ref) {
      return (book, index) async {
        await ref
            .read(libraryProvider.notifier)
            .getContent(book, index, download: true);
      };
    });

class DownloadQueueController extends Notifier<DownloadQueueState> {
  late DownloadQueueRepository repository;
  final Set<String> _active = {};
  Future<void> _writes = Future<void>.value();

  @override
  DownloadQueueState build() {
    repository = DownloadQueueRepository(ref.read(preferencesProvider));
    ref.listen(
      settingsProvider.select((settings) => settings.downloadConcurrency),
      (_, _) => _pump(),
    );
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
        state = DownloadQueueState(tasks: tasks, running: state.running);
      }
    });
    _writes = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return operation;
  }

  Future<void> enqueue(String bookId, Iterable<String> chapterIds) async {
    if (bookId.isEmpty) throw ArgumentError('Thiếu mã sách');
    final ids = chapterIds.toList();
    if (ids.any((id) => id.isEmpty)) throw ArgumentError('Thiếu mã chương');
    await _change((current) {
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

  Future<void> start() async {
    if (state.storageError != null) throw StateError(state.storageError!);
    state = DownloadQueueState(tasks: state.tasks, running: true);
    _pump();
  }

  void pause() {
    state = DownloadQueueState(
      tasks: state.tasks,
      storageError: state.storageError,
    );
  }

  Future<void> retry() async {
    await _change(
      (tasks) => tasks
          .map(
            (task) => task.status == DownloadJobStatus.failed
                ? task.copyWith(status: DownloadJobStatus.pending, attempts: 0)
                : task,
          )
          .toList(),
    );
    await start();
  }

  void _pump() {
    if (!ref.mounted || !state.running || state.storageError != null) return;
    final limit = ref.read(settingsProvider).downloadConcurrency;
    for (final task in state.tasks) {
      if (_active.length >= limit) break;
      if (task.status != DownloadJobStatus.pending ||
          !_active.add(task.identity)) {
        continue;
      }
      unawaited(_run(task));
    }
    if (_active.isEmpty &&
        !state.tasks.any((task) => task.status == DownloadJobStatus.pending)) {
      pause();
    }
  }

  Future<void> _run(DownloadJob job) async {
    try {
      await _change(
        (tasks) => tasks
            .map(
              (task) => task.identity == job.identity
                  ? task.copyWith(status: DownloadJobStatus.active)
                  : task,
            )
            .toList(),
      );
      if (!ref.mounted) return;
      final book = await ref.read(libraryRepositoryProvider).find(job.bookId);
      if (book == null) throw StateError('Sách đã được xóa khỏi thư viện');
      final index = book.chapters.indexWhere(
        (chapter) => chapter.id == job.chapterId,
      );
      if (index < 0) throw StateError('Chương không còn trong mục lục');
      if (!book.chapters[index].downloaded) {
        await ref.read(downloadJobExecutorProvider)(book, index);
      }
      await _change(
        (tasks) =>
            tasks.where((task) => task.identity != job.identity).toList(),
      );
    } catch (error) {
      try {
        await _change(
          (tasks) => tasks
              .map(
                (task) => task.identity == job.identity
                    ? task.copyWith(
                        status: task.attempts + 1 < 3
                            ? DownloadJobStatus.pending
                            : DownloadJobStatus.failed,
                        error: '$error',
                        attempts: task.attempts + 1,
                      )
                    : task,
              )
              .toList(),
        );
      } catch (writeError) {
        if (ref.mounted) {
          state = DownloadQueueState(
            tasks: state.tasks,
            storageError: '$writeError',
          );
        }
      }
    } finally {
      _active.remove(job.identity);
      _pump();
    }
  }
}
