import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tachi_books/features/sources/data/source_repository.dart';
import 'package:tachi_books/features/sources/domain/catalogue.dart';

const source = CatalogueSource(
  id: '9007199254740995',
  name: 'Fixture source',
  lang: 'en',
  baseUrl: 'https://source.example',
  kind: ContentKind.manga,
  engine: SourceEngine.tachimanga,
);
const manga = CatalogueBook(
  ref: '42',
  title: 'Fixture manga',
  sourceId: '9007199254740995',
  kind: ContentKind.manga,
  engine: SourceEngine.tachimanga,
);
const novel = CatalogueBook(
  ref: 'https://source.example/book/1',
  title: 'Fixture novel',
  sourceId: 'fixture-novel',
  kind: ContentKind.novel,
  engine: SourceEngine.vbook,
);

SourceRepository repository(
  Future<http.Response> Function(http.Request) handler, {
  Duration timeout = const Duration(seconds: 30),
}) => SourceRepository(
  tachimangaUrl: 'http://localhost:4567/reader',
  vbookUrl: 'http://localhost:4570',
  client: MockClient(handler),
  timeout: timeout,
);

http.Response jsonResponse(Object value, {int status = 200}) => http.Response(
  jsonEncode(value),
  status,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

void main() {
  test(
    'unconfigured runtimes report a per-engine error without HTTP',
    () async {
      var calls = 0;
      final repo = SourceRepository(
        tachimangaUrl: '',
        vbookUrl: '  ',
        client: MockClient((_) async {
          calls++;
          return jsonResponse({});
        }),
      );
      for (final engine in SourceEngine.values) {
        await expectLater(
          repo.health(engine),
          throwsA(
            isA<ApiException>().having(
              (error) => error.code,
              'missing configuration',
              'NOT_CONFIGURED',
            ),
          ),
        );
      }
      expect(calls, 0);
    },
  );

  test(
    'one configured runtime works while the other remains unconfigured',
    () async {
      for (final engine in SourceEngine.values) {
        final other = engine == SourceEngine.vbook
            ? SourceEngine.tachimanga
            : SourceEngine.vbook;
        var calls = 0;
        final repo = SourceRepository(
          tachimangaUrl: engine == SourceEngine.tachimanga
              ? 'http://localhost:4567'
              : '',
          vbookUrl: engine == SourceEngine.vbook ? 'http://localhost:4570' : '',
          client: MockClient((request) async {
            calls++;
            expect(
              request.url.path,
              engine == SourceEngine.tachimanga
                  ? '/api/v1/settings/about'
                  : '/v1/health',
            );
            return jsonResponse({'name': 'Configured runtime'});
          }),
        );
        expect((await repo.health(engine))['name'], 'Configured runtime');
        await expectLater(
          repo.listSources(other),
          throwsA(
            isA<ApiException>().having(
              (error) => error.code,
              'missing configuration',
              'NOT_CONFIGURED',
            ),
          ),
        );
        expect(calls, 1);
      }
    },
  );

  test('preserves large source identities and scopes them by engine', () async {
    final repo = repository((request) async {
      expect(request.url.path, '/reader/api/v1/source/list');
      return http.Response(
        '[{"id":9007199254740995,"name":"Fixture source","lang":"en","baseUrl":null,"iconUrl":"/api/v1/extension/icon/eu.kanade.tachiyomi.extension.all.komga"}]',
        200,
        headers: {'content-type': 'application/json'},
      );
    });
    final sources = await repo.listSources(SourceEngine.tachimanga);
    expect(sources.single.id, '9007199254740995');
    expect(sources.single.identity, 'tachimanga:9007199254740995');
    expect(sources.single.baseUrl, '');
    expect(sources.single.kind, ContentKind.manga);
    expect(
      sources.single.iconUrl,
      'http://localhost:4567/reader/api/v1/extension/icon/eu.kanade.tachiyomi.extension.all.komga',
    );
  });

  test('optional source icons use returned HTTP URLs and invalid or absent icons fall back', () async {
    final icons = [
      'https://icons.test/source.png',
      'assets/source.png',
      'file:///tmp/source.png',
      'https://user:secret@icons.test/source.png',
      null,
      42,
    ];
    final repo = repository((request) async {
        expect(request.url.path, '/v1/sources');
      return http.Response(
        jsonEncode([
          for (var index = 0; index < icons.length; index++)
            {
              'id': '$index',
              'name': 'Source $index',
              'lang': 'vi',
              'kind': 'novel',
              'baseUrl': 'https://source.test',
              'iconUrl': icons[index],
            },
        ]),
        200,
      );
    });
    final sources = await repo.listSources(SourceEngine.vbook);
    expect(sources.map((source) => source.iconUrl), [
      'https://icons.test/source.png',
        'http://localhost:4570/assets/source.png',
      '',
      '',
      '',
      '',
    ]);
    expect(sources.map((source) => source.identity), [
      'vbook:0',
      'vbook:1',
      'vbook:2',
      'vbook:3',
      'vbook:4',
      'vbook:5',
    ]);
  });

  test(
    'uses the Suwayomi quick-search contract and companion thumbnails',
    () async {
      final repo = repository((request) async {
        expect(request.method, 'POST');
        expect(
          request.url.path,
          '/reader/api/v1/source/9007199254740995/quick-search',
        );
        expect(request.url.queryParameters, {'pageNum': '2'});
        expect(jsonDecode(request.body), {
          'searchTerm': 'name & title',
          'filter': null,
        });
        return jsonResponse({
          'mangaList': [
            {
              'id': 42,
              'sourceId': '9007199254740995',
              'url': '/manga/fixture',
              'title': 'Fixture manga',
              'author': null,
              'thumbnailUrl': 'https://source.example/cover.jpg',
            },
          ],
          'hasNextPage': false,
        });
      });
      final books = await repo.search(source, 'name & title', page: 2);
      expect(books.single.identity, 'tachimanga:9007199254740995:42');
      expect(books.single.author, '');
      expect(
        books.single.coverUrl,
        'http://localhost:4567/reader/api/v1/manga/42/thumbnail',
      );
    },
  );

  test(
    'detail refresh uses onlineFetch and preserves the server source ID',
    () async {
      final repo = repository((request) async {
        expect(request.url.path, '/reader/api/v1/manga/42');
        expect(request.url.queryParameters, {'onlineFetch': 'true'});
        return http.Response(
          '{"id":42,"sourceId":9007199254740995,"title":"Updated manga","author":"Author","description":null}',
          200,
          headers: {'content-type': 'application/json'},
        );
      });
      final book = await repo.detail(manga);
      expect(book.sourceId, '9007199254740995');
      expect(book.title, 'Updated manga');
      expect(book.description, '');
    },
  );

  test('uses chapter source-order indexes rather than database IDs', () async {
    final requests = <http.Request>[];
    final repo = repository((request) async {
      requests.add(request);
      if (request.url.path.endsWith('/chapters')) {
        return jsonResponse([
          {'id': 981, 'index': 7, 'name': 'Chapter 7', 'pageCount': -1},
        ]);
      }
      expect(request.url.path, '/reader/api/v1/manga/42/chapter/7');
      return jsonResponse({'id': 981, 'index': 7, 'pageCount': 2});
    });
    final chapters = await repo.chapters(manga);
    expect(chapters.single.ref, '7');
    expect(requests.single.url.queryParameters, {'onlineFetch': 'true'});
    final content = await repo.chapter(manga, chapters.single);
    expect(content.images, [
      'http://localhost:4567/reader/api/v1/manga/42/chapter/7/page/0?updateProgress=false',
      'http://localhost:4567/reader/api/v1/manga/42/chapter/7/page/1?updateProgress=false',
    ]);
  });

  test('vBook source/search/novel chapter use the runtime contract', () async {
    final repo = repository((request) async {
      if (request.url.path == '/v1/sources') {
        return jsonResponse([
          {
            'id': 'fixture-novel',
            'name': 'Novel source',
            'lang': 'vi',
            'baseUrl': 'https://source.example',
            'kind': 'novel',
            'engine': 'vbook',
          },
        ]);
      }
      if (request.url.path.endsWith('/search')) {
        expect(request.url.queryParameters, {'query': 'hello', 'page': '1'});
        return jsonResponse([
          {
            'ref': novel.ref,
            'title': novel.title,
            'sourceId': novel.sourceId,
            'kind': 'novel',
            'coverUrl': 'https://source.example/cover.jpg',
          },
        ]);
      }
      expect(request.url.path, '/v1/sources/fixture-novel/chapter');
      expect(
        request.url.queryParameters['ref'],
        'https://source.example/chapter/1?a=b&c=d',
      );
      return jsonResponse({'kind': 'novel', 'html': '<p>Chương một.</p>'});
    });
    final sources = await repo.listSources(SourceEngine.vbook);
    final books = await repo.search(sources.single, 'hello');
    expect(books.single.kind, ContentKind.novel);
    final content = await repo.chapter(
      books.single,
      const CatalogueChapter(
        ref: 'https://source.example/chapter/1?a=b&c=d',
        title: 'Chapter 1',
        index: 0,
      ),
    );
    expect(content.html, '<p>Chương một.</p>');
  });

  test('keeps vBook per-image request headers for offline downloads', () async {
    final repo = repository(
      (_) async => jsonResponse({
        'kind': 'manga',
        'headers': {'User-Agent': 'FixtureReader'},
        'images': [
          {
            'url': 'https://source.example/a.jpg',
            'headers': {'Referer': 'https://source.example/book'},
          },
          {
            'url': 'https://source.example/b.jpg',
            'headers': {'Referer': 'https://source.example/other'},
          },
        ],
      }),
    );
    final content = await repo.chapter(
      novel,
      const CatalogueChapter(ref: 'chapter', title: 'Chapter', index: 0),
    );
    expect(content.headersFor(content.images[0]), {
      'User-Agent': 'FixtureReader',
      'Referer': 'https://source.example/book',
    });
    expect(
      content.headersFor(content.images[1])['Referer'],
      'https://source.example/other',
    );
  });

  test(
    'surfaces unsupported vBook runtime capabilities and HTTP status',
    () async {
      final repo = repository(
        (_) async => jsonResponse({
          'error': {
            'code': 'UNSUPPORTED_CAPABILITY',
            'message': 'Browser API chưa được hỗ trợ.',
          },
        }, status: 422),
      );
      await expectLater(
        repo.detail(novel),
        throwsA(
          isA<ApiException>()
              .having((error) => error.statusCode, 'HTTP status', 422)
              .having(
                (error) => error.code,
                'capability code',
                'UNSUPPORTED_CAPABILITY',
              )
              .having(
                (error) => error.message,
                'runtime message',
                contains('Browser'),
              ),
        ),
      );
    },
  );

  test(
    'auth errors and malformed JSON do not become empty source lists',
    () async {
      final unauthorized = repository(
        (_) async => http.Response('<html>sign in</html>', 401),
      );
      await expectLater(
        unauthorized.listSources(SourceEngine.tachimanga),
        throwsA(
          isA<ApiException>().having(
            (error) => error.statusCode,
            'HTTP status',
            401,
          ),
        ),
      );
      final malformed = repository((_) async => http.Response('not JSON', 200));
      await expectLater(
        malformed.listSources(SourceEngine.vbook),
        throwsA(isA<ApiException>()),
      );
    },
  );

  test('health uses settings/about and runtime health endpoints', () async {
    final paths = <String>[];
    final repo = repository((request) async {
      paths.add(request.url.path);
      return jsonResponse({'name': 'Fixture runtime'});
    });
    await repo.health(SourceEngine.tachimanga);
    await repo.health(SourceEngine.vbook);
    expect(paths, ['/reader/api/v1/settings/about', '/v1/health']);
  });

  test(
    'source preferences use actual Suwayomi DTO and string values',
    () async {
      final changes = <Map<String, dynamic>>[];
      final repo = repository((request) async {
        expect(
          request.url.path,
          '/reader/api/v1/source/9007199254740995/preferences',
        );
        if (request.method == 'GET') {
          return jsonResponse([
            {
              'type': 'EditTextPreference',
              'props': {
                'key': 'Address',
                'currentValue': '',
                'defaultValueType': 'String',
              },
            },
          ]);
        }
        expect(request.method, 'POST');
        changes.add(jsonDecode(request.body) as Map<String, dynamic>);
        return jsonResponse({});
      });
      final preferences = await repo.sourcePreferences(source);
      expect(preferences.single['props']['key'], 'Address');
      await repo.setSourcePreference(source, 1, 'http://127.0.0.1:25600');
      await repo.setSourcePreference(source, 2, true);
      await repo.setSourcePreference(source, 3, <String>['a', 'b']);
      expect(changes, [
        {'position': 1, 'value': 'http://127.0.0.1:25600'},
        {'position': 2, 'value': 'true'},
        {'position': 3, 'value': '["a","b"]'},
      ]);
    },
  );

  test('vBook source preferences report unsupported without HTTP', () async {
    final repo = repository((_) async => fail('Must not call HTTP'));
    const novelSource = CatalogueSource(
      id: 'fixture',
      name: 'Novel',
      lang: 'vi',
      baseUrl: 'https://source.example',
      kind: ContentKind.novel,
      engine: SourceEngine.vbook,
    );
    final unsupported = throwsA(
      isA<ApiException>().having(
        (error) => error.code,
        'unsupported code',
        'UNSUPPORTED_CAPABILITY',
      ),
    );
    await expectLater(repo.sourcePreferences(novelSource), unsupported);
    await expectLater(
      repo.setSourcePreference(novelSource, 0, ''),
      unsupported,
    );
  });

  test('installs registered APKs using the package name', () async {
    const pkg = 'eu.kanade.tachiyomi.extension.en.fixture';
    final repo = repository((request) async {
      expect(request.url.path, '/reader/api/v1/extension/install/$pkg');
      expect(request.method, 'GET');
      return http.Response('', 201);
    });
    await repo.installExtension(SourceEngine.tachimanga, pkg);
  });

  test('downloads a direct APK and uploads the multipart file field', () async {
    var calls = 0;
    final repo = repository((request) async {
      calls++;
      if (request.url.host == 'packages.example') {
        return http.Response.bytes([80, 75, 3, 4], 200);
      }
      expect(request.method, 'POST');
      expect(request.url.path, '/reader/api/v1/extension/install');
      expect(
        request.headers['content-type'],
        startsWith('multipart/form-data; boundary='),
      );
      expect(request.body, contains('name="file"; filename="fixture.apk"'));
      return http.Response('', 201);
    });
    await repo.installExtension(
      SourceEngine.tachimanga,
      'https://packages.example/fixture.apk',
    );
    expect(calls, 2);
  });

  test('vBook install and repository addition send original URLs', () async {
    final paths = <String>[];
    final repo = repository((request) async {
      paths.add(request.url.path);
      expect(request.method, 'POST');
      expect(
        jsonDecode(request.body)['url'],
        'https://packages.example/plugin.zip',
      );
      return jsonResponse({'id': 'fixture'}, status: 201);
    });
    await repo.installExtension(
      SourceEngine.vbook,
      'https://packages.example/plugin.zip',
    );
    await repo.addRepository(
      SourceEngine.vbook,
      'https://packages.example/plugin.zip',
    );
    expect(paths, ['/v1/extensions/install', '/v1/repositories']);
  });

  test(
    'Suwayomi repository addition checks GraphQL errors even on HTTP 200',
    () async {
      final repo = repository((request) async {
        expect(request.url.path, '/reader/api/graphql');
        final body = jsonDecode(request.body);
        expect(
          body['variables']['input']['indexUrl'],
          'https://packages.example/index.min.json',
        );
        expect(body['query'], contains('addExtensionStore'));
        return jsonResponse({
          'errors': [
            {'message': 'Cannot query field addExtensionStore'},
          ],
        });
      });
      await expectLater(
        repo.addRepository(
          SourceEngine.tachimanga,
          'https://packages.example/index.min.json',
        ),
        throwsA(
          isA<ApiException>().having(
            (error) => error.code,
            'GraphQL error',
            'GRAPHQL_ERROR',
          ),
        ),
      );
    },
  );

  test(
    'Suwayomi repository addition requires a confirmed mutation payload',
    () async {
      final repo = repository(
        (_) async => jsonResponse({
          'data': {
            'addExtensionStore': {
              'extensionStore': {
                'indexUrl': 'https://packages.example/index.min.json',
              },
            },
          },
        }),
      );
      await repo.addRepository(
        SourceEngine.tachimanga,
        'https://packages.example/index.min.json',
      );
    },
  );

  test('base URL rejects credentials, queries and unsupported schemes', () {
    for (final address in [
      'ftp://localhost',
      'http://user:password@localhost',
      'http://localhost?token=secret',
      'http://localhost#fragment',
      'relative/path',
    ]) {
      expect(
        () => SourceRepository(
          tachimangaUrl: address,
          vbookUrl: 'http://localhost:4570',
        ),
        throwsA(isA<ApiException>()),
      );
    }
  });

  test('times out with a useful error instead of reporting success', () async {
    final repo = repository((_) async {
      await Future<void>.delayed(const Duration(milliseconds: 30));
      return jsonResponse([]);
    }, timeout: const Duration(milliseconds: 1));
    await expectLater(
      repo.listSources(SourceEngine.vbook),
      throwsA(
        isA<ApiException>().having(
          (error) => error.code,
          'timeout code',
          'TIMEOUT',
        ),
      ),
    );
  });

  test(
    'large-number JSON scanner leaves strings and normal numbers intact',
    () {
      final decoded = decodeCatalogueJson(
        r'{"id":-9223372036854775807,"escaped":"say \"9007199254740995\"","fraction":1.25,"exponent":1e3,"small":123}',
      );
      expect(decoded['id'], '-9223372036854775807');
      expect(decoded['escaped'], 'say "9007199254740995"');
      expect(decoded['fraction'], 1.25);
      expect(decoded['exponent'], 1000);
      expect(decoded['small'], 123);
    },
  );

  test('large-number preprocessing does not make malformed JSON valid', () {
    expect(
      () => decodeCatalogueJson('{"id":09007199254740995}'),
      throwsFormatException,
    );
  });
}
