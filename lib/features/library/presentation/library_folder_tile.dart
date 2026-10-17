import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../domain/library_grouping.dart';

class LibraryFolderTile extends StatelessWidget {
  const LibraryFolderTile({
    super.key,
    required this.folder,
    required this.onTap,
    this.onLongPress,
    this.list = false,
  });
  final LibraryGroup folder;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final bool list;

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.primary;
    if (list) {
      return ListTile(
        leading: Icon(CupertinoIcons.folder_fill, size: 44, color: color),
        title: Text(folder.label),
        subtitle: Text('${folder.bookIds.length} truyện'),
        trailing: const Icon(CupertinoIcons.chevron_right, size: 16),
        onTap: onTap,
        onLongPress: onLongPress,
      );
    }
    return Semantics(
      label: '${folder.label}, ${folder.bookIds.length} truyện, thư mục',
      button: true,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        borderRadius: BorderRadius.circular(12),
        child: Column(
          children: [
            Expanded(
              child: Container(
                width: double.infinity,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: .12),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: FittedBox(
                    fit: BoxFit.contain,
                    child: Icon(CupertinoIcons.folder_fill, color: color),
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                folder.label,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 12),
              ),
            ),
            Text(
              '${folder.bookIds.length} truyện',
              maxLines: 1,
              style: Theme.of(context).textTheme.labelSmall,
            ),
          ],
        ),
      ),
    );
  }
}
