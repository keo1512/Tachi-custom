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
    'protobuf preserves int64 and string source names before installation',
    () async {
      List<int> scalar(int id, BigInt value) {
        final result = <int>[(id << 3)];
        while (value > BigInt.from(127)) {
          result.add((value & BigInt.from(127)).toInt() | 128);
          value >>= 7;
        }
        return [...result, value.toInt()];
      }

      final extension = message([
        text(1, 'Fixture'),
        text(2, 'extension.fixture'),
        field(3, message([text(1, 'fixture.apk')])),
        field(
          8,
          message([
            scalar(1, BigInt.parse('8222087175453285202')),
            text(2, 'CuuTruyen'),
            text(3, 'vi'),
          ]),
        ),
        field(
          8,
          message([
            text(1, '8070257113818912648'),
            text(2, 'MiMiHentai'),
            text(3, 'vi'),
          ]),
        ),
      ]);
      final store = message([field(101, field(1, extension))]);
      final repo = ExtensionIndexRepository(
        MockClient((_) async => http.Response.bytes(store, 200)),
      );
      final result = await repo.fetch(
        'https://repo.test/index.pb',
        SourceEngine.tachimanga,
      );
      expect(result.entries.single.sources.map((s) => s.id), [
        '8222087175453285202',
        '8070257113818912648',
      ]);
      expect(result.entries.single.sources.map((s) => s.name), [
        'CuuTruyen',
        'MiMiHentai',
      ]);
      expect(result.entries.single.installed, isFalse);
    },
  );
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
      expect(result.entries.single.iconUrl, 'https://repo.test/icon.png');
      expect(result.entries.single.lang, 'en');
      expect(result.entries.single.installed, false);
      expect(result.name, 'Fixture repo');
      expect(result.displayName, 'Fixture repo');
    },
  );
  test(
    'vBook JSON resolves plugin links without a running companion',
    () async {
      final repo = ExtensionIndexRepository(
        MockClient(
          (_) async => http.Response(
            jsonEncode({
              'name': 'Kho truyện chữ',
              'data': [
                {
                  'name': 'Fixture',
                  'path': 'fixture/plugin.zip',
                  'version': 13,
                  'locale': 'vi_VN',
                  'icon': 'fixture/icon.png',
                },
              ],
            }),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
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
      expect(result.displayName, 'Kho truyện chữ');
      expect(
        result.entries.single.iconUrl,
        'https://repo.test/path/fixture/icon.png',
      );
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
    expect(
      result.entries.single.iconUrl,
      'https://repo.test/root/icon/eu.kanade.tachiyomi.extension.fixture.png',
    );
  });
  test('current Keiyoushi JSON uses published release resources and package identity', () async {
    // A reduced record from the official current index.json, not the retired
    // flat pkg/apk schema. Source IDs remain strings even though only language
    // is needed by the extension catalogue.
    final entry = {
      'name': 'Komga',
      'packageName': 'eu.kanade.tachiyomi.extension.all.komga',
      'resources': {
        'apkUrl': 'https://github.com/keiyoushi/extensions/releases/download/a2d7e26/tachiyomi-all.komga-v1.6.71.apk',
        'iconUrl': 'https://cdn.jsdelivr.net/gh/keiyoushi/extensions-source@main/src/all/komga/res/mipmap-xhdpi/ic_launcher.png',
        'jarUrl': 'https://github.com/keiyoushi/extensions/releases/download/a2d7e26/tachiyomi-all.komga-v1.6.71.jar',
      },
      'versionName': '1.6.71',
      'sources': [
        {'id': '4508733312114627536', 'language': 'all'},
        {'id': '8074481155021144106', 'language': 'all'},
      ],
    };
    final repo = ExtensionIndexRepository(
      MockClient((request) async {
        expect(
          request.url.toString(),
          'https://raw.githubusercontent.com/keiyoushi/extensions/repo/index.json',
        );
        return http.Response(
          jsonEncode({
            'extensionList': {
              'extensions': [entry],
            },
          }),
          200,
        );
      }),
    );
    final result = await repo.fetch(
      'https://github.com/keiyoushi/extensions/blob/repo/index.json',
      SourceEngine.tachimanga,
    );
    final extension = result.entries.single;
    expect(extension.id, entry['packageName']);
    expect(extension.packageUrl, (entry['resources'] as Map)['apkUrl']);
    expect(extension.iconUrl, (entry['resources'] as Map)['iconUrl']);
    expect(extension.version, '1.6.71');
    expect(extension.lang, 'all');
    expect(extension.installed, isFalse);
  });
  test(
    'current JSON resources resolve relative URLs and combine source languages',
    () async {
      final repo = ExtensionIndexRepository(
        MockClient(
          (_) async => http.Response(
            jsonEncode({
              'extensionList': {
                'extensions': [
                  {
                    'name': 'Multilingual',
                    'packageName': 'eu.kanade.tachiyomi.extension.multi',
                    'versionName': '1.6.1',
                    'resources': {
                      'apkUrl': '../packages/current.apk',
                      'iconUrl': 'icons/current.png',
                    },
                    'sources': [
                      {'language': 'en'},
                      {'language': 'vi'},
                    ],
                  },
                ],
              },
            }),
            200,
          ),
        ),
      );
      final entry = (await repo.fetch(
        'https://repo.test/catalogue/index.json',
        SourceEngine.tachimanga,
      )).entries.single;
      expect(entry.packageUrl, 'https://repo.test/packages/current.apk');
      expect(entry.iconUrl, 'https://repo.test/catalogue/icons/current.png');
      expect(entry.lang, 'all');
    },
  );
  test('current JSON refuses malformed packages and duplicate identities but keeps icons optional', () async {
    Map<String, dynamic> entry(Object? resources) => {
      'name': 'Fixture',
      'packageName': 'eu.kanade.tachiyomi.extension.fixture',
      'resources': resources,
    };
    for (final entries in [
      [entry(null)],
      [
        entry({'apkUrl': ''}),
      ],
      [
        entry({'apkUrl': 'https://user:password@repo.test/a.apk'}),
      ],
      [
        entry({'apkUrl': 'file:///tmp/a.apk'}),
      ],
      [
        entry({'apkUrl': 'a.apk'}),
        entry({'apkUrl': 'b.apk'}),
      ],
    ]) {
      final repo = ExtensionIndexRepository(
        MockClient(
          (_) async => http.Response(
            jsonEncode({
              'extensionList': {'extensions': entries},
            }),
            200,
          ),
        ),
      );
      await expectLater(
        repo.fetch('https://repo.test/index.json', SourceEngine.tachimanga),
        throwsFormatException,
      );
    }
    final repo = ExtensionIndexRepository(
      MockClient(
        (_) async => http.Response(
          jsonEncode({
            'extensionList': {
              'extensions': [
                entry({
                  'apkUrl': 'fixture.apk',
                  'iconUrl': 'javascript:alert(1)',
                }),
              ],
            },
          }),
          200,
        ),
      ),
    );
    final extension = (await repo.fetch(
      'https://repo.test/index.json',
      SourceEngine.tachimanga,
    )).entries.single;
    expect(extension.packageUrl, 'https://repo.test/fixture.apk');
    expect(extension.iconUrl, isEmpty);
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
          field(
            3,
            message([text(1, 'apk/fixture.apk'), text(2, 'icons/fixture.png')]),
          ),
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
      expect(
        loaded.entries.single.iconUrl,
        'https://repo.test/catalogue/icons/fixture.png',
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
      expect(loaded.entries.single.iconUrl, isEmpty);
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
  test('optional malformed icon links do not hide valid packages or trigger image requests', () async {
    for (final icon in [
      null,
      17,
      '',
      'javascript:alert(1)',
      'data:image/png;base64,AA==',
      'https://user:password@icons.test/icon.png',
      'https://icons.test/icon.png#fragment',
      List.filled(4097, 'x').join(),
    ]) {
      var requests = 0;
      final repo = ExtensionIndexRepository(
        MockClient((_) async {
          requests++;
          return http.Response(
            jsonEncode({
              'data': [
                {
                  'name': 'Fixture',
                  'path': 'plugin.zip',
                  'version': 1,
                  'icon': icon,
                },
              ],
            }),
            200,
          );
        }),
      );
      final index = await repo.fetch(
        'https://repo.test/plugin.json',
        SourceEngine.vbook,
      );
      expect(index.entries.single.iconUrl, isEmpty);
      expect(index.entries.single.packageUrl, 'https://repo.test/plugin.zip');
      expect(index.entries.single.installed, isFalse);
      expect(requests, 1);
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
    final jsonIndex = await repo.fetch(
      'https://github.com/keiyoushi/extensions/blob/repo/index.json',
      SourceEngine.tachimanga,
    );
    expect(jsonIndex.entries.length, greaterThan(100));
    final pbKomga = tachi.entries.firstWhere(
      (entry) => entry.id.endsWith('.all.komga'),
    );
    final jsonKomga = jsonIndex.entries.firstWhere(
      (entry) => entry.id == pbKomga.id,
    );
    expect(jsonKomga.packageUrl, pbKomga.packageUrl);
    expect(jsonKomga.iconUrl, pbKomga.iconUrl);
    final apk = await client.get(Uri.parse(pbKomga.packageUrl));
    expect(apk.statusCode, 200);
    expect(apk.bodyBytes.take(4).toList(), [0x50, 0x4b, 0x03, 0x04]);
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
    final tachiIcon = tachi.entries
        .firstWhere((entry) => entry.id.endsWith('.all.komga'))
        .iconUrl;
    final vbookIcon = vbook.entries
        .firstWhere((entry) => entry.name == 'Truyện Full')
        .iconUrl;
    for (final iconUrl in [tachiIcon, vbookIcon]) {
      expect(iconUrl, isNotEmpty);
      final image = await client.get(Uri.parse(iconUrl));
      expect(image.statusCode, 200);
      expect(image.headers['content-type'], startsWith('image/'));
      expect(image.bodyBytes.take(8).toList(), [
        137,
        80,
        78,
        71,
        13,
        10,
        26,
        10,
      ]);
    }
    // Only counts, never user data or downloaded package execution.
    // ignore: avoid_print
    print(
      'Live indexes: ${tachi.entries.length} protobuf/${jsonIndex.entries.length} JSON tachi, ${vbook.entries.length} vBook; Komga APK HTTP200 ${apk.bodyBytes.length} bytes; Komga and Truyện Full icons HTTP200 PNG.',
    );
  }, skip: Platform.environment['TACHI_LIVE_EXTENSION_INDEX'] != '1');
}
