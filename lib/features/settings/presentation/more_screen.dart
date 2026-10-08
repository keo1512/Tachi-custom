import 'package:file_picker/file_picker.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/widgets/feedback.dart';
import '../../library/data/backup_service.dart';
import '../../library/presentation/library_view_model.dart';
import '../../reader/presentation/reader_settings_sheet.dart';
import '../settings_controller.dart';
import 'connection_dialog.dart';

class MoreScreen extends ConsumerStatefulWidget {
  const MoreScreen({super.key});
  @override
  ConsumerState<MoreScreen> createState() => _MoreScreenState();
}

class _MoreScreenState extends ConsumerState<MoreScreen> {
  bool busy = false;

  Future<void> run(Future<void> Function() action) async {
    if (busy) return;
    setState(() => busy = true);
    try {
      await perform(context, action);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> importBooks() => run(() async {
    final count = await ref.read(libraryProvider.notifier).importFiles();
    if (mounted && count > 0) {
      message(context, 'Đã nhập $count file vào thư viện');
    }
  });

  Future<void> exportBackup() => run(() async {
    final bytes = await BackupService(ref.read(libraryRepositoryProvider))
        .export();
    final date = DateTime.now().toIso8601String().substring(0, 10);
    final saved = await FilePicker.saveFile(
      fileName: 'tachibooks-$date.json',
      bytes: bytes,
      mimeType: 'application/json',
      dialogTitle: 'Lưu bản sao lưu TachiBooks',
    );
    if (mounted && saved != null) {
      message(context, 'Đã xuất thư viện và nội dung đã lưu');
    }
  });

  Future<void> importBackup() => run(() async {
    final selected = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: ['json'],
      dialogTitle: 'Chọn bản sao lưu TachiBooks',
    );
    if (selected == null) return;
    final size = await selected.length();
    if (size != null && size > BackupService.maxBackupBytes) {
      throw const FormatException('Bản sao lưu vượt giới hạn 128 MB.');
    }
    final bytes = await selected.readAsBytes();
    final count = await BackupService(ref.read(libraryRepositoryProvider))
        .merge(bytes);
    await ref.read(libraryProvider.notifier).refresh();
    if (mounted) {
      message(context, 'Đã khôi phục $count sách. Sách đã có được giữ nguyên.');
    }
  });

  Future<void> downloads() => showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (ctx) => SizedBox(
      height: MediaQuery.sizeOf(ctx).height * .75,
      child: Consumer(
        builder: (ctx, ref, _) => SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(20, 0, 20, 16),
                child: Text(
                  'Nội dung đã tải',
                  style: TextStyle(fontSize: 24, fontWeight: FontWeight.w700),
                ),
              ),
              Expanded(
                child: ref
                    .watch(libraryProvider)
                    .when(
                      loading: () =>
                          const Center(child: CircularProgressIndicator()),
                      error: (error, _) => Center(child: Text('$error')),
                      data: (books) {
                        final downloaded = books
                            .where(
                              (book) => book.chapters.any(
                                (chapter) => chapter.downloaded,
                              ),
                            )
                            .toList();
                        if (downloaded.isEmpty) {
                          return const EmptyPanel(
                            icon: CupertinoIcons.arrow_down_circle,
                            title: 'Chưa có nội dung offline',
                            description: 'Nhập EPUB, TXT, CBZ hoặc tải chương từ trang chi tiết truyện.',
                          );
                        }
                        return ListView.separated(
                          itemCount: downloaded.length,
                          separatorBuilder: (_, _) =>
                              const Divider(height: 1, indent: 60),
                          itemBuilder: (_, index) {
                            final book = downloaded[index];
                            final count = book.chapters
                                .where((chapter) => chapter.downloaded)
                                .length;
                            return ListTile(
                              leading: const Icon(
                                CupertinoIcons.arrow_down_circle_fill,
                              ),
                              title: Text(book.title),
                              subtitle: Text(
                                '$count / ${book.chapters.length} chương đã lưu',
                              ),
                              trailing: const Icon(
                                CupertinoIcons.chevron_right,
                                size: 16,
                              ),
                              onTap: () {
                                Navigator.pop(ctx);
                                context.push('/book/${book.id}');
                              },
                            );
                          },
                        );
                      },
                    ),
              ),
            ],
          ),
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
    final background = settings.dark
        ? const Color(0xFF000000)
        : const Color(0xFFF2F2F7);
    return Scaffold(
      backgroundColor: background,
      appBar: AppBar(backgroundColor: background, title: const Text('Thêm')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
        children: [
          _Section(
            children: [
              ListTile(
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                leading: Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: const Color(0xFF007AFF),
                    borderRadius: BorderRadius.circular(11),
                  ),
                  child: const Icon(
                    CupertinoIcons.book_fill,
                    color: Colors.white,
                    size: 28,
                  ),
                ),
                title: const Text(
                  'TachiBooks',
                  style: TextStyle(fontSize: 21, fontWeight: FontWeight.w600),
                ),
                subtitle: const Text('Truyện tranh · Truyện chữ · Ebook'),
              ),
            ],
          ),
          if (busy)
            const Padding(
              padding: EdgeInsets.only(top: 12),
              child: LinearProgressIndicator(),
            ),
          const _SectionTitle('THƯ VIỆN'),
          _Section(
            children: [
              _MenuRow(
                icon: CupertinoIcons.arrow_down_circle,
                title: 'Nội dung đã tải',
                onTap: busy ? null : downloads,
              ),
              _MenuRow(
                icon: CupertinoIcons.doc_on_doc,
                title: 'Nhập sách & truyện',
                subtitle: 'EPUB, TXT, CBZ, ZIP',
                onTap: busy ? null : importBooks,
              ),
              _MenuRow(
                icon: CupertinoIcons.compass,
                title: 'Nguồn & extension',
                onTap: busy ? null : () => context.go('/browse'),
              ),
            ],
          ),
          const _SectionTitle('GIAO DIỆN & ĐỌC SÁCH'),
          _Section(
            children: [
              SwitchListTile.adaptive(
                secondary: const Icon(CupertinoIcons.moon),
                title: const Text('Giao diện tối'),
                value: settings.dark,
                onChanged: busy
                    ? null
                    : (value) => run(
                        () => ref
                            .read(settingsProvider.notifier)
                            .update(dark: value),
                      ),
              ),
              _MenuRow(
                icon: CupertinoIcons.textformat_size,
                title: 'Đọc truyện chữ & ebook',
                subtitle: 'Phông chữ, cỡ chữ, nền trang',
                onTap: busy
                    ? null
                    : () => showReaderSettings(context, manga: false),
              ),
              _MenuRow(
                icon: CupertinoIcons.rectangle_on_rectangle,
                title: 'Đọc truyện tranh',
                subtitle: 'Hướng đọc, cuộn dọc, lật trang',
                onTap: busy
                    ? null
                    : () => showReaderSettings(context, manga: true),
              ),
            ],
          ),
          const _SectionTitle('DỮ LIỆU & KẾT NỐI'),
          _Section(
            children: [
              _MenuRow(
                icon: CupertinoIcons.link,
                title: 'Kết nối runtime nguồn',
                subtitle: 'Tachimanga / Suwayomi và vBook',
                onTap: busy ? null : () => showConnections(context, ref),
              ),
              _MenuRow(
                icon: CupertinoIcons.arrow_up_doc,
                title: 'Xuất bản sao lưu',
                onTap: busy ? null : exportBackup,
              ),
              _MenuRow(
                icon: CupertinoIcons.arrow_down_doc,
                title: 'Khôi phục bản sao lưu',
                onTap: busy ? null : importBackup,
              ),
            ],
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(14, 8, 14, 0),
            child: Text(
              'Sao lưu TachiBooks giữ thư viện, tiến độ, dấu trang và nội dung đã lưu. Khôi phục thêm sách mới và giữ nguyên sách đã có.',
              style: TextStyle(color: Colors.grey, fontSize: 12, height: 1.5),
            ),
          ),
          const _SectionTitle('ỨNG DỤNG'),
          _Section(
            children: [
              _MenuRow(
                icon: CupertinoIcons.info_circle,
                title: 'Giới thiệu',
                onTap: () => showAboutDialog(
                  context: context,
                  applicationName: 'TachiBooks',
                  applicationVersion: '1.0.0',
                  applicationIcon: const Icon(
                    CupertinoIcons.book_fill,
                    size: 40,
                    color: Color(0xFF007AFF),
                  ),
                  children: const [
                    Text(
                      'Thư viện chung cho manga, truyện chữ và ebook. Nội dung đã nhập hoặc tải được đọc offline. Nguồn extension hoạt động qua runtime đã cấu hình.',
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(14, 24, 14, 7),
    child: Text(
      text,
      style: const TextStyle(
        fontSize: 12,
        color: Colors.grey,
        fontWeight: FontWeight.w500,
      ),
    ),
  );
}

class _Section extends StatelessWidget {
  const _Section({required this.children});
  final List<Widget> children;
  @override
  Widget build(BuildContext context) => Material(
    color: Theme.of(context).brightness == Brightness.dark
        ? const Color(0xFF1C1C1E)
        : Colors.white,
    borderRadius: BorderRadius.circular(11),
    clipBehavior: Clip.antiAlias,
    child: Column(
      children: [
        for (var index = 0; index < children.length; index++) ...[
          if (index > 0) const Divider(height: 1, indent: 56),
          children[index],
        ],
      ],
    ),
  );
}

class _MenuRow extends StatelessWidget {
  const _MenuRow({
    required this.icon,
    required this.title,
    this.subtitle,
    this.onTap,
  });
  final IconData icon;
  final String title;
  final String? subtitle;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) => ListTile(
    leading: Icon(icon, color: Theme.of(context).colorScheme.primary, size: 23),
    title: Text(title, style: const TextStyle(fontSize: 16)),
    subtitle: subtitle == null
        ? null
        : Text(subtitle!, style: const TextStyle(fontSize: 12)),
    trailing: const Icon(
      CupertinoIcons.chevron_right,
      size: 14,
      color: Colors.grey,
    ),
    enabled: onTap != null,
    onTap: onTap,
  );
}
