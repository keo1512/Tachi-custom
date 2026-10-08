import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/widgets/feedback.dart';
import '../../library/presentation/library_view_model.dart';
import '../../reader/presentation/reader_settings_sheet.dart';
import '../settings_controller.dart';
import 'backup_settings_screen.dart';
import 'connection_dialog.dart';
import 'settings_widgets.dart';

class GeneralSettingsScreen extends ConsumerStatefulWidget {
  const GeneralSettingsScreen({super.key});

  @override
  ConsumerState<GeneralSettingsScreen> createState() => _GeneralSettingsState();
}

class _GeneralSettingsState extends ConsumerState<GeneralSettingsScreen> {
  bool importing = false;

  Future<void> importBooks() async {
    if (importing) return;
    setState(() => importing = true);
    try {
      await perform(context, () async {
        final count = await ref.read(libraryProvider.notifier).importFiles();
        if (mounted && count > 0) {
          message(context, 'Đã nhập $count file vào thư viện');
        }
      });
    } finally {
      if (mounted) setState(() => importing = false);
    }
  }

  @override
  Widget build(BuildContext context) => SettingsPage(
    title: 'Chung',
    children: [
      SettingsRow(
        icon: CupertinoIcons.doc_on_doc,
        title: 'Nhập sách & truyện',
        subtitle: 'EPUB, TXT, CBZ, ZIP',
        trailing: importing ? const CupertinoActivityIndicator() : null,
        onTap: importing ? null : importBooks,
      ),
      SettingsRow(
        icon: CupertinoIcons.link,
        title: 'Kết nối nguồn',
        subtitle: 'Tachimanga / Suwayomi và vBook',
        onTap: () => showConnections(context, ref),
      ),
      const Divider(height: 24, thickness: .5),
      const SettingsRow(
        title: 'TachiBooks',
        icon: CupertinoIcons.book,
        subtitle: 'Phiên bản 1.0.0 · iPhone và iPad',
      ),
      const SettingsNote(
        'Thư viện chung cho truyện tranh, truyện chữ và ebook. Sách đã nhập hoặc chương đã tải có thể đọc offline.',
      ),
      SettingsRow(
        title: 'Giấy phép phần mềm',
        icon: CupertinoIcons.doc_text,
        onTap: () => showLicensePage(
          context: context,
          applicationName: 'TachiBooks',
          applicationVersion: '1.0.0',
        ),
      ),
    ],
  );
}

class AppearanceSettingsScreen extends ConsumerWidget {
  const AppearanceSettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dark = ref.watch(settingsProvider).dark;
    return SettingsPage(
      title: 'Giao diện',
      children: [
        SettingsRow(
          title: 'Giao diện tối',
          icon: CupertinoIcons.moon,
          trailing: CupertinoSwitch(
            value: dark,
            onChanged: (value) => perform(
              context,
              () => ref.read(settingsProvider.notifier).update(dark: value),
            ),
          ),
        ),
        const SettingsNote(
          'Lựa chọn giao diện được lưu trên thiết bị. Phông chữ và nền trang của reader được thiết lập riêng trong Độc giả.',
        ),
      ],
    );
  }
}

class LibrarySettingsScreen extends ConsumerWidget {
  const LibrarySettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final columns = ref.watch(settingsProvider).libraryColumns;
    final books = ref.watch(libraryProvider).asData?.value;
    return SettingsPage(
      title: 'Thư viện',
      children: [
        SettingsRow(
          title: 'Số cột hiển thị',
          subtitle: '$columns cột',
          icon: CupertinoIcons.square_grid_2x2,
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: CupertinoSlider(
            value: columns.toDouble().clamp(2, 8),
            min: 2,
            max: 8,
            divisions: 6,
            onChanged: (value) => perform(
              context,
              () => ref
                  .read(settingsProvider.notifier)
                  .update(libraryColumns: value.round()),
            ),
          ),
        ),
        const SettingsNote(
          'Thay đổi số bìa trên một hàng trong thư viện. Bộ lọc, sắp xếp và bộ sưu tập nằm trong menu Thư viện.',
        ),
        const Divider(height: 24, thickness: .5),
        SettingsRow(
          title: 'Mở thư viện',
          icon: CupertinoIcons.book,
          subtitle: books == null ? null : '${books.length} sách và truyện',
          onTap: () => context.go('/'),
        ),
        SettingsRow(
          title: 'Nhập sách & truyện',
          icon: CupertinoIcons.doc_on_doc,
          onTap: () => openSettingsPage(context, const GeneralSettingsScreen()),
        ),
      ],
    );
  }
}

