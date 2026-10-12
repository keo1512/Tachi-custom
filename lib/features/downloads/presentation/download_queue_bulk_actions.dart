import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/widgets/feedback.dart';
import '../../library/data/library_mutation.dart';
import '../../library/domain/library_book.dart';
import '../../library/presentation/library_view_model.dart';
import '../../privacy/application/app_lock_controller.dart';
import '../../settings/settings_controller.dart';
import 'download_queue_controller.dart';

/// Queue management stays within the existing downloads screen. Completed
/// chapters live in RecentDownloadsScreen, so these counts only describe work
/// still recorded in the durable queue.
class DownloadQueueBulkActions extends ConsumerStatefulWidget {
  const DownloadQueueBulkActions({super.key});

  @override
  ConsumerState<DownloadQueueBulkActions> createState() =>
      _DownloadQueueBulkActionsState();
}

class _DownloadQueueBulkActionsState
    extends ConsumerState<DownloadQueueBulkActions> {
  int _privacyEpoch = 0;
  bool _busy = false;

  void _guard(int revision, int epoch) {
    final lock = ref.read(appLockProvider);
    if (!mounted ||
        epoch != _privacyEpoch ||
        !lock.initialized ||
        !lock.configurationValid ||
        lock.locked ||
        lock.obscured ||
        lock.authenticating) {
      throw StateError('Thao tác đã dừng. Hãy mở khóa và chọn lại tác vụ.');
    }
    checkLibraryRevision(
      ref.read(libraryRepositoryProvider).replacementRevision,
      revision,
    );
  }

  Future<void> _action(String action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await perform(context, () async {
        await ref.read(appLockProvider.notifier).initialize();
        if (!mounted) return;
        final revision = ref
            .read(libraryRepositoryProvider)
            .replacementRevision;
        final epoch = _privacyEpoch;
        void guard() => _guard(revision, epoch);
        guard();
        final controller = ref.read(downloadQueueProvider.notifier);
        if (action == 'retry') {
          await controller.retry(expectedRevision: revision, guard: guard);
          return;
        }
        final tasks = ref.read(downloadQueueProvider).tasks;
        final books = <String, LibraryBook>{
          for (final book in ref.read(libraryProvider).value ?? <LibraryBook>[])
            book.id: book,
        };
        final choices = [
          for (final task in tasks)
            (
              identity: task.identity,
              book:
                  books[task.bookId]?.title ?? 'Sách không còn trong thư viện',
              chapter:
                  books[task.bookId]?.chapters
                      .where((chapter) => chapter.id == task.chapterId)
                      .firstOrNull
                      ?.title ??
                  'Chương không còn trong mục lục',
            ),
        ];
        if (choices.isEmpty) return;
        final selected = await showModalBottomSheet<Set<String>>(
          context: context,
          isScrollControlled: true,
          useSafeArea: true,
          builder: (_) => _QueueCancellationPicker(choices: choices),
        );
        if (!mounted || selected == null || selected.isEmpty) return;
        guard();
        await controller.cancelMany(
          selected,
          expectedRevision: revision,
          guard: guard,
        );
        if (mounted) message(context, 'Đã hủy các tác vụ đã chọn');
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(appLockProvider, (previous, next) {
      if (next.locked ||
          next.obscured ||
          next.authenticating ||
          !next.configurationValid ||
          (previous?.initialized == true && !next.initialized)) {
        _privacyEpoch++;
      }
    });
    ref.listen(
      settingsProvider.select((settings) => settings.incognitoMode),
      (_, _) => _privacyEpoch++,
    );
    final queue = ref.watch(downloadQueueProvider);
    int count(DownloadJobStatus status) =>
        queue.tasks.where((task) => task.status == status).length;
    final failed = count(DownloadJobStatus.failed);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '${queue.tasks.length} chương trong hàng đợi · '
            '${count(DownloadJobStatus.active)} đang tải · '
            '${count(DownloadJobStatus.pending)} chờ · '
            '${count(DownloadJobStatus.paused)} tạm dừng · $failed lỗi',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall,
          ),
          PopupMenuButton<String>(
            tooltip: 'Quản lý nhiều tác vụ tải xuống',
            enabled: !_busy && queue.storageError == null,
            onSelected: _action,
            itemBuilder: (_) => [
              if (failed > 0)
                const PopupMenuItem(
                  value: 'retry',
                  child: Text('Thử lại tất cả tác vụ thất bại'),
                ),
              const PopupMenuItem(
                value: 'select',
                child: Text('Chọn nhiều chương để hủy tải'),
              ),
            ],
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(CupertinoIcons.list_bullet, size: 18),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(_busy ? 'Đang xử lý' : 'Quản lý hàng đợi'),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

typedef _QueueChoice = ({String identity, String book, String chapter});

class _QueueCancellationPicker extends StatefulWidget {
  const _QueueCancellationPicker({required this.choices});
  final List<_QueueChoice> choices;

  @override
  State<_QueueCancellationPicker> createState() => _QueueCancellationState();
}

class _QueueCancellationState extends State<_QueueCancellationPicker> {
  final Set<String> _selected = {};

  @override
  Widget build(BuildContext context) => SizedBox(
    height: (MediaQuery.sizeOf(context).height * .8).clamp(200.0, 640.0),
    child: Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Text(
            'Chọn chương để hủy tải',
            style: Theme.of(context).textTheme.titleMedium,
          ),
        ),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 16),
          child: Text(
            'Có thể chọn chương của nhiều truyện. Nội dung đã tải được giữ.',
          ),
        ),
        TextButton(
          onPressed: () => setState(() {
            if (_selected.length == widget.choices.length) {
              _selected.clear();
            } else {
              _selected.addAll(widget.choices.map((choice) => choice.identity));
            }
          }),
          child: Text(
            _selected.length == widget.choices.length
                ? 'Bỏ chọn tất cả'
                : 'Chọn tất cả',
          ),
        ),
        Expanded(
          child: ListView.builder(
            itemCount: widget.choices.length,
            itemBuilder: (context, index) {
              final choice = widget.choices[index];
              return CheckboxListTile(
                key: ValueKey('cancel-download-${choice.identity}'),
                value: _selected.contains(choice.identity),
                controlAffinity: ListTileControlAffinity.leading,
                title: Text(choice.chapter, maxLines: 2),
                subtitle: Text(choice.book, maxLines: 2),
                onChanged: (value) => setState(() {
                  if (value == true) {
                    _selected.add(choice.identity);
                  } else {
                    _selected.remove(choice.identity);
                  }
                }),
              );
            },
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              Expanded(
                child: TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Đóng'),
                ),
              ),
              Expanded(
                child: FilledButton(
                  onPressed: _selected.isEmpty
                      ? null
                      : () => Navigator.pop(context, Set<String>.of(_selected)),
                  child: Text('Hủy tải ${_selected.length} chương'),
                ),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}
