import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tachi_books/features/sync/data/sync_manifest_cache.dart';

void main() {
  test('many published manifests stay within four entries and byte budget', () {
    final cache = SyncManifestCache(maxBytes: 10);
    for (var index = 0; index < 100; index++) {
      cache.put('$index', Uint8List(3));
      expect(cache.length, lessThanOrEqualTo(4));
      expect(cache.bytes, lessThanOrEqualTo(10));
    }
    expect(cache.length, 3);
    expect(cache.get('96'), isNull);
    expect(cache.get('99'), hasLength(3));
  });

  test(
    'reads retain recent manifests while oversized entries are not cached',
    () {
      final cache = SyncManifestCache(maxEntries: 2, maxBytes: 10);
      cache.put('a', Uint8List(2));
      cache.put('b', Uint8List(2));
      expect(cache.get('a'), isNotNull);
      cache.put('c', Uint8List(2));
      expect(cache.get('b'), isNull);
      expect(cache.get('a'), isNotNull);
      expect(cache.get('c'), isNotNull);
      cache.put('large', Uint8List(11));
      expect(cache.get('large'), isNull);
      expect(cache.length, 2);
      expect(cache.bytes, 4);
      cache.put('a', Uint8List(8));
      expect(cache.bytes, 10);
      expect(cache.get('a'), hasLength(8));
    },
  );

  test('cached payload is independent from caller mutations', () {
    final cache = SyncManifestCache();
    final bytes = Uint8List.fromList([1, 2]);
    cache.put('a', bytes);
    bytes[0] = 9;
    final read = cache.get('a')!;
    expect(read, [1, 2]);
    expect(() => read[0] = 9, throwsUnsupportedError);
  });
}
