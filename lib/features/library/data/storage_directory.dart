import 'dart:io';

/// Canonicalize only verified Apple system aliases, never caller-owned links.
/// The stores still reject links in every remaining parent and destination.
Directory storageDirectory(String path) {
  final normalized = Directory(path).absolute.uri.normalizePath().toFilePath();
  if (Platform.isIOS || Platform.isMacOS) {
    const aliases = {'/var': '/private/var', '/tmp': '/private/tmp'};
    for (final entry in aliases.entries) {
      if ((normalized == entry.key || normalized.startsWith('${entry.key}/')) &&
          FileSystemEntity.typeSync(entry.key, followLinks: false) ==
              FileSystemEntityType.link &&
          Directory(entry.key).resolveSymbolicLinksSync() == entry.value) {
        return Directory(
          '${entry.value}${normalized.substring(entry.key.length)}',
        );
      }
    }
  }
  return Directory(normalized);
}
