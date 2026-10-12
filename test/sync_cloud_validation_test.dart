import 'package:flutter_test/flutter_test.dart';
import 'package:tachi_books/features/sync/data/firestore_sync_remote.dart';
import 'package:tachi_books/features/sync/domain/sync_engine.dart';

void main() {
  Map<String, dynamic> head({int bytes = 100, int parts = 1}) => {
    'id': 'a' * 32,
    'digest': 'b' * 64,
    'bytes': bytes,
    'parts': parts,
  };

  test('maximum 128 MiB full snapshot fits 256 bounded chunks', () {
    final parsed = FirestoreSyncRemote.parseHead(
      head(bytes: 128 * 1024 * 1024, parts: 256),
    );
    expect(parsed.parts, 256);
    expect(FirestoreSyncRemote.namespace, 'tachiBooksUsers');
  });

  test('legacy and incremental heads keep explicit format compatibility', () {
    expect(FirestoreSyncRemote.parseHead(head()).format, 1);
    expect(FirestoreSyncRemote.parseHead({...head(), 'format': 1}).format, 1);
    expect(FirestoreSyncRemote.parseHead({...head(), 'format': 2}).format, 2);
  });

  test('oversize, inconsistent count and path-shaped IDs are rejected before allocating payload', () {
    for (final malformed in [
      head(bytes: 128 * 1024 * 1024 + 1, parts: 256),
      head(bytes: 100, parts: 32),
      head(bytes: 0),
      {...head(), 'id': '../another-user'},
      {...head(), 'bytes': 100.0},
      {...head(), 'digest': 'not-a-digest'},
      {...head(), 'format': 1.0},
      {...head(), 'format': 2.0},
      {...head(), 'format': null},
      {...head(), 'format': 3},
    ]) {
      expect(
        () => FirestoreSyncRemote.parseHead(malformed),
        throwsA(isA<SyncFailure>()),
      );
    }
  });
}
