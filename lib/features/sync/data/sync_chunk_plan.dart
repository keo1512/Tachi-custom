import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../../library/data/library_snapshot.dart';
import '../domain/sync_engine.dart';

/// Immutable, content-addressed pieces. A reading-position edit changes book
/// metadata, without uploading the cover and cached chapter payloads again.
class SyncChunkPlan {
  SyncChunkPlan._(this.manifest, this.chunks);
  final Uint8List manifest;
  final Map<String, Uint8List> chunks;
  static const chunkBytes = 384 * 1024;
  static const format = 'tachi-books-cloud-payload-2';

  static SyncChunkPlan build(Uint8List snapshot) {
    if (snapshot.isEmpty || snapshot.length > LibrarySnapshot.maxBytes) {
      throw const SyncFailure('Nội dung đồng bộ vượt giới hạn 128 MiB.');
    }
    final root = jsonDecode(utf8.decode(snapshot)) as Map<String, dynamic>;
    if (root['schema'] != 'tachi-books-backup' || root['entries'] is! List) {
      throw const SyncFailure('Không nhận diện được dữ liệu đồng bộ.');
    }
    final chunks = <String, Uint8List>{};
    List<Map<String, Object>> store(Object? value) {
      final bytes = _encode(value);
      return [
        for (var start = 0; start < bytes.length; start += chunkBytes)
          (() {
            final piece = Uint8List.sublistView(
              bytes,
              start,
              (start + chunkBytes).clamp(0, bytes.length),
            );
            final hash = sha256.convert(piece).toString();
            chunks.putIfAbsent(hash, () => Uint8List.fromList(piece));
            return {'hash': hash, 'bytes': piece.length};
          })(),
      ];
    }

    final entries = <Object>[];
    for (final raw in root['entries'] as List) {
      final entry = raw as Map<String, dynamic>;
      final book = Map<String, dynamic>.from(entry['book'] as Map);
      final cover = book.remove('cover');
      entries.add({
        'book': store(book),
        if (cover != null) 'cover': store(cover),
        'contents': {
          for (final item in (entry['contents'] as Map).entries)
            item.key as String: store(item.value),
        },
      });
    }
    final canonical = _encode(root);
    return SyncChunkPlan._(
      _encode({
        'schema': format,
        'version': 2,
        'bytes': canonical.length,
        'digest': sha256.convert(canonical).toString(),
        'root': {
          ...Map<String, dynamic>.from(root)
            ..remove('entries')
            ..remove('configuration')
            ..remove('extensions'),
          if (root.containsKey('configuration'))
            'configuration': store(root['configuration']),
          if (root.containsKey('extensions'))
            'extensions': {
              'version': (root['extensions'] as Map)['version'],
              'packages': [
                for (final package
                    in (root['extensions'] as Map)['packages'] as List)
                  {
                    'metadata': store({
                      ...Map<String, dynamic>.from(package as Map)
                        ..remove('data'),
                    }),
                    'data': store(package['data']),
                  },
              ],
            },
          'entries': entries,
        },
      }),
      Map.unmodifiable(chunks),
    );
  }

  static Map<String, dynamic> _manifest(Uint8List bytes) {
    if (bytes.isEmpty || bytes.length > LibrarySnapshot.maxBytes) {
      throw const SyncFailure('Mục lục đồng bộ vượt giới hạn.');
    }
    final value = jsonDecode(utf8.decode(bytes));
    if (value is! Map<String, dynamic> ||
        value['schema'] != format ||
        value['version'] != 2 ||
        value['root'] is! Map<String, dynamic> ||
        value['bytes'] is! int ||
        value['bytes'] < 1 ||
        value['bytes'] > LibrarySnapshot.maxBytes ||
        value['digest'] is! String ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(value['digest'])) {
      throw const SyncFailure('Mục lục đồng bộ không hợp lệ.');
    }
    return value;
  }

