import 'dart:convert';
import 'dart:typed_data';

import '../../library/data/library_snapshot.dart';
import '../../library/data/backup_configuration.dart';
import '../../library/domain/library_book.dart';
import '../../sources/domain/extension_backup.dart';

class SyncRecordConflict {
  const SyncRecordConflict(this.key, this.title, this.local, this.remote);
  final String key, title;
  final Object? local, remote;
  bool get localDeleted => local == null;
  bool get remoteDeleted => remote == null;
}

/// A book and all its cached chapter contents form one indivisible record.
/// Never pair metadata from one chapter layout with another layout's media.
class SyncMergePlan {
  SyncMergePlan._(
    this._root,
    this._entries,
    this._settings,
    this.conflicts,
    this.hasBaseline,
    this._configuration,
    this._extensions,
    this._hasExtensions,
  );
  final Map<String, dynamic> _root;
  final Map<String, Object?> _entries, _settings;
  final Map<String, dynamic>? _configuration;
  final Map<String, Object?> _extensions;
  final bool _hasExtensions;
  final List<SyncRecordConflict> conflicts;
  final bool hasBaseline;

  static SyncMergePlan? tryBuild(
    Uint8List local,
    Uint8List remote, {
    Uint8List? baseline,
  }) {
    Map<String, dynamic>? parse(Uint8List bytes) {
      final value = jsonDecode(utf8.decode(bytes));
      return value is Map<String, dynamic> &&
              value['schema'] == 'tachi-books-backup' &&
              value['version'] == 1 &&
              value['entries'] is List
          ? value
          : null;
    }

    final l = parse(local),
        r = parse(remote),
        b = baseline == null ? null : parse(baseline);
    if (l == null || r == null || (baseline != null && b == null)) return null;
    // Inputs were validated by SyncLocal. Re-serialize through the same domain
    // objects as the snapshot fingerprint so old omitted defaults and alternate
    // embedded-image encodings do not masquerade as independent edits.
    Map<String, Object?> records(Map<String, dynamic>? root) {
      final result = <String, Object?>{};
      for (final raw in root?['entries'] as List? ?? const []) {
        final entry = raw as Map;
        final book = LibraryBook.fromJson(
          Map<String, dynamic>.from(entry['book'] as Map),
        );
        final contents = {
          for (final item in (entry['contents'] as Map).entries)
            int.parse(item.key as String): ReaderContent.fromJson(
              Map<String, dynamic>.from(item.value as Map),
            ),
        };
        result[book.id] = LibrarySnapshotEntry(
          book,
          contents,
        ).toJson(canonicalMedia: true);
      }
      return result;
    }

    final ls = records(l), rs = records(r), bs = records(b);
    final entries = <String, Object?>{}, settings = <String, Object?>{};
    final conflicts = <SyncRecordConflict>[];
    void choose(
      String key,
      String title,
      Object? left,
      Object? right,
      Object? base,
      Map<String, Object?> target,
      String targetKey,
    ) {
      if (_same(left, right)) {
        target[targetKey] = left;
      } else if (b != null && _same(left, base)) {
        target[targetKey] = right;
      } else if (b != null && _same(right, base)) {
        target[targetKey] = left;
      } else if (b == null && (left == null || right == null)) {
        target[targetKey] = left ?? right;
      } else {
        conflicts.add(SyncRecordConflict(key, title, left, right));
      }
    }

    final ids = {...ls.keys, ...rs.keys, ...bs.keys}.toList()..sort();
    for (final id in ids) {
      final present = (ls[id] ?? rs[id] ?? bs[id]) as Map;
      choose(
        'book:$id',
        (present['book'] as Map)['title'] as String,
        ls[id],
        rs[id],
        bs[id],
        entries,
        id,
      );
    }
    Map<String, Object?> values(Map<String, dynamic>? root) {
      final configuration = root?['configuration'];
      if (configuration == null) return {};
      return Map<String, Object?>.from(
        BackupConfiguration.fromJson(configuration)
                .toJson(canonical: true)['preferences']
            as Map,
      );
    }

    final lc = values(l), rc = values(r), bc = values(b);
    for (final key in {...lc.keys, ...rc.keys, ...bc.keys}) {
      // Whole-field omission uses the same retain semantics as backup restore;
      // explicit configuration images still allow individual key deletions.
      if (!l.containsKey('configuration') || !r.containsKey('configuration')) {
        settings[key] = lc[key] ?? rc[key];
      } else {
        choose(
          'setting:$key',
          'Thiết lập: $key',
          lc[key],
          rc[key],
          bc[key],
          settings,
          key,
        );
      }
    }
    final configuration =
        l['configuration'] ?? r['configuration'] ?? b?['configuration'];
    Map<String, Object?> packages(Map<String, dynamic>? root) => {
      for (final package
          in root?['extensions'] == null
              ? <ExtensionBackupPackage>[]
              : ExtensionBackup.fromJson(root!['extensions']).packages)
        package.identity: package.toJson(),
    };
    final le = packages(l),
        re = packages(r),
        be = packages(b),
        extensions = <String, Object?>{};
    for (final key in {...le.keys, ...re.keys, ...be.keys}) {
      final present = (le[key] ?? re[key] ?? be[key]) as Map;
      // Restore is additive for installed packages. Neither an old client's
      // omitted field nor a missing package in a partial bundle means uninstall,
      // even when that package existed in the common baseline.
      if (!le.containsKey(key) || !re.containsKey(key)) {
        extensions[key] = le[key] ?? re[key];
      } else {
        choose(
          'extension:$key',
          'Extension: ${present['name']}',
          le[key],
          re[key],
          be[key],
          extensions,
          key,
        );
      }
    }
    return SyncMergePlan._(
      {...l}
        ..remove('entries')
        ..remove('configuration')
        ..remove('extensions'),
      entries,
      settings,
      List.unmodifiable(conflicts),
      b != null,
      configuration == null
          ? null
          : Map<String, dynamic>.from(configuration as Map),
      extensions,
      l.containsKey('extensions') || r.containsKey('extensions'),
    );
  }

