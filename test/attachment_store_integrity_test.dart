import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tachi_books/features/library/data/attachment_store_native.dart';

void main() {
  late Directory directory;
  late AttachmentStore store;
  final bytes = Uint8List.fromList([137, 80, 78, 71, 13, 10, 26, 10, 1, 2, 3]);

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('tachi-asset-integrity-');
    store = await AttachmentStore.open(directory.path);
  });
  tearDown(() async {
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  test('stored bytes retain their content address after reopening', () async {
    final reference = await store.store('book', bytes, 'image/png');
    final uri = Uri.parse(reference);
    expect(uri.host, sha256.convert(utf8.encode('book')).toString());
    expect(uri.path, '/${sha256.convert(bytes)}');
    final reopened = await AttachmentStore.open(directory.path);
    expect(
      await reopened.resolve(reference),
      'data:image/png;base64,${base64Encode(bytes)}',
    );
    final files = await _assetFile(directory, reference).parent.list().toList();
    expect(files, hasLength(1));
    expect(files.single, isA<File>());
  });

  test(
    'truncated existing attachment is repaired rather than reused',
    () async {
      final reference = await store.store('book', bytes, 'image/png');
      final file = _assetFile(directory, reference);
      await file.writeAsBytes(bytes.sublist(0, 3), flush: true);
      await expectLater(store.resolve(reference), throwsFormatException);
      expect(await store.store('book', bytes, 'image/png'), reference);
      expect(await file.readAsBytes(), bytes);
      expect(
        await store.resolve(reference),
        'data:image/png;base64,${base64Encode(bytes)}',
      );
      expect(await file.parent.list().toList(), hasLength(1));
    },
  );

  test(
    'same-size corruption is rejected on resolve and repaired on store',
    () async {
      final reference = await store.store('book', bytes, 'image/png');
      final file = _assetFile(directory, reference);
      final corrupted = Uint8List.fromList(bytes)..[bytes.length - 1] = 9;
      await file.writeAsBytes(corrupted, flush: true);
      await expectLater(store.resolve(reference), throwsFormatException);
      expect(await file.readAsBytes(), corrupted);
      await store.store('book', bytes, 'image/png');
      expect(await file.readAsBytes(), bytes);
      expect(await file.parent.list().toList(), hasLength(1));
    },
  );

  test('valid existing attachment is preserved without rewriting it', () async {
    final reference = await store.store('book', bytes, 'image/png');
    final file = _assetFile(directory, reference);
    await file.setLastModified(DateTime(2001, 2, 3));
    final before = await file.lastModified();
    await store.store('book', bytes, 'image/png');
    expect(await file.lastModified(), before);
    expect(await file.readAsBytes(), bytes);
  });

  test(
    'concurrent stores publish one complete file and clean staging files',
    () async {
      final other = await AttachmentStore.open(directory.path);
      final references = await Future.wait([
        store.store('book', bytes, 'image/png'),
        other.store('book', bytes, 'image/png'),
        store.store('book', bytes, 'image/png'),
      ]);
      expect(references.toSet(), hasLength(1));
      final file = _assetFile(directory, references.first);
      expect(await file.readAsBytes(), bytes);
      expect(await file.parent.list().toList(), hasLength(1));
      expect(
        await other.resolve(references.first),
        'data:image/png;base64,${base64Encode(bytes)}',
      );
    },
  );

  test('oversized inputs and oversized stored files are rejected', () async {
    final oversized = Uint8List(8 * 1024 * 1024 + 1);
    await expectLater(
      store.store('oversized', oversized, 'image/png'),
      throwsFormatException,
    );
    final reference = await store.store('book', bytes, 'image/png');
    await _assetFile(directory, reference).writeAsBytes(oversized, flush: true);
    await expectLater(store.resolve(reference), throwsFormatException);
  });
}

File _assetFile(Directory directory, String reference) {
  final uri = Uri.parse(reference);
  return File('${directory.path}/attachments/${uri.host}${uri.path}');
}
