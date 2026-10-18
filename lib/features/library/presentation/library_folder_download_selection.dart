import 'package:flutter/material.dart';

import '../domain/library_grouping.dart';
import 'library_filter_picker.dart';

Future<Set<String>?> showLibraryFolderDownloadSelection(
  BuildContext context,
  List<LibraryGroup> folders,
) async {
  Set<String> bookIds(Set<String> keys) => {
    for (final folder in folders)
      if (keys.contains(folder.key)) ...folder.bookIds,
  };

  final keys = await showLibraryFilterMultiPicker(
    context,
    title: 'Tải nhiều thư mục',
    options: {
      for (final folder in folders)
        folder.key: '${folder.label} (${folder.bookIds.length} truyện)',
    },
    selected: const {},
    requireSelection: true,
    applyLabel: (keys) => 'Tiếp tục tải ${keys.length} thư mục',
    selectionSummary: (keys) =>
        '${keys.length} thư mục · ${bookIds(keys).length} truyện không trùng',
  );
  return keys == null ? null : bookIds(keys);
}
