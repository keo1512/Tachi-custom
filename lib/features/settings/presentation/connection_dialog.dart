import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/widgets/feedback.dart';
import '../../sources/data/source_repository.dart';
import '../../sources/domain/catalogue.dart';
import '../settings_controller.dart';

Future<void> showConnections(BuildContext context, WidgetRef ref) {
  final controller = ref.read(settingsProvider.notifier);
  final initial = ref.read(settingsProvider);
  return showDialog<void>(
    context: context,
    builder: (_) => _ConnectionDialog(
      initial: initial,
      onSave: (tachi, vbook) =>
          controller.update(tachimangaUrl: tachi, vbookUrl: vbook),
    ),
  );
}

class _ConnectionDialog extends StatefulWidget {
  const _ConnectionDialog({required this.initial, required this.onSave});
  final AppSettings initial;
  final Future<void> Function(String, String) onSave;

  @override
  State<_ConnectionDialog> createState() => _ConnectionState();
}

class _ConnectionState extends State<_ConnectionDialog> {
  late final tachi = TextEditingController(text: widget.initial.tachimangaUrl);
  late final vbook = TextEditingController(text: widget.initial.vbookUrl);
  SourceRepository? active;
  bool busy = false;

  @override
  void dispose() {
    active?.dispose();
    tachi.dispose();
    vbook.dispose();
    super.dispose();
  }

  Future<void> testConnection() async {
    setState(() => busy = true);
    final tachiUrl = tachi.text.trim();
    final vbookUrl = vbook.text.trim();
    SourceRepository? repo;
    try {
      repo = SourceRepository(tachimangaUrl: tachiUrl, vbookUrl: vbookUrl);
      active = repo;
      final results = <String>[];
      if (tachiUrl.isNotEmpty) {
        await repo.health(SourceEngine.tachimanga);
        results.add('Tachimanga đã kết nối');
      }
      if (vbookUrl.isNotEmpty) {
        await repo.health(SourceEngine.vbook);
        results.add('vBook đã kết nối');
      }
      if (mounted) {
        message(
          context,
          results.isEmpty ? 'Nhập ít nhất một địa chỉ' : results.join(' · '),
        );
      }
    } catch (e) {
      if (mounted) message(context, e);
    } finally {
      repo?.dispose();
      if (identical(active, repo)) active = null;
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> save() async {
    final tachiUrl = tachi.text.trim();
    final vbookUrl = vbook.text.trim();
    for (final value in [tachiUrl, vbookUrl]) {
      if (value.isEmpty) continue;
      final uri = Uri.tryParse(value);
      if (uri == null ||
          !['http', 'https'].contains(uri.scheme) ||
          uri.host.isEmpty ||
          uri.userInfo.isNotEmpty ||
          uri.hasQuery ||
          uri.hasFragment) {
        message(
          context,
          'Địa chỉ phải là HTTP/HTTPS hợp lệ, không chứa tài khoản hoặc query',
        );
        return;
      }
    }
    setState(() => busy = true);
    try {
      await widget.onSave(tachiUrl, vbookUrl);
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) message(context, e);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Kết nối nguồn truyện'),
    content: SizedBox(
      width: 420,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Nguồn APK dùng Suwayomi. Nguồn vBook dùng runtime vBook. Trên iPhone/iPad, nhập địa chỉ PC/server mà thiết bị truy cập được; localhost là chính thiết bị.',
              style: TextStyle(fontSize: 13, height: 1.5),
            ),
            const SizedBox(height: 18),
            TextField(
              controller: tachi,
              enabled: !busy,
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(
                labelText: 'Tachimanga / Suwayomi',
                hintText: 'http://192.168.1.10:4567',
              ),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: vbook,
              enabled: !busy,
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(
                labelText: 'vBook runtime',
                hintText: 'http://192.168.1.10:4570',
              ),
            ),
            const SizedBox(height: 14),
            if (busy) const LinearProgressIndicator(),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: busy ? null : testConnection,
        child: const Text('Kiểm tra'),
      ),
      TextButton(
        onPressed: busy ? null : () => Navigator.pop(context),
        child: const Text('Hủy'),
      ),
      FilledButton(onPressed: busy ? null : save, child: const Text('Lưu')),
    ],
  );
}
