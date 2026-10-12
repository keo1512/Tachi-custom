import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/widgets/feedback.dart';
import '../data/folder_comic_importer.dart';
import '../data/local_comic_files_platform.dart';
import 'library_view_model.dart';
import 'library_category_controller.dart';
import '../../privacy/application/app_lock_controller.dart';
import '../domain/library_book.dart';

class LocalComicLibraryScreen extends ConsumerStatefulWidget {
  const LocalComicLibraryScreen({super.key});
  @override
  ConsumerState<LocalComicLibraryScreen> createState() =>
      _LocalComicLibraryScreenState();
}

class _LocalComicLibraryScreenState
    extends ConsumerState<LocalComicLibraryScreen> {
  LocalComicFolder? folder;
  bool busy = true;
  bool folderIsSingleBook = false;
  String? message, error;
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    try {
      final value = await ref.read(localComicFilesPlatformProvider).current();
      if (mounted) {
        setState(() {
          folder = value;
          busy = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          error = userFacingError(e);
          busy = false;
        });
      }
    }
  }

  Future<void> action({bool choose = false, bool forget = false}) async {
    if (busy) return;
    setState(() {
      busy = true;
      error = null;
      message = null;
    });
    try {
      final platform = ref.read(localComicFilesPlatformProvider);
      if (forget) {
        await platform.forget();
        if (mounted) {
          setState(() {
            folder = null;
            message = 'Đã ngừng theo dõi thư mục. Truyện đã nhập vẫn đọc được.';
          });
        }
        return;
      }
      if (choose) {
        final selected = await platform.choose();
        if (!mounted || selected == null) return;
        setState(() => folder = selected);
      }
      final selected = folder;
      if (selected == null) return;
      final repository = ref.read(libraryRepositoryProvider);
      final candidates = (await repository.list())
          .where(
            (book) =>
                book.engine == 'local' &&
                book.kind == 'manga' &&
                book.sourceName == 'Thư mục trên máy' &&
                book.sourceId != selected.id,
          )
          .toList();
      Map<String, FolderComicReconnect> reconnect = const {};
      if (candidates.isNotEmpty) {
        if (!mounted) return;
        final result =
            await showModalBottomSheet<Map<String, FolderComicReconnect>>(
              context: context,
              isScrollControlled: true,
              builder: (_) => _ReconnectFolderSheet(candidates: candidates),
            );
        if (!mounted || result == null) return;
        reconnect = result;
      }
      final result = await FolderComicImporter(platform).scan(
        selected,
        repository,
        reconnect: reconnect,
        folderIsSingleBook: folderIsSingleBook,
        defaultCategories: ref
            .read(libraryCategoriesProvider)
            .defaultCategories,
        isCurrent: () {
          if (!mounted) return false;
          final lock = ref.read(appLockProvider);
          return lock.initialized &&
              lock.configurationValid &&
              !lock.locked &&
              !lock.authenticating;
        },
      );
      await ref.read(libraryProvider.notifier).refresh();
      if (mounted) {
        setState(
          () => message =
              'Đã nhập ${result.newBooks} truyện mới, thêm ${result.newChapters} chương; giữ ${result.retainedChapters} chương không còn trong thư mục.',
        );
      }
    } catch (e) {
      if (mounted) setState(() => error = userFacingError(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Truyện trong thư mục')),
    body: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text(
          'Chọn thư mục trong Tệp. Mỗi thư mục con cấp đầu là một truyện; thư mục chương, ảnh và CBZ/ZIP/CBR/RAR bên trong được quét theo thứ tự tự nhiên. details.json và cover.jpg có thể bổ sung thông tin và bìa.',
        ),
        const SizedBox(height: 12),
        const Text(
          'App sao chép nội dung để đọc offline và đưa vào backup/đồng bộ. Quét lại phát hiện chương mới, giữ tiến độ, dấu trang và chương đã sao chép dù tệp nguồn bị xóa. Tệp gốc được giữ nguyên. Quyền thư mục chỉ lưu trên thiết bị này.',
        ),
        const SizedBox(height: 20),
        SwitchListTile.adaptive(
          contentPadding: EdgeInsets.zero,
          title: const Text('Thư mục này là một truyện'),
          subtitle: const Text(
            'Bật nếu các thư mục con là chương của cùng một truyện. Tắt nếu mỗi thư mục con là một truyện trong tủ sách.',
          ),
          value: folderIsSingleBook,
          onChanged: busy
              ? null
              : (value) => setState(() => folderIsSingleBook = value),
        ),
        if (folder != null)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(CupertinoIcons.folder),
            title: Text(folder!.label),
            subtitle: const Text('Thư mục đã chọn trên thiết bị'),
          ),
        if (busy)
          const Center(
            child: Padding(
              padding: EdgeInsets.all(12),
              child: CupertinoActivityIndicator(),
            ),
          ),
        FilledButton.icon(
          onPressed: busy ? null : () => action(choose: true),
          icon: const Icon(CupertinoIcons.folder_badge_plus),
          label: const Text('Chọn thư mục và quét'),
        ),
        if (folder != null) ...[
          const SizedBox(height: 10),
          OutlinedButton.icon(
            onPressed: busy ? null : () => action(),
            icon: const Icon(CupertinoIcons.refresh),
            label: const Text('Quét lại chương mới'),
          ),
          TextButton(
            onPressed: busy ? null : () => action(forget: true),
            child: const Text('Ngừng theo dõi thư mục'),
          ),
        ],
        if (message != null)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(message!),
          ),
        if (error != null)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(
              error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
      ],
    ),
  );
}

class _ReconnectFolderSheet extends StatefulWidget {
  const _ReconnectFolderSheet({required this.candidates});
  final List<LibraryBook> candidates;
  @override
  State<_ReconnectFolderSheet> createState() => _ReconnectFolderSheetState();
}

class _ReconnectFolderSheetState extends State<_ReconnectFolderSheet> {
  final selected = <String, FolderComicReconnect>{};
  @override
  Widget build(BuildContext context) => SafeArea(
    child: SizedBox(
      height: MediaQuery.sizeOf(context).height * .8,
      child: Column(
        children: [
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text(
              'Kết nối lại truyện đã khôi phục',
              style: TextStyle(fontSize: 19),
            ),
          ),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              'Nếu thư mục này chứa truyện đã nhập trên máy trước, chọn đúng truyện và đường dẫn bên dưới. App giữ mã truyện, tiến độ và chương đã sao chép. Mỗi đường dẫn chỉ chọn một truyện. Để trống để nhập thành truyện mới.',
            ),
          ),
          Expanded(
            child: ListView(
              children: [
                for (final book in widget.candidates)
                  CheckboxListTile(
                    value: selected[book.sourceRef]?.bookId == book.id,
                    title: Text(book.title),
                    subtitle: Text(
                      '${book.sourceRef.isEmpty ? 'Ảnh/archive ở gốc thư mục' : book.sourceRef}\n${book.chapters.length} chương đã giữ',
                    ),
                    onChanged: (value) => setState(() {
                      if (value == true) {
                        selected[book.sourceRef] = FolderComicReconnect(
                          book.id,
                          book.sourceId,
                        );
                      } else {
                        selected.remove(book.sourceRef);
                      }
                    }),
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: FilledButton(
              onPressed: () => Navigator.pop(
                context,
                Map<String, FolderComicReconnect>.of(selected),
              ),
              child: Text(
                selected.isEmpty
                    ? 'Nhập thành truyện mới'
                    : 'Kết nối truyện đã chọn và quét',
              ),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Hủy'),
          ),
        ],
      ),
    ),
  );
}
