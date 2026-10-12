import 'dart:typed_data';

/// Only schema-2 manifests belong here; full schema-1 library payloads do not.
/// Bound both the count and bytes because a manifest for many chapters can grow.
class SyncManifestCache {
  SyncManifestCache({this.maxEntries = 4, this.maxBytes = 8 * 1024 * 1024});
  final int maxEntries, maxBytes;
  final _values = <String, Uint8List>{};
  int _bytes = 0;

  int get length => _values.length;
  int get bytes => _bytes;

  Uint8List? get(String id) {
    final value = _values.remove(id);
    if (value != null) _values[id] = value;
    return value;
  }

  void put(String id, Uint8List value) {
    final previous = _values.remove(id);
    if (previous != null) _bytes -= previous.length;
    if (maxEntries <= 0 || value.length > maxBytes) return;
    while (_values.isNotEmpty &&
        (_values.length >= maxEntries || _bytes + value.length > maxBytes)) {
      _bytes -= _values.remove(_values.keys.first)!.length;
    }
    final copy = Uint8List.fromList(value).asUnmodifiableView();
    _values[id] = copy;
    _bytes += copy.length;
  }
}
