import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../domain/library_book.dart';
import '../domain/library_duplicates.dart';

Future<void> showLibraryDuplicates(
  BuildContext context,
  List<LibraryBook> books,
) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  showDragHandle: true,
  builder: (sheetContext) {
    final duplicates = libraryDuplicates(books);
    return SizedBox(
      height: MediaQuery.sizeOf(sheetContext).height * .75,
      child: ListView(
        children: [
          const ListTile(
            title: Text('Truyện có tên trùng nhau'),
            subtitle: Text(
              'Các bản dịch hoặc ấn bản khác nhau có thể trùng tên. Mở từng truyện để đối chiếu trước khi quyết định xóa.',
            ),
          ),
          if (duplicates.isEmpty)
            const ListTile(
              title: Text('Không tìm thấy tên trùng trong thư viện.'),
            ),
          for (final group in duplicates) ...[
            ListTile(
              title: Text(group.first.title),
              subtitle: Text('${group.length} truyện'),
            ),
            for (final book in group)
              ListTile(
                title: Text(book.title),
                subtitle: Text(
                  '${book.author}\n${book.engine == 'local' ? 'Truyện cục bộ' : '${book.engine} · ${book.sourceId}'} · ${book.chapters.length} chương',
                ),
                isThreeLine: true,
                trailing: const Icon(Icons.chevron_right),
                onTap: () {
                  Navigator.pop(sheetContext);
                  context.push('/book/${book.id}');
                },
              ),
            const Divider(),
          ],
        ],
      ),
    );
  },
);
