import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Disposable cover cache, separate from downloaded chapters and backup data.
/// Names are hashes of engine/source/URL; no credentials or URLs are written.
class SourceCoverCache {
  SourceCoverCache(this.directory);
  final Directory directory;
  static const maxBytes = 64 * 1024 * 1024;
  static const maxEntryBytes = 12 * 1024 * 1024;
  static const lifetime = Duration(days: 7);
  Future<void> _writes = Future.value();
  int generation = 0;

  File _file(String key) {
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(key)) {
      throw ArgumentError('Invalid cover cache key');
    }
    return File('${directory.path}/$key.json');
  }

  Future<Map<String, dynamic>?> read(String key) async {
    final file = _file(key);
    try {
      await _writes;
      final stat = await file.stat();
      if (stat.type != FileSystemEntityType.file ||
          stat.size > maxEntryBytes ||
          DateTime.now().difference(stat.modified) > lifetime) {
        return null;
      }
      final value = jsonDecode(await file.readAsString());
      return value is Map<String, dynamic> ? value : null;
    } catch (_) {
      return null; // Cache failures must not prevent a source request.
    }
  }

  Future<void> write(
    String key,
    Map<String, dynamic> value,
    int expectedGeneration,
  ) {
    final result = _writes.then((_) async {
      if (generation != expectedGeneration) return;
      final encoded = utf8.encode(jsonEncode(value));
      if (encoded.length > maxEntryBytes) return;
      await directory.create(recursive: true);
      final file = _file(key);
      final pending = File('${file.path}.pending');
      try {
        await pending.writeAsBytes(encoded, flush: true);
        if (generation != expectedGeneration) return;
        await pending.rename(file.path);
        final entries = <({File file, FileStat stat})>[];
        var bytes = 0;
        await for (final entity in directory.list(followLinks: false)) {
          if (entity is! File ||
              !RegExp(r'[/\\][a-f0-9]{64}\.json$').hasMatch(entity.path)) {
            continue;
          }
          final stat = await entity.stat();
          if (stat.type != FileSystemEntityType.file) continue;
          entries.add((file: entity, stat: stat));
          bytes += stat.size;
        }
        entries.sort((a, b) => a.stat.modified.compareTo(b.stat.modified));
        for (final entry in entries) {
          if (bytes <= maxBytes &&
              DateTime.now().difference(entry.stat.modified) <= lifetime) {
            break;
          }
          await entry.file.delete();
          bytes -= entry.stat.size;
        }
      } finally {
        if (await pending.exists()) await pending.delete();
      }
    });
    _writes = result.catchError((Object _) {});
    return _writes;
  }

  Future<void> remove(String key) {
    final result = _writes.then((_) async {
      final file = _file(key);
      if (await file.exists()) await file.delete();
    });
    _writes = result.catchError((Object _) {});
    return _writes;
  }

  Future<void> clear() {
    generation++;
    final result = _writes.then((_) async {
      if (!await directory.exists()) return;
      await for (final entity in directory.list(followLinks: false)) {
        if (entity is File &&
            RegExp(r'[/\\][a-f0-9]{64}\.json(?:\.pending)?$')
                .hasMatch(entity.path)) {
          await entity.delete();
        }
      }
    });
    _writes = result.catchError((Object _) {});
    return _writes;
  }
}