  Uint8List encode(Map<String, bool> choices) {
    final entries = {..._entries},
        settings = {..._settings},
        extensions = {..._extensions};
    for (final conflict in conflicts) {
      if (!choices.containsKey(conflict.key)) {
        throw const FormatException('Hãy chọn dữ liệu cho mọi mục xung đột.');
      }
      final value = choices[conflict.key]! ? conflict.local : conflict.remote;
      if (conflict.key.startsWith('book:')) {
        entries[conflict.key.substring(5)] = value;
      } else if (conflict.key.startsWith('extension:')) {
        extensions[conflict.key.substring(10)] = value;
      } else {
        settings[conflict.key.substring(8)] = value;
      }
    }
    final ids = entries.keys.toList()..sort();
    final bytes = Uint8List.fromList(
      utf8.encode(
        jsonEncode(
          _canonical({
            ..._root,
            'entries': [
              for (final id in ids)
                if (entries[id] != null) entries[id],
            ],
            if (_hasExtensions)
              'extensions': ExtensionBackup.fromJson({
                'version': 1,
                'packages': [
                  for (final entry in extensions.entries)
                    if (entry.value != null) entry.value,
                ],
              }).toJson(),
            if (_configuration != null)
              'configuration': {
                ..._configuration,
                'preferences': {
                  for (final entry in settings.entries)
                    if (entry.value != null) entry.key: entry.value,
                },
              },
          }),
        ),
      ),
    );
    if (bytes.length > LibrarySnapshot.maxBytes) {
      throw const FormatException('Bản hợp nhất vượt giới hạn 128 MiB.');
    }
    return bytes;
  }
}

bool _same(Object? a, Object? b) =>
    jsonEncode(_canonical(a)) == jsonEncode(_canonical(b));
Object? _canonical(Object? value) {
  if (value is Map) {
    final keys = value.keys.cast<String>().toList()..sort();
    return {for (final key in keys) key: _canonical(value[key])};
  }
  if (value is List) return value.map(_canonical).toList();
  return value;
}
