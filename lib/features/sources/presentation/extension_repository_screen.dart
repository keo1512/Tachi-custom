import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/widgets/feedback.dart';
import '../data/extension_index.dart';
import '../domain/catalogue.dart';
import 'browse_dialogs.dart';
import 'browse_widgets.dart';
import 'extension_catalogue_controller.dart';

class ExtensionRepositoryScreen extends ConsumerStatefulWidget {
  const ExtensionRepositoryScreen({super.key});

  @override
  ConsumerState<ExtensionRepositoryScreen> createState() =>
      _ExtensionRepositoryState();
}

class _ExtensionRepositoryState
    extends ConsumerState<ExtensionRepositoryScreen> {
  bool adding = false;

  Future<void> add() async {
    if (adding) return;
    final engine = await chooseExtensionEngine(context);
    if (engine == null || !mounted) return;
    final url = await showDialog<String>(
      context: context,
      builder: (_) => _RepositoryUrlDialog(engine: engine),
    );
    if (url == null || url.isEmpty || !mounted) return;
    final current = ref.read(extensionCatalogueProvider).value;
    if (current?.any((index) => index.engine == engine && index.url == url) ==
        true) {
      message(context, 'Kho này đã có trong danh sách.');
      return;
    }
    final accepted = await showCupertinoDialog<bool>(
      context: context,
      builder: (ctx) => CupertinoAlertDialog(
        title: const Text('Thêm kho tiện ích?'),
        content: Text(
          '${sourceEngineName(engine)}\n\n$url\n\nỨng dụng sẽ kiểm tra chỉ mục trước khi lưu kho.',
        ),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Hủy'),
          ),
          CupertinoDialogAction(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Xác nhận'),
          ),
        ],
      ),
    );
    if (accepted != true || !mounted) return;
    setState(() => adding = true);
    await perform(
      context,
      () => ref.read(extensionCatalogueProvider.notifier).add(engine, url),
      success: 'Đã thêm kho tiện ích mở rộng',
    );
    if (mounted) setState(() => adding = false);
  }

  Future<void> refresh() => perform(
    context,
    () => ref.read(extensionCatalogueProvider.notifier).refresh(),
  );

  Future<void> rename(ExtensionIndex index) async {
    final name = await showDialog<String>(
      context: context,
      builder: (_) => _RepositoryNameDialog(index: index),
    );
    if (name == null || !mounted) return;
    await perform(
      context,
      () => ref
          .read(extensionCatalogueProvider.notifier)
          .rename(index.identity, name),
    );
  }

  Widget repository(ExtensionIndex index) => Padding(
    key: ValueKey(index.identity),
    padding: const EdgeInsets.fromLTRB(16, 16, 8, 16),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.only(top: 2, right: 14),
          child: Icon(CupertinoIcons.square_stack_3d_up, size: 25),
        ),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(index.displayName, style: const TextStyle(fontSize: 16)),
              const SizedBox(height: 5),
              SelectableText(
                index.url,
                style: TextStyle(
                  fontSize: 13,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 5),
              Text(
                '${index.entries.length} tiện ích mở rộng',
                style: const TextStyle(fontSize: 12),
              ),
              if (index.error.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(
                  index.error,
                  style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context).colorScheme.error,
                  ),
                ),
              ],
            ],
          ),
        ),
        Column(
          children: [
            IconButton(
              tooltip: 'Đổi tên kho',
              icon: const Icon(CupertinoIcons.pencil, size: 22),
              onPressed: () => rename(index),
            ),
            IconButton(
              tooltip: 'Sao chép link kho',
              icon: const Icon(CupertinoIcons.doc_on_doc, size: 22),
              onPressed: () => perform(
                context,
                () => Clipboard.setData(ClipboardData(text: index.url)),
                success: 'Đã sao chép link kho',
              ),
            ),
            IconButton(
              tooltip: 'Gỡ kho khỏi danh sách',
              icon: const Icon(CupertinoIcons.trash, size: 22),
              onPressed: () async {
                if (!await confirmRemoveRepository(
                      context,
                      index.displayName,
                    ) ||
                    !mounted) {
                  return;
                }
                await perform(
                  context,
                  () => ref
                      .read(extensionCatalogueProvider.notifier)
                      .remove(index.identity),
                );
              },
            ),
          ],
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final indexes = ref.watch(extensionCatalogueProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Kho tiện ích mở rộng'),
        actions: [
          IconButton(
            tooltip: 'Thêm kho tiện ích mở rộng',
            onPressed: adding ? null : add,
            icon: adding
                ? const CupertinoActivityIndicator()
                : const Icon(CupertinoIcons.plus),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: refresh,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: EdgeInsets.only(
            bottom: MediaQuery.paddingOf(context).bottom + 16,
          ),
          children: indexes.when(
            loading: () => const [LinearProgressIndicator()],
            error: (error, _) => [
              BrowseNote(userFacingError(error), onRetry: refresh),
            ],
            data: (values) => [
              if (values.isEmpty)
                const BrowseNote(
                  'Chưa có kho tiện ích mở rộng. Nhấn + để nhập link kho.',
                ),
              for (final index in values) ...[
                repository(index),
                const Divider(height: .5, thickness: .5),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _RepositoryNameDialog extends StatefulWidget {
  const _RepositoryNameDialog({required this.index});
  final ExtensionIndex index;
  @override
  State<_RepositoryNameDialog> createState() => _RepositoryNameDialogState();
}

class _RepositoryNameDialogState extends State<_RepositoryNameDialog> {
  late final controller = TextEditingController(text: widget.index.label);
  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Đổi tên kho'),
    content: TextField(
      controller: controller,
      maxLength: 100,
      decoration: InputDecoration(
        labelText: 'Tên riêng',
        hintText: widget.index.name.isEmpty
            ? sourceEngineName(widget.index.engine)
            : widget.index.name,
        helperText: 'Để trống để dùng tên từ kho.',
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Hủy'),
      ),
      TextButton(
        onPressed: () => Navigator.pop(context, controller.text.trim()),
        child: const Text('Lưu'),
      ),
    ],
  );
}

class _RepositoryUrlDialog extends StatefulWidget {
  const _RepositoryUrlDialog({required this.engine});
  final SourceEngine engine;

  @override
  State<_RepositoryUrlDialog> createState() => _RepositoryUrlDialogState();
}

class _RepositoryUrlDialogState extends State<_RepositoryUrlDialog> {
  final url = TextEditingController();
  String? error;

  void submit() {
    try {
      final normalized = ExtensionIndexRepository.normalize(
        url.text.trim(),
        widget.engine,
      );
      Navigator.pop(context, normalized.toString());
    } catch (e) {
      setState(() => error = userFacingError(e));
    }
  }

  @override
  void dispose() {
    url.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text('Thêm kho ${sourceEngineName(widget.engine)}'),
    content: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: url,
            keyboardType: TextInputType.url,
            autocorrect: false,
            onSubmitted: (_) => submit(),
            decoration: InputDecoration(
              labelText: 'Link kho extension',
              errorText: error,
            ),
          ),
          TextButton(
            onPressed: () => url.text = widget.engine == SourceEngine.tachimanga
                ? 'https://github.com/keiyoushi/extensions'
                : 'https://raw.githubusercontent.com/Darkrai9x/vbook-extensions/master/plugin.json',
            child: Text(
              widget.engine == SourceEngine.tachimanga
                  ? 'Dùng kho Keiyoushi'
                  : 'Dùng kho vBook / Darkrai9x',
            ),
          ),
          if (widget.engine == SourceEngine.vbook)
            const Text(
              'Với vbookext.me, sao chép link kho của tác giả rồi dán vào đây.',
              style: TextStyle(fontSize: 12),
            ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Hủy'),
      ),
      TextButton(onPressed: submit, child: const Text('Thêm')),
    ],
  );
}
