import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tachi_books/features/sources/data/extension_index.dart';
import 'package:tachi_books/features/sources/domain/catalogue.dart';

Uint8List field(int id, List<int> data) {
  List<int> number(int value) {
    final result = <int>[];
    while (value > 127) {
      result.add((value & 127) | 128);
      value >>= 7;
    }
    return [...result, value];
  }

  return Uint8List.fromList([
    ...number((id << 3) | 2),
    ...number(data.length),
    ...data,
  ]);
}

Uint8List message(List<List<int>> fields) =>
    Uint8List.fromList(fields.expand((x) => x).toList());
Uint8List text(int id, String value) => field(id, utf8.encode(value));

void main() {
  test(
    'Keiyoushi root and obsolete indexes normalize to actual protobuf store',
    () {
      for (final url in [
        'https://github.com/keiyoushi/extensions',
        'https://raw.githubusercontent.com/keiyoushi/extensions/repo/index.min.json',
        'https://raw.githubusercontent.com/keiyoushi/extensions/repo/repo.json',
      ]) {
        expect(
          ExtensionIndexRepository.normalize(url, SourceEngine.tachimanga).path,
          '/keiyoushi/extensions/repo/index.pb',
        );
      }
    },
  );
  test(
    'Mihon protobuf list supplies absolute package URLs and exact package IDs',
    () async {
      final extension = message([
        text(1, 'Fixture'),
        text(2, 'eu.kanade.tachiyomi.extension.en.fixture'),
        field(3, message([text(1, 'apk/fixture.apk'), text(2, 'icon.png')])),
        text(6, '1.4.2'),
        field(8, message([text(2, 'Fixture'), text(3, 'en')])),
      ]);
      final store = message([
        text(1, 'Fixture repo'),
        field(101, field(1, extension)),
      ]);
      final repo = ExtensionIndexRepository(
        MockClient((request) async {
          expect(request.url.path, '/index.pb');
          return http.Response.bytes(store, 200);
        }),
      );
      final result = await repo.fetch(
        'https://repo.test/index.pb',
        SourceEngine.tachimanga,
      );
      expect(
        result.entries.single.packageUrl,
        'https://repo.test/apk/fixture.apk',
      );
      expect(result.entries.single.version, '1.4.2');
      expect(result.entries.single.lang, 'en');
      expect(result.entries.single.installed, false);
    },
  );
  test(
    'vBook JSON resolves plugin links without a running companion',
    () async {
      final repo = ExtensionIndexRepository(
        MockClient(
          (_) async => http.Response(
            jsonEncode({
              'data': [
                {
                  'name': 'Fixture',
                  'path': 'fixture/plugin.zip',
                  'version': 13,
                  'locale': 'vi_VN',
                },
              ],
            }),
            200,
          ),
        ),
      );
      final result = await repo.fetch(
        'https://repo.test/path/plugin.json',
        SourceEngine.vbook,
      );
      expect(
        result.entries.single.packageUrl,
        'https://repo.test/path/fixture/plugin.zip',
      );
      expect(result.entries.single.installed, false);
    },
  );
  test('legacy tachi JSON links APKs and keeps IDs as strings', () async {
    final repo = ExtensionIndexRepository(
      MockClient(
        (_) async => http.Response(
          jsonEncode([
            {
              'name': 'Fixture',
              'pkg': 'eu.kanade.tachiyomi.extension.fixture',
              'apk': 'fixture.apk',
              'version': '1.4.1',
              'lang': 'all',
            },
          ]),
          200,
        ),
      ),
    );
    final result = await repo.fetch(
      'https://repo.test/root/index.min.json',
      SourceEngine.tachimanga,
    );
    expect(
      result.entries.single.packageUrl,
      'https://repo.test/root/apk/fixture.apk',
    );
  });
  test('credential URLs, APK traversal, duplicated IDs and oversized indexes are rejected', () async {
    expect(
      () => ExtensionIndexRepository.validUrl(
        'https://user:password@repo.test/plugin.json',
      ),
      throwsFormatException,
    );
    for (final body in [
      [
        {'name': 'Fixture', 'pkg': 'fixture', 'apk': '../x.apk'},
      ],
      [
        {'name': 'Fixture', 'pkg': 'fixture', 'apk': 'x.apk'},
        {'name': 'Other', 'pkg': 'fixture', 'apk': 'y.apk'},
      ],
    ]) {
      final repo = ExtensionIndexRepository(
        MockClient((_) async => http.Response(jsonEncode(body), 200)),
      );
      await expectLater(
        repo.fetch('https://repo.test/index.json', SourceEngine.tachimanga),
        throwsFormatException,
      );
    }
    final large = ExtensionIndexRepository(
      MockClient.streaming(
        (_, _) async => http.StreamedResponse(
          Stream.value(utf8.encode('[]')),
          200,
          contentLength: ExtensionIndexRepository.maxBytes + 1,
        ),
      ),
    );
    await expectLater(
      large.fetch('https://repo.test/index.json', SourceEngine.tachimanga),
      throwsFormatException,
    );
  });
  test(
    'protobuf rejects missing APK URLs and duplicate package identities',
    () async {
      Uint8List extension(String apk) => message([
        text(1, 'Fixture'),
        text(2, 'fixture'),
        field(3, message([text(1, apk)])),
        text(6, '1.4.1'),
      ]);
      for (final entries in [
        [extension('')],
        [extension('a.apk'), extension('b.apk')],
      ]) {
        final store = field(
          101,
          message(entries.map((entry) => field(1, entry)).toList()),
        );
        final repo = ExtensionIndexRepository(
          MockClient((_) async => http.Response.bytes(store, 200)),
        );
        await expectLater(
          repo.fetch('https://repo.test/index.pb', SourceEngine.tachimanga),
          throwsFormatException,
        );
      }
    },
  );
  test(
    'external protobuf extension list resolves resources relative to that list',
    () async {
      final list = field(
        1,
        message([
          text(1, 'Fixture'),
          text(2, 'fixture'),
          field(3, message([text(1, 'apk/fixture.apk')])),
        ]),
      );
      final requests = <String>[];
      final repo = ExtensionIndexRepository(
        MockClient((request) async {
          requests.add(request.url.toString());
          return http.Response.bytes(
            request.url.path == '/index.pb'
                ? text(102, 'catalogue/list.pb')
                : list,
            200,
          );
        }),
      );
      final loaded = await repo.fetch(
        'https://repo.test/index.pb',
        SourceEngine.tachimanga,
      );
      expect(requests, [
        'https://repo.test/index.pb',
        'https://repo.test/catalogue/list.pb',
      ]);
      expect(
        loaded.entries.single.packageUrl,
        'https://repo.test/catalogue/apk/fixture.apk',
      );
    },
  );
  test(
    'gzip indexes are decoded and checked before protobuf parsing',
    () async {
      final store = field(
        101,
        field(
          1,
          message([
            text(1, 'Compressed fixture'),
            text(2, 'fixture'),
            field(3, text(1, 'fixture.apk')),
          ]),
        ),
      );
      final compressed = gzip.encode(store);
      final repo = ExtensionIndexRepository(
        MockClient((_) async => http.Response.bytes(compressed, 200)),
      );
      final loaded = await repo.fetch(
        'https://repo.test/index.pb',
        SourceEngine.tachimanga,
      );
      expect(loaded.entries.single.name, 'Compressed fixture');
      for (final data in [
        compressed.sublist(0, compressed.length - 4),
        [
          ...compressed.sublist(0, compressed.length - 8),
          0,
          0,
          0,
          0,
          ...compressed.sublist(compressed.length - 4),
        ],
        gzip.encode(Uint8List(ExtensionIndexRepository.maxBytes + 1)),
      ]) {
        final invalid = ExtensionIndexRepository(
          MockClient((_) async => http.Response.bytes(data, 200)),
        );
        await expectLater(
          invalid.fetch('https://repo.test/index.pb', SourceEngine.tachimanga),
          throwsFormatException,
        );
      }
    },
  );
  test('truncated protobuf and website HTML fail before claiming any installed extensions', () async {
    for (final data in [
      <int>[0xaa, 6, 20, 1],
      utf8.encode('<html>website</html>'),
    ]) {
      final repo = ExtensionIndexRepository(
        MockClient((_) async => http.Response.bytes(data, 200)),
      );
      await expectLater(
        repo.fetch('https://repo.test/index.pb', SourceEngine.tachimanga),
        throwsFormatException,
      );
    }
  });
  test('live public Keiyoushi and vBook indexes expose downloadable packages', () async {
    final client = http.Client();
    addTearDown(client.close);
    final repo = ExtensionIndexRepository(client);
    final tachi = await repo.fetch(
      'https://github.com/keiyoushi/extensions',
      SourceEngine.tachimanga,
    );
    expect(tachi.entries.length, greaterThan(100));
    expect(
      tachi.entries.every((entry) => entry.packageUrl.endsWith('.apk')),
      true,
    );
    expect(tachi.entries.every((entry) => !entry.installed), true);
    final vbook = await repo.fetch(
      'https://raw.githubusercontent.com/Darkrai9x/vbook-extensions/master/plugin.json',
      SourceEngine.vbook,
    );
    expect(vbook.entries.length, greaterThan(10));
    expect(
      vbook.entries.every((entry) => entry.packageUrl.endsWith('.zip')),
      true,
    );
    expect(vbook.entries.every((entry) => !entry.installed), true);
    // Only counts, never user data or downloaded package execution.
    // ignore: avoid_print
    print(
      'Live indexes: ${tachi.entries.length} tachi, ${vbook.entries.length} vBook.',
    );
  }, skip: Platform.environment['TACHI_LIVE_EXTENSION_INDEX'] != '1');
}
