import 'package:flutter/material.dart';

class LibraryFolderNameDialog extends StatefulWidget {
  const LibraryFolderNameDialog({super.key, this.initial});
  final String? initial;
  @override
  State<LibraryFolderNameDialog> createState() => _FolderNameState();
}

class _FolderNameState extends State<LibraryFolderNameDialog> {
  final form = GlobalKey<FormState>();
  late final controller = TextEditingController(text: widget.initial ?? '');
  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    scrollable: true,
    title: Text(widget.initial == null ? 'Gom vào thư mục' : 'Đổi tên thư mục'),
    content: Form(
      key: form,
      child: TextFormField(
        key: const ValueKey('folder-name'),
        controller: controller,
        autofocus: true,
        maxLength: 256,
        decoration: const InputDecoration(labelText: 'Tên thư mục'),
        validator: (value) =>
            (value ?? '').trim().isEmpty ? 'Nhập tên thư mục.' : null,
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Hủy'),
      ),
      TextButton(
        onPressed: () {
          if (form.currentState!.validate()) {
            Navigator.pop(context, controller.text.trim());
          }
        },
        child: const Text('Lưu'),
      ),
    ],
  );
}
