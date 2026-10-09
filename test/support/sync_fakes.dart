import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:tachi_books/features/sync/data/google_session.dart';
import 'package:tachi_books/features/sync/domain/sync_engine.dart';

Uint8List sampleSnapshot({
  double progress = 0,
  String html = '<p>Nội dung đã tải</p>',
}) => Uint8List.fromList(
  utf8.encode(
    jsonEncode({
      'schema': 'test-library-snapshot',
      'progress': progress,
      'html': html,
    }),
  ),
);

class FakeSyncLocal implements SyncLocal {
  FakeSyncLocal({Uint8List? bytes, this.savedLink})
    : bytes = bytes ?? sampleSnapshot();
  Uint8List bytes;
  SyncLink? savedLink;
  int snapshots = 0, replaces = 0;
  void Function()? beforeReplace;
  @override
  SyncLink? get link => savedLink;
  @override
  Future<void> saveLink(SyncLink link) async => savedLink = link;
  @override
  Future<Uint8List> snapshot() async {
    snapshots++;
    return Uint8List.fromList(bytes);
  }

  @override
  String fingerprint(Uint8List bytes) => sha256.convert(bytes).toString();
  @override
  void validate(Uint8List bytes) {
    if ((jsonDecode(utf8.decode(bytes)) as Map)['schema'] !=
        'test-library-snapshot') {
      throw const FormatException('invalid snapshot');
    }
  }

  @override
  Future<void> replace(
    Uint8List source, {
    required String expectedFingerprint,
  }) async {
    beforeReplace?.call();
    if (fingerprint(bytes) != expectedFingerprint) {
      throw const SyncFailure('local compare-and-swap failed');
    }
    replaces++;
    bytes = Uint8List.fromList(source);
  }
}

class FakeSyncRemote implements SyncRemote {
  SyncHead? current;
  Uint8List? bytes;
  int headReads = 0, downloads = 0, publishes = 0;
  Object? headError;
  void Function()? beforePublish;
  void Function()? beforeDownload;
  String nextId = '11111111111111111111111111111111';
  @override
  Future<SyncHead?> head() async {
    headReads++;
    if (headError != null) throw headError!;
    return current;
  }

  void seed(Uint8List data, {String id = '22222222222222222222222222222222'}) {
    bytes = Uint8List.fromList(data);
    current = SyncHead(
      id: id,
      parts: 1,
      bytes: data.length,
      digest: sha256.convert(data).toString(),
    );
  }

  @override
  Future<Uint8List> download(SyncHead head) async {
    downloads++;
    beforeDownload?.call();
    return Uint8List.fromList(bytes!);
  }

  @override
  Future<SyncHead> publish(
    Uint8List data, {
    required String? expectedHead,
  }) async {
    beforePublish?.call();
    if (current?.id != expectedHead) {
      throw const SyncFailure('remote compare-and-swap failed');
    }
    publishes++;
    seed(data, id: nextId);
    return current!;
  }
}

class FakeSyncAuth implements SyncAuth {
  SyncUser? user;
  SyncUser? signInResult = const SyncUser(
    uid: 'alice',
    name: 'Alice',
    email: 'alice@example.org',
  );
  Object? error;
  int initializes = 0, signIns = 0, signOuts = 0;
  @override
  SyncUser? get currentUser => user;
  @override
  Future<void> initialize() async {
    initializes++;
    if (error != null) throw error!;
  }

  @override
  Future<SyncUser?> signIn() async {
    signIns++;
    if (error != null) throw error!;
    if (signInResult != null) user = signInResult;
    return signInResult;
  }

  @override
  Future<void> signOut() async {
    signOuts++;
    user = null;
  }
}