  static Map<String, int> inventory(Uint8List manifest) {
    final root = _manifest(manifest)['root'] as Map<String, dynamic>;
    if (root['schema'] != 'tachi-books-backup' ||
        root['version'] != 1 ||
        root['entries'] is! List ||
        (root['entries'] as List).length > 10000) {
      throw const SyncFailure('Danh sách truyện trên cloud không hợp lệ.');
    }
    final result = <String, int>{};
    var expanded = 0;
    void inspect(Object? value) {
      if (value is! List || value.isEmpty || value.length > 342) {
        throw const SyncFailure('Danh sách phần nội dung không hợp lệ.');
      }
      for (final item in value) {
        if (item is! Map ||
            item['hash'] is! String ||
            !RegExp(r'^[a-f0-9]{64}$').hasMatch(item['hash']) ||
            item['bytes'] is! int ||
            item['bytes'] < 1 ||
            item['bytes'] > chunkBytes) {
          throw const SyncFailure('Thông tin phần nội dung không hợp lệ.');
        }
        final hash = item['hash'] as String, size = item['bytes'] as int;
        if (result[hash] != null && result[hash] != size) {
          throw const SyncFailure('Kích thước phần nội dung không khớp.');
        }
        result[hash] = size;
        expanded += size;
        if (expanded > LibrarySnapshot.maxBytes) {
          throw const SyncFailure('Nội dung cloud vượt giới hạn 128 MiB.');
        }
      }
    }

    if (root.containsKey('configuration')) inspect(root['configuration']);
    if (root.containsKey('extensions')) {
      final extensions = root['extensions'];
      if (extensions is! Map ||
          extensions['version'] != 1 ||
          extensions['packages'] is! List ||
          (extensions['packages'] as List).length > 512) {
        throw const SyncFailure('Danh sách extension trên cloud không hợp lệ.');
      }
      for (final package in extensions['packages'] as List) {
        if (package is! Map) {
          throw const SyncFailure('Gói extension trên cloud không hợp lệ.');
        }
        inspect(package['metadata']);
        inspect(package['data']);
      }
    }
    for (final entry in root['entries'] as List) {
      if (entry is! Map || entry['contents'] is! Map) {
        throw const SyncFailure('Thông tin truyện trên cloud không hợp lệ.');
      }
      inspect(entry['book']);
      if (entry.containsKey('cover')) inspect(entry['cover']);
      for (final value in (entry['contents'] as Map).values) {
        inspect(value);
      }
    }
    return Map.unmodifiable(result);
  }

  static Uint8List assemble(Uint8List manifest, Map<String, Uint8List> chunks) {
    final expected = inventory(manifest);
    for (final entry in expected.entries) {
      final bytes = chunks[entry.key];
      if (bytes == null ||
          bytes.length != entry.value ||
          sha256.convert(bytes).toString() != entry.key) {
        throw const SyncFailure(
          'Nội dung cloud thiếu hoặc không khớp mã kiểm tra.',
        );
      }
    }
    Object? read(Object? descriptors) {
      final joined = BytesBuilder(copy: false);
      for (final item in descriptors as List) {
        joined.add(chunks[(item as Map)['hash']]!);
      }
      return jsonDecode(utf8.decode(joined.takeBytes()));
    }

    final info = _manifest(manifest);
    final root = Map<String, dynamic>.from(info['root'] as Map);
    root['entries'] = [
      for (final item in root['entries'] as List)
        {
          'book': {
            ...read((item as Map)['book']) as Map,
            if (item.containsKey('cover')) 'cover': read(item['cover']),
          },
          'contents': {
            for (final content in (item['contents'] as Map).entries)
              content.key as String: read(content.value),
          },
        },
    ];
    if (root.containsKey('configuration')) {
      root['configuration'] = read(root['configuration']);
    }
    if (root.containsKey('extensions')) {
      final extensions = root['extensions'] as Map;
      root['extensions'] = {
        'version': extensions['version'],
        'packages': [
          for (final package in extensions['packages'] as List)
            {
              ...read((package as Map)['metadata']) as Map,
              'data': read(package['data']),
            },
        ],
      };
    }
    final bytes = _encode(root);
    if (bytes.length != info['bytes'] ||
        sha256.convert(bytes).toString() != info['digest']) {
      throw const SyncFailure('Thư viện cloud không khớp mã kiểm tra.');
    }
    return bytes;
  }
}

Uint8List _encode(Object? value) =>
    Uint8List.fromList(utf8.encode(jsonEncode(_canonical(value))));
Object? _canonical(Object? value) {
  if (value is Map) {
    final keys = value.keys.cast<String>().toList()..sort();
    return {for (final key in keys) key: _canonical(value[key])};
  }
  if (value is List) return value.map(_canonical).toList();
  return value;
}