class ReaderSettingsScreen extends ConsumerWidget {
  const ReaderSettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    final mode = switch (settings.mangaMode) {
      'paged' => 'Lật trang',
      'rtl' => 'Phải → trái',
      _ => 'Cuộn dọc',
    };
    return SettingsPage(
      title: 'Độc giả',
      children: [
        SettingsRow(
          title: 'Đọc truyện tranh',
          icon: CupertinoIcons.rectangle_on_rectangle,
          subtitle: mode,
          onTap: () => showReaderSettings(context, manga: true),
        ),
        SettingsRow(
          title: 'Đọc truyện chữ & ebook',
          icon: CupertinoIcons.textformat_size,
          subtitle: '${settings.font} · ${settings.fontSize.round()} pt',
          onTap: () => showReaderSettings(context, manga: false),
        ),
        const SettingsNote(
          'Cỡ chữ, phông chữ, khoảng cách dòng, nền trang và hướng đọc được lưu trên thiết bị, áp dụng cho reader.',
        ),
        const Divider(height: 24, thickness: .5),
        SettingsRow(
          title: 'Đọc thành tiếng',
          icon: CupertinoIcons.speaker_2,
          subtitle: 'Truyện chữ và ebook',
          onTap: () => openSettingsPage(
            context,
            const SettingsPage(
              title: 'Đọc thành tiếng',
              children: [
                SettingsNote(
                  'Mở một chương truyện chữ hoặc ebook, rồi chạm biểu tượng loa trong reader để bắt đầu hoặc dừng đọc. Giọng đọc sử dụng dịch vụ đọc văn bản của thiết bị.',
                ),
                SettingsNote(
                  'Khả năng đọc tiếng Việt phụ thuộc giọng đọc đã có trên iPhone hoặc iPad. Reader tự dừng đọc thành tiếng khi rời màn hình.',
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class ExtensionSettingsScreen extends ConsumerWidget {
  const ExtensionSettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) => SettingsPage(
    title: 'Phần mở rộng',
    children: [
      SettingsRow(
        title: 'Nguồn & extension',
        icon: CupertinoIcons.compass,
        subtitle: 'Tachimanga và vBook',
        onTap: () => context.go('/browse'),
      ),
      SettingsRow(
        title: 'Kết nối nguồn',
        icon: CupertinoIcons.link,
        onTap: () => showConnections(context, ref),
      ),
      const SettingsNote(
        'Nguồn APK dùng Suwayomi và nguồn vBook dùng runtime vBook đã cấu hình. Hai runtime hiện chạy ngoài thiết bị. Nội dung đã tải vẫn đọc được offline.',
      ),
    ],
  );
}

class FeatureStatusScreen extends StatelessWidget {
  const FeatureStatusScreen({
    super.key,
    required this.title,
    required this.description,
    this.offerBackup = false,
  });
  final String title, description;
  final bool offerBackup;

  @override
  Widget build(BuildContext context) => SettingsPage(
    title: title,
    children: [
      const SettingsRow(title: 'Chưa hỗ trợ', icon: CupertinoIcons.info_circle),
      SettingsNote(description),
      if (offerBackup)
        SettingsRow(
          title: 'Sao lưu & Khôi phục',
          icon: CupertinoIcons.arrow_counterclockwise,
          onTap: () => openSettingsPage(context, const BackupSettingsScreen()),
        ),
    ],
  );
}

class PrivacySettingsScreen extends StatelessWidget {
  const PrivacySettingsScreen({super.key});

  @override
  Widget build(BuildContext context) => const SettingsPage(
    title: 'Bảo mật',
    children: [
      SettingsHeading('Dữ liệu trên thiết bị'),
      SettingsNote(
        'Thư viện, nội dung đã tải, tiến độ và dấu trang được lưu trong dữ liệu riêng của ứng dụng. App chưa có khóa bằng mật khẩu hoặc Face ID. Bản sao lưu JSON chưa được mã hóa.',
      ),
      SettingsHeading('Kết nối nguồn'),
      SettingsNote(
        'Tìm truyện, cập nhật và tải chương gửi yêu cầu tới runtime nguồn mà bạn cấu hình. Dùng địa chỉ HTTPS hoặc mạng riêng đáng tin cậy. App chưa hỗ trợ đăng nhập bearer-token cho runtime.',
      ),
      SettingsHeading('Phần mở rộng'),
      SettingsNote(
        'Chỉ cài extension từ nguồn tin cậy. Extension được thực thi ở runtime bên ngoài thiết bị; runtime này có thể truy cập mạng và dữ liệu của nó.',
      ),
    ],
  );
}

class DownloadSettingsScreen extends ConsumerWidget {
  const DownloadSettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) => SettingsPage(
    title: 'Tải xuống Manga',
    children: [
      const SettingsHeading('Hàng đợi tải'),
      const SettingsRow(title: 'Số chương tải đồng thời'),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
        child: CupertinoSlidingSegmentedControl<int>(
          groupValue: ref.watch(settingsProvider).downloadConcurrency,
          children: const {
            1: Text('1'),
            2: Text('2'),
            3: Text('3'),
            4: Text('4'),
          },
          onValueChanged: (value) {
            if (value != null) {
              perform(
                context,
                () => ref
                    .read(settingsProvider.notifier)
                    .update(downloadConcurrency: value),
              );
            }
          },
        ),
      ),
      const Divider(height: 24, thickness: .5),
      SettingsRow(
        title: 'Nội dung đã tải',
        icon: CupertinoIcons.arrow_down_circle,
        onTap: () => context.go('/downloads'),
      ),
      const SettingsNote(
        'Mở chi tiết truyện, chọn tải một chương hoặc các chương chưa lưu. Manga lưu ảnh vào dữ liệu ứng dụng; truyện chữ lưu nội dung chương và ảnh đính kèm.',
      ),
      const SettingsNote(
        'Nhập EPUB, TXT hoặc CBZ để đọc offline từ file. App hiện chưa có bộ lập lịch tải tự động hoặc lựa chọn chỉ tải qua Wi-Fi.',
      ),
    ],
  );
}
