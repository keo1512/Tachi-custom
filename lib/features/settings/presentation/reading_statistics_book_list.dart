import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/widgets/feedback.dart';
import '../../library/application/reading_statistics_controller.dart';
import '../../library/domain/library_book.dart';
import '../../library/domain/library_reading.dart';
import '../../library/domain/reading_statistics.dart';
import '../../library/presentation/library_view_model.dart';
import '../../privacy/application/app_lock_controller.dart';
import 'settings_widgets.dart';

class ReadingStatisticsBookList extends ConsumerStatefulWidget {
  const ReadingStatisticsBookList({super.key, this.initialBookId});
  final String? initialBookId;
  @override
  ConsumerState<ReadingStatisticsBookList> createState() =>
      _BookStatisticsState();
}

class _BookStatisticsState extends ConsumerState<ReadingStatisticsBookList> {
  String query = '';
  String? selectedBookId;
  bool saving = false;

  @override
  void initState() {
    super.initState();
    selectedBookId = widget.initialBookId;
  }

  void _guard() {
    final lock = ref.read(appLockProvider);
    if (!mounted || lock.locked || lock.obscured) {
      throw StateError('Hãy mở khóa ứng dụng và thử lại.');
    }
  }

  Future<void> _save(Future<void> Function(int revision) action) async {
    if (saving) return;
    setState(() => saving = true);
    try {
      await perform(context, () async {
        _guard();
        final revision = ref
            .read(libraryRepositoryProvider)
            .replacementRevision;
        await action(revision);
        if (!mounted) return;
        await ref.read(libraryProvider.notifier).refresh();
      });
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  Future<void> _chooseState(LibraryBook book) async {
    final repository = ref.read(libraryRepositoryProvider);
    final revision = repository.replacementRevision;
    final state = await showCupertinoModalPopup<String>(
      context: context,
      builder: (dialogContext) => CupertinoActionSheet(
        title: Text(book.title),
        message: const Text(
          'Trạng thái do bạn chọn được lưu cùng truyện. Chọn hoàn thành áp dụng '
          'cờ hoàn thành hiện có; các lựa chọn khác giữ vị trí đọc và nội dung đã tải.',
        ),
        actions: [
          for (final state in ['planned', 'reading', 'paused', 'completed'])
            CupertinoActionSheetAction(
              key: ValueKey('statistics-state-$state'),
              onPressed: () => Navigator.pop(dialogContext, state),
              child: Text(readingStateLabel(state)),
            ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.pop(dialogContext),
          child: const Text('Hủy'),
        ),
      ),
    );
    if (!mounted || state == null) return;
    await _save(
      (_) => ReadingStatisticsEditor(repository).setReadingState(
        book.id,
        state,
        expectedRevision: revision,
        guard: _guard,
      ),
    );
  }

  Future<void> _chooseRating(LibraryBook book) async {
    final repository = ref.read(libraryRepositoryProvider);
    final revision = repository.replacementRevision;
    var rating = book.rating != null && book.rating!.isFinite
        ? book.rating!.clamp(0, 10).toDouble()
        : 5.0;
    final choice = await showCupertinoDialog<_RatingChoice>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (_, update) => CupertinoAlertDialog(
          title: Text(book.title),
          content: Column(
            children: [
              const SizedBox(height: 8),
              Text('Đánh giá của bạn: ${rating.toStringAsFixed(1)}/10'),
              CupertinoSlider(
                key: const ValueKey('statistics-rating-slider'),
                value: rating,
                min: 0,
                max: 10,
                divisions: 20,
                onChanged: (value) => update(() => rating = value),
              ),
            ],
          ),
          actions: [
            CupertinoDialogAction(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Hủy'),
            ),
            if (book.rating != null)
              CupertinoDialogAction(
                onPressed: () =>
                    Navigator.pop(dialogContext, const _RatingChoice(null)),
                child: const Text('Xóa đánh giá'),
              ),
            CupertinoDialogAction(
              key: const ValueKey('statistics-rating-save'),
              onPressed: () =>
                  Navigator.pop(dialogContext, _RatingChoice(rating)),
              child: const Text('Lưu'),
            ),
          ],
        ),
      ),
    );
    if (!mounted || choice == null) return;
    await _save(
      (_) => ReadingStatisticsEditor(repository).setRating(
        book.id,
        choice.rating,
        expectedRevision: revision,
        guard: _guard,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final statistics = ref.watch(readingStatisticsProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Thống kê từng truyện')),
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: CupertinoSearchTextField(
                placeholder: 'Tìm truyện',
                onChanged: (value) =>
                    setState(() => query = value.trim().toLowerCase()),
              ),
            ),
            if (selectedBookId != null)
              TextButton(
                onPressed: () => setState(() => selectedBookId = null),
                child: const Text('Hiện tất cả truyện'),
              ),
            Expanded(
              child: statistics.when(
                loading: () =>
                    const Center(child: CupertinoActivityIndicator()),
                error: (error, _) =>
                    Center(child: SettingsNote(userFacingError(error))),
                data: (stats) {
                  final books =
                      stats.books
                          .where(
                            (book) =>
                                (selectedBookId == null ||
                                    book.id == selectedBookId) &&
                                book.title.toLowerCase().contains(query),
                          )
                          .toList()
                        ..sort(
                          (left, right) => left.title.compareTo(right.title),
                        );
                  if (books.isEmpty) {
                    return const Center(
                      child: Text('Không có truyện phù hợp.'),
                    );
                  }
                  return ListView.builder(
                    itemCount: books.length,
                    itemBuilder: (_, index) {
                      final book = books[index];
                      return Padding(
                        padding: const EdgeInsets.fromLTRB(16, 10, 16, 18),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              book.title,
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                            const SizedBox(height: 5),
                            Text(
                              '${readChapterCount(book)}/${book.chapters.length} chương đã đọc '
                              '· ${stats.downloadedChapterCount(book)} chương offline',
                            ),
                            const SizedBox(height: 6),
                            LinearProgressIndicator(
                              value: stats.progressOf(book),
                            ),
                            if (book.lastRead != null)
                              Padding(
                                padding: const EdgeInsets.only(top: 6),
                                child: Text(
                                  'Đọc gần nhất: ${book.lastRead!.day}/${book.lastRead!.month}/${book.lastRead!.year}',
                                ),
                              ),
                            Wrap(
                              spacing: 8,
                              children: [
                                TextButton(
                                  key: ValueKey('statistics-state-${book.id}'),
                                  onPressed: saving
                                      ? null
                                      : () => _chooseState(book),
                                  child: Text(
                                    readingStateLabel(readingStateOf(book)),
                                  ),
                                ),
                                TextButton(
                                  key: ValueKey('statistics-rating-${book.id}'),
                                  onPressed: saving
                                      ? null
                                      : () => _chooseRating(book),
                                  child: Text(
                                    book.rating == null
                                        ? 'Thêm đánh giá'
                                        : '${book.rating!.toStringAsFixed(1)}/10 · Đổi đánh giá',
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RatingChoice {
  const _RatingChoice(this.rating);
  final double? rating;
}
