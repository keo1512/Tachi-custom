import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../domain/catalogue.dart';
import 'browse_widgets.dart';

Future<SourceEngine?> chooseExtensionEngine(BuildContext context) =>
    showCupertinoModalPopup<SourceEngine>(
      context: context,
      builder: (context) => CupertinoActionSheet(
        title: const Text('Thêm phần mở rộng'),
        message: const Text('Chọn loại extension hoặc repository'),
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
                true: Text('Repository'),
                false: Text('Gói extension'),
              },
              onValueChanged: (value) {
                if (value != null) setState(() => repository = value);
              },
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: text,
            keyboardType: TextInputType.url,
            autocorrect: false,
            decoration: InputDecoration(
              labelText: repository
                  ? 'URL registry JSON'
                  : widget.engine == SourceEngine.tachimanga
                  ? 'URL APK'
                  : 'URL plugin.zip',
            ),
          ),
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
