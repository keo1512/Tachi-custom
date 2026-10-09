import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../domain/catalogue.dart';
import 'browse_widgets.dart';

Future<SourceEngine?> chooseExtensionEngine(BuildContext context) =>
    showCupertinoModalPopup<SourceEngine>(
      context: context,
      builder: (context) => CupertinoActionSheet(
        title: const Text('Thêm phần mở rộng'),
        message: const Text('Chọn hệ extension'),
        actions: [
          for (final engine in SourceEngine.values)
            CupertinoActionSheetAction(
              onPressed: () => Navigator.pop(context, engine),
              child: Text(sourceEngineName(engine)),
            ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.pop(context),
          child: const Text('Hủy'),
        ),
      ),
    );

class ExtensionInput {
  const ExtensionInput(this.url, this.repository);
  final String url;
  final bool repository;
}

Future<ExtensionInput?> requestExtension(
  BuildContext context,
  SourceEngine engine,
) => showDialog<ExtensionInput>(
  context: context,
  builder: (_) => _ExtensionDialog(engine: engine),
);

class _ExtensionDialog extends StatefulWidget {
  const _ExtensionDialog({required this.engine});
  final SourceEngine engine;

  @override
  State<_ExtensionDialog> createState() => _ExtensionDialogState();
}

class _ExtensionDialogState extends State<_ExtensionDialog> {
  bool repository = true;
  final text = TextEditingController();

  @override
  void dispose() {
    text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text('Thêm extension ${sourceEngineName(widget.engine)}'),
    content: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: double.infinity,
            child: CupertinoSlidingSegmentedControl<bool>(
              groupValue: repository,
              children: const {
                true: Text('Kho extension'),
                false: Text('Gói extension'),
              },
              onValueChanged: (value) {
                if (value != null) setState(() => repository = value);
              },
            ),
          ),
          const SizedBox(height: 16),
          if (repository)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                onPressed: () =>
                    text.text = widget.engine == SourceEngine.tachimanga
                    ? 'https://github.com/keiyoushi/extensions'
                    : 'https://raw.githubusercontent.com/Darkrai9x/vbook-extensions/master/plugin.json',
                child: Text(
                  widget.engine == SourceEngine.tachimanga
                      ? 'Dùng kho Keiyoushi'
                      : 'Dùng kho vBook / Darkrai9x',
                ),
              ),
            ),
          TextField(
            controller: text,
            keyboardType: TextInputType.url,
            autocorrect: false,
            decoration: InputDecoration(
              labelText: repository
                  ? 'Link kho extension'
                  : widget.engine == SourceEngine.tachimanga
                  ? 'URL APK'
                  : 'URL plugin.zip',
            ),
          ),
          if (repository && widget.engine == SourceEngine.vbook) ...[
            const SizedBox(height: 8),
            const Text(
              'Với vbookext.me, sao chép link kho của tác giả rồi dán vào đây.',
              style: TextStyle(fontSize: 12),
            ),
          ],
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Hủy'),
      ),
      TextButton(
        onPressed: () => Navigator.pop(
          context,
          ExtensionInput(text.text.trim(), repository),
        ),
        child: const Text('Thêm'),
      ),
    ],
  );
}

Future<void> showSourceInfo(
  BuildContext context,
  CatalogueSource source,
) => showDialog<void>(
  context: context,
  builder: (context) => AlertDialog(
    title: Text(source.name),
    content: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${sourceEngineName(source.engine)} · ${sourceLanguage(source.lang)}',
          ),
          const SizedBox(height: 12),
          Text(
            source.kind == ContentKind.manga ? 'Truyện tranh' : 'Truyện chữ',
          ),
          if (source.baseUrl.isNotEmpty) ...[
            const SizedBox(height: 12),
            SelectableText(source.baseUrl),
          ],
          const SizedBox(height: 12),
          SelectableText('ID: ${source.id}'),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Xong'),
      ),
    ],
  ),
);
