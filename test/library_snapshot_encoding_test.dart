import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tachi_books/features/library/data/backup_configuration.dart';
import 'package:tachi_books/features/library/data/library_snapshot.dart';
import 'package:tachi_books/features/library/domain/library_book.dart';
import 'package:tachi_books/features/sources/domain/catalogue.dart';
import 'package:tachi_books/features/sources/domain/extension_backup.dart';

LibrarySnapshot _snapshot() => LibrarySnapshot(
  [
    LibrarySnapshotEntry(
      LibraryBook(
        id: 'z',
        title: 'Tiếng Việt 😀',
        cover: 'data:image/png;base64,AQID',
        chapters: const [BookChapter(id: 'c', title: 'C', index: 0)],
      ),
      {
        0: ReaderContent(
          kind: 'novel',
          html: '<p>A<img src="data:image/png,%01%02%03"></p>',
          headers: const {'Z': 'z', 'A': 'a'},
        ),
      },
    ),
    LibrarySnapshotEntry(LibraryBook(id: 'a', title: 'A'), {}),
  ],
  configuration: BackupConfiguration.fromJson({
    'version': 1,
    'preferences': {'dark': true, 'libraryColumns': 5},
  }),
  extensions: ExtensionBackup([
    ExtensionBackupPackage.create(
      engine: SourceEngine.tachimanga,
      id: 'eu.kanade.tachiyomi.extension.test',
      name: 'Fixture',
      bytes: base64Decode('UEsDBAECAwQ='),
    ),
  ]),
);

void main() {
  // Captured from the released v1 codec before switching to per-book encoding.
  // These bytes/fingerprints also protect restore CAS and the sync contract.
  test('v1 bytes and fingerprint remain identical with metadata, extension bytes, Unicode and canonical media', () {
    final snapshot = _snapshot();
    expect(snapshot.encode().length, 1397);
    expect(
      sha256.convert(snapshot.encode()).toString(),
      'a0c1f5d76a4e0036f72846a76fe35b8264e8844d0919d74436f613b55a985946',
    );
    expect(
      snapshot.fingerprint,
      'f35115f57c4bac6be6c5eeaae4ba27cfb977d2b4b6750dd637553d2ed1651692',
    );
    expect(
      sha256.convert(snapshot.encode(canonicalMedia: true)).toString(),
      snapshot.fingerprint,
    );
    expect(jsonDecode(utf8.decode(snapshot.encode())), snapshot.toJson());
    snapshot.checkEncodedSize();
  });

  test('entry ordering cannot change existing backup fingerprints', () {
    final snapshot = _snapshot();
    final reversed = LibrarySnapshot(
      snapshot.entries.reversed,
      configuration: snapshot.configuration,
      extensions: snapshot.extensions,
    );
    expect(reversed.encode(), snapshot.encode());
    expect(reversed.fingerprint, snapshot.fingerprint);
  });

  test('size enforcement applies to the complete streamed envelope', () {
    final notes = 'a' * (1024 * 1024);
    final snapshot = LibrarySnapshot([
      for (var i = 0; i < 129; i++)
        LibrarySnapshotEntry(
          LibraryBook(id: '$i', title: 'Large', notes: notes),
          {},
        ),
    ]);
    expect(snapshot.checkEncodedSize, throwsFormatException);
    expect(() => snapshot.fingerprint, throwsFormatException);
  });
}
