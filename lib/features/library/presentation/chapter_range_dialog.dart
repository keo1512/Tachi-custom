import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../domain/library_book.dart';

Future<Set<String>?> showChapterRangeDialog(
  BuildContext context,
  List<BookChapter> visible,
) async {
  if (visible.isEmpty) return null;
  final first = TextEditingController(text: '1');
  final last = TextEditingController(text: '${visible.length}');
  final form = GlobalKey<FormState>();
  String? validate(String? value) {
    final number = int.tryParse(value ?? '');
    return number == null || number < 1 || number > visible.length
        ? 'Nhập vị trí từ 1 đến ${visible.length}.'
        : null;
  }

  final result = await showDialog<Set<String>>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Chọn phạm vi chương'),
      content: SingleChildScrollView(
        child: Form(
          key: form,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Theo thứ tự ${visible.length} chương đang hiển thị.'),
              const SizedBox(height: 16),
              for (final entry in [(first, 'Từ vị trí'), (last, 'Đến vị trí')])
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: TextFormField(
                    key: ValueKey('chapter-range-${entry.$2}'),
                    controller: entry.$1,
                    decoration: InputDecoration(labelText: entry.$2),
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    validator: validate,
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('Hủy'),
        ),
        TextButton(
          onPressed: () {
            if (!form.currentState!.validate()) return;
            final a = int.parse(first.text) - 1, b = int.parse(last.text) - 1;
            final from = a < b ? a : b, to = a < b ? b : a;
            Navigator.pop(ctx, {
              for (final chapter in visible.sublist(from, to + 1)) chapter.id,
            });
          },
          child: const Text('Chọn'),
        ),
      ],
    ),
  );
  WidgetsBinding.instance.addPostFrameCallback((_) {
    first.dispose();
    last.dispose();
  });
  return result;
}
