import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../domain/library_book.dart';

class BookMetadataEdit {
  const BookMetadataEdit({
    required this.title,
    required this.alternativeTitles,
    required this.author,
    required this.artist,
    required this.series,
    required this.description,
    required this.notes,
  });
  final String title, author, artist, series, description, notes;
  final List<String> alternativeTitles;
}

Future<BookMetadataEdit?> showBookMetadataEditor(
  BuildContext context,
  LibraryBook book,
) => Navigator.of(context).push<BookMetadataEdit>(
  CupertinoPageRoute(builder: (_) => _BookMetadataEditor(book: book)),
);

class _BookMetadataEditor extends StatefulWidget {
  const _BookMetadataEditor({required this.book});
  final LibraryBook book;
  @override
  State<_BookMetadataEditor> createState() => _BookMetadataEditorState();
}

class _BookMetadataEditorState extends State<_BookMetadataEditor> {
  final form = GlobalKey<FormState>();
  late final fields = <String, TextEditingController>{
    'Tên truyện': TextEditingController(text: widget.book.title),
    'Tên khác 1': TextEditingController(
      text: widget.book.alternativeTitles.elementAtOrNull(0) ?? '',
    ),
    'Tên khác 2': TextEditingController(
      text: widget.book.alternativeTitles.elementAtOrNull(1) ?? '',
    ),
    'Tác giả': TextEditingController(text: widget.book.author),
    'Họa sĩ': TextEditingController(text: widget.book.artist),
    'Bộ truyện': TextEditingController(text: widget.book.series),
    'Mô tả': TextEditingController(text: widget.book.description),
    'Ghi chú cá nhân': TextEditingController(text: widget.book.notes),
  };
  @override
  void dispose() {
    for (final controller in fields.values) {
      controller.dispose();
    }
    super.dispose();
  }

  void save() {
    if (!form.currentState!.validate()) return;
    final titles = [
      fields['Tên khác 1']!.text.trim(),
      fields['Tên khác 2']!.text.trim(),
    ].where((name) => name.isNotEmpty).toList();
    Navigator.pop(
      context,
      BookMetadataEdit(
        title: fields['Tên truyện']!.text.trim(),
        alternativeTitles: titles,
        author: fields['Tác giả']!.text.trim(),
        artist: fields['Họa sĩ']!.text.trim(),
        series: fields['Bộ truyện']!.text.trim(),
        description: fields['Mô tả']!.text,
        notes: fields['Ghi chú cá nhân']!.text,
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Thông tin truyện'),
      actions: [TextButton(onPressed: save, child: const Text('Lưu'))],
    ),
    body: Form(
      key: form,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            'Tên khác giúp tìm truyện trong thư viện. Bạn có thể lưu tối đa hai tên.',
          ),
          const SizedBox(height: 12),
          for (final field in fields.entries)
            Padding(
              padding: const EdgeInsets.only(bottom: 14),
              child: TextFormField(
                controller: field.value,
                key: ValueKey('metadata-${field.key}'),
                decoration: InputDecoration(labelText: field.key),
                minLines: field.key == 'Mô tả' || field.key == 'Ghi chú cá nhân'
                    ? 3
                    : 1,
                maxLines: field.key == 'Mô tả' || field.key == 'Ghi chú cá nhân'
                    ? 8
                    : 2,
                maxLength:
                    field.key == 'Mô tả' || field.key == 'Ghi chú cá nhân'
                    ? 20000
                    : 1024,
                validator: (value) {
                  if (field.key == 'Tên truyện' &&
                      (value ?? '').trim().isEmpty) {
                    return 'Tên truyện không được để trống.';
                  }
                  if (field.key == 'Tên khác 2' &&
                      (value ?? '').trim().isNotEmpty &&
                      value!.trim() == fields['Tên khác 1']!.text.trim()) {
                    return 'Hai tên khác phải khác nhau.';
                  }
                  return null;
                },
              ),
            ),
        ],
      ),
    ),
  );
}
