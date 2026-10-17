import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tachi_books/features/sources/data/native_tachi_repository.dart';
import 'package:tachi_books/features/sources/domain/catalogue.dart';

const _sourceId = '9223372036854775806';
const _source = CatalogueSource(
  id: _sourceId,
  name: 'Original source',
  lang: 'vi',
  baseUrl: 'https://source.example',
  kind: ContentKind.manga,
  engine: SourceEngine.tachimanga,
);
const _book = CatalogueBook(
  ref: '/series/original',
  title: 'Original title',
  sourceId: _sourceId,
  kind: ContentKind.manga,
  engine: SourceEngine.tachimanga,
);
const _chapter = CatalogueChapter(
  ref: '/chapter/original',
  title: 'Chapter one',
  index: 7,
);
const _packageUrl = 'https://repo.example/apk/fixture.apk';

// These tests exercise the Dart/storage boundary, not APK class execution.
Uint8List _packageBytes() => Uint8List.fromList(
  ZipEncoder().encode(
    Archive()
      ..add(ArchiveFile.bytes('classes.dex', [1, 2, 3, 4]))
      ..add(
        ArchiveFile.bytes('AndroidManifest.xml', utf8.encode('<manifest/>')),
      ),
  ),
);

Matcher _apiCode(String code) =>
    throwsA(isA<ApiException>().having((error) => error.code, 'code', code));

class _Host {
  _Host(this.handler);
  final FutureOr<Object?> Function(String method, Map<String, dynamic> args)
  handler;
  final requests = <Map<String, dynamic>>[];

  Future<String> execute(String raw) async {
    final request = jsonDecode(raw) as Map<String, dynamic>;
    requests.add(request);
    final method = request['method'] as String;
    final args = request['args'] as Map<String, dynamic>;
    final result = method == 'initialize'
        ? {'engine': 'tachi', 'protocolVersion': 1}
        : await handler(method, args);
    return jsonEncode({'ok': true, 'result': result});
  }
}

void main() {
  late Directory directory;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp(
      'tachibooks-native-tachi-test-',
    );
  });
  tearDown(() async => directory.delete(recursive: true));

  NativeTachiRepository repository(_Host host, {http.Client? client}) =>
      NativeTachiRepository(
        executor: host.execute,
        storageDirectory: directory,
        client: client ?? MockClient((_) async => http.Response('', 500)),
      );

  for (final outcome in [
    'unique',
    'ambiguous',
    'missing',
    'failed-candidate',
  ]) {
    test(
      'restored metadata resolution requires all saved chapter URLs and a unique exact-source result: $outcome',
      () async {
        const restored = CatalogueBook(
          ref: '42',
          title: 'Original title',
          sourceId: _sourceId,
          kind: ContentKind.manga,
          engine: SourceEngine.tachimanga,
          knownChapterRefs: ['/chapter/one', '/chapter/two'],
        );
        var searches = 0, details = 0;
        final host = _Host((method, args) {
          expect(args['sourceId'], _sourceId);
          if (method == 'search') {
            searches++;
            return {
              'items': [
                {'ref': '/wrong', 'title': restored.title},
                {'ref': '/right', 'title': restored.title},
              ],
            };
          }
          if (method == 'chapters') {
            if (args['ref'] == '/wrong' && outcome == 'failed-candidate') {
              throw const ApiException(
                'Candidate could not be verified',
                code: 'TIMEOUT',
              );
            }
            return [
              {'ref': '/chapter/one', 'title': 'One', 'index': 0},
              {
                'ref':
                    outcome == 'ambiguous' ||
                        (args['ref'] == '/right' && outcome == 'unique')
                    ? '/chapter/two'
                    : '/unrelated',
                'title': 'Two',
                'index': 1,
              },
            ];
          }
          expect(method, 'detail');
          details++;
          expect(args['ref'], '/right');
          return {
            'ref': '/right',
            'title': restored.title,
            'author': 'Real author',
            'status': 1,
          };
        });
        final repo = repository(host);
        if (outcome == 'unique') {
          expect((await repo.detail(restored)).author, 'Real author');
          expect(
            (await repo.chapters(restored)).map((c) => c.ref),
            restored.knownChapterRefs,
          );
          expect(searches, 1);
          expect(details, 1);
          expect(restored.ref, '42');
        } else {
          await expectLater(
            repo.detail(restored),
            _apiCode(
              outcome == 'failed-candidate'
                  ? 'TIMEOUT'
                  : 'RESTORED_TITLE_UNRESOLVED',
            ),
          );
          expect(details, 0);
        }
      },
    );
  }
  test('native errors preserve bounded exception types and reject provider identifiers', () async {
    for (final type in [
      'NoSuchMethodError',
      'NoClassDefFoundError',
      'IOException',
      'SourceNotLoadedException',
      'private_token_secret',
      123,
      null,
    ]) {
      final repo = NativeTachiRepository(
        storageDirectory: directory,
        executor: (raw) async {
          final request = jsonDecode(raw) as Map;
          if (request['method'] == 'initialize') {
            return jsonEncode({'ok': true, 'result': {}});
          }
          return jsonEncode({
            'ok': false,
            'error': {
              'code': 'unsupported_extension',
              'message': 'PrivateBook private_token_secret',
              'type': type,
            },
          });
        },
      );
      addTearDown(repo.dispose);
      await expectLater(
        repo.listSources(),
        throwsA(
          isA<ApiException>()
              .having((e) => e.code, 'original code', 'unsupported_extension')
              .having(
                (e) => e.diagnosticType,
                'allowlisted diagnostic type',
                type is String && type != 'private_token_secret' ? type : null,
              ),
        ),
      );
    }
  });

  test('local APK import stages an immutable copy and forwards confirmed host metadata without HTTP', () async {
    final bytes = _packageBytes(),
        original = Uint8List.fromList(_packageBytes());
    final digest = sha256.convert(original).toString();
    final host = _Host((method, args) async {
      expect(method, 'install');
      expect(args['packageUrl'], '');
      expect(args['iconUrl'], '');
      expect(args['packageHash'], digest);
      expect(await File(args['apkPath'] as String).readAsBytes(), original);
      return {
        'installed': true,
        'id': 'eu.kanade.tachiyomi.extension.fixture',
        'name': 'Original APK source',
        'version': '1.6.25',
        'sourceIds': [_sourceId],
      };
    });
    final repo = repository(
      host,
      client: MockClient(
        (_) async => throw StateError('No HTTP needed for Files input.'),
      ),
    );
    final installed = repo.installExtensionBytes(bytes);
    bytes.fillRange(0, bytes.length, 0);
    final package = await installed;
    expect(package.installed, true);
    expect(package.name, 'Original APK source');
    expect(package.sourceIds, [_sourceId]);
    expect(package.version, '1.6.25');
    expect(package.packageUrl, isEmpty);
    expect(
      await Directory('${directory.path}/staging').list().toList(),
      hasLength(1),
    );
  });

  test('local APK invalid/oversized input and unconfirmed engine result cannot report installed', () async {
    var installs = 0;
    final host = _Host((method, _) {
      expect(method, 'install');
      installs++;
      return {'installed': false};
    });
    final repo = repository(host);
    await expectLater(
      repo.installExtensionBytes(Uint8List.fromList([1, 2, 3, 4])),
      _apiCode('INVALID_PACKAGE'),
    );
    await expectLater(
      repo.installExtensionBytes(Uint8List(32 * 1024 * 1024 + 1)),
      _apiCode('PACKAGE_TOO_LARGE'),
    );
    expect(host.requests, isEmpty);
    final input = _packageBytes(),
        expected = Uint8List.fromList(_packageBytes());
    await expectLater(
      repo.installExtensionBytes(input),
      _apiCode('INSTALL_NOT_CONFIRMED'),
    );
    expect(input, expected);
    expect(installs, 1);
    expect(
      await File('${directory.path}/staging/${sha256.convert(expected)}.apk')
          .readAsBytes(),
      expected,
    );
  });

  test(
    'APK bytes and hash are staged before the host confirms installation',
    () async {
      final bytes = _packageBytes();
      final digest = sha256.convert(bytes).toString();
      var downloads = 0;
      var installations = 0;
      final host = _Host((method, args) async {
        expect(method, 'install');
        expect(args['packageUrl'], _packageUrl);
        expect(args['packageHash'], digest);
        final staged = File(args['apkPath'] as String);
        expect(staged.parent.path, Directory('${directory.path}/staging').path);
        expect(staged.uri.pathSegments.last, '$digest.apk');
        expect(await staged.readAsBytes(), bytes);
        expect(
          await staged.parent
              .list()
              .where((file) => file.path.endsWith('.pending'))
              .toList(),
          isEmpty,
        );
        installations++;
        return {
          'installed': true,
          'id': 'eu.kanade.tachiyomi.extension.fixture',
        };
      });
      final repo = repository(
        host,
        client: MockClient((request) async {
          downloads++;
          expect(request.method, 'GET');
          expect(request.url.toString(), _packageUrl);
          return http.Response.bytes(bytes, 200);
        }),
      );
      await repo.installExtension(_packageUrl);
      await repo.installExtension(_packageUrl);
      expect(downloads, 2);
      expect(installations, 2);
      expect(
        host.requests.where((r) => r['method'] == 'initialize'),
        hasLength(1),
      );
      expect(host.requests.first['args'], {'dataDirectory': directory.path});
      expect(
        await Directory('${directory.path}/staging').list().toList(),
        hasLength(1),
      );
    },
  );

  test(
    'failed source loading preserves APK bytes and never claims installed',
    () async {
      final bytes = _packageBytes();
      var installCount = 0;
      final repo = NativeTachiRepository(
        storageDirectory: directory,
        client: MockClient((_) async => http.Response.bytes(bytes, 200)),
        executor: (raw) async {
          final request = jsonDecode(raw) as Map;
          if (request['method'] == 'install') {
            installCount++;
            expect(
              await File(request['args']['apkPath'] as String).readAsBytes(),
              bytes,
            );
            return jsonEncode({
              'ok': false,
              'error': {
                'code': 'unsupported_extension',
                'message': 'Unsupported Android API',
              },
            });
          }
          return jsonEncode({
            'ok': true,
            'result': request['method'] == 'extensions' ? [] : {},
          });
        },
      );
      await expectLater(
        repo.installExtension(_packageUrl),
        _apiCode('unsupported_extension'),
      );
      expect(await repo.extensions(), isEmpty);
      expect(installCount, 1);
      expect(
        await File('${directory.path}/staging/${sha256.convert(bytes)}.apk')
            .readAsBytes(),
        bytes,
      );
    },
  );

  test('simultaneous installs of the same APK from separate handles retain one intact staged file', () async {
    final bytes = _packageBytes();
    final downloadsReady = Completer<void>();
    var downloads = 0;
    var installed = 0;
    final host = _Host((method, args) async {
      expect(method, 'install');
      expect(await File(args['apkPath'] as String).readAsBytes(), bytes);
      installed++;
      return {'installed': true};
    });
    final client = MockClient((_) async {
      if (++downloads == 2) downloadsReady.complete();
      await downloadsReady.future;
      return http.Response.bytes(bytes, 200);
    });
    final repo = repository(host, client: client);
    final peer = repository(host, client: client);
    await Future.wait([
      peer.installExtension(_packageUrl),
      repo.installExtension(_packageUrl),
    ]);
    expect(installed, 2);
    final files = await Directory('${directory.path}/staging').list().toList();
    expect(files, hasLength(1));
    expect(await File(files.single.path).readAsBytes(), bytes);
  });

  test(
    'health, sources and extensions share a single initialization',
    () async {
      final host = _Host(
        (method, _) => method == 'health'
            ? {
                'engine': 'tachi',
                'protocolVersion': 1,
                'sourceCount': 0,
                'execution': 'java-interpreter',
              }
            : [],
      );
      final repo = repository(host);
      final results = await Future.wait<Object>([
        repo.health(),
        repo.listSources(),
        repo.extensions(),
      ]);
      expect((results.first as Map)['protocolVersion'], 1);
      expect((results.first as Map)['execution'], 'java-interpreter');
      expect(
        host.requests.where((r) => r['method'] == 'initialize'),
        hasLength(1),
      );
      expect(host.requests.map((r) => r['method']).toSet(), {
        'initialize',
        'health',
        'sources',
        'extensions',
      });
    },
  );

  test(
    'installation requires an explicit installed true acknowledgement',
    () async {
      final host = _Host(
        (method, _) => method == 'extensions' ? [] : {'installed': false},
      );
      final repo = repository(
        host,
        client: MockClient(
          (_) async => http.Response.bytes(_packageBytes(), 200),
        ),
      );
      await expectLater(
        repo.installExtension(_packageUrl),
        _apiCode('INSTALL_NOT_CONFIRMED'),
      );
      expect(await repo.extensions(), isEmpty);
    },
  );

  test(
    'invalid package URL is rejected before initializing or downloading',
    () async {
      var downloads = 0;
      final host = _Host((_, _) => fail('Must not reach the host'));
      final repo = repository(
        host,
        client: MockClient((_) async {
          downloads++;
          return http.Response.bytes(_packageBytes(), 200);
        }),
      );
      for (final url in [
        'file:///tmp/input.apk',
        'https://user:password@repo.example/a.apk',
        'https://repo.example/a.apk#fragment',
        'not a URL',
      ]) {
        await expectLater(
          repo.installExtension(url),
          throwsA(isA<ApiException>()),
        );
      }
      expect(downloads, 0);
      expect(host.requests, isEmpty);
    },
  );

  test('HTTP failure and non-APK bytes never invoke install', () async {
    for (final response in [
      http.Response('missing', 404),
      http.Response('<html>login</html>', 200),
    ]) {
      final host = _Host(
        (_, _) => fail('Must not install an invalid download'),
      );
      final repo = repository(host, client: MockClient((_) async => response));
      await expectLater(
        repo.installExtension(_packageUrl),
        throwsA(isA<ApiException>()),
      );
      expect(host.requests.map((r) => r['method']), ['initialize']);
    }
  });

  test(
    'APK stream with no declared size is bounded before installation',
    () async {
      final host = _Host(
        (_, _) => fail('Oversized package must not reach install'),
      );
      final block = Uint8List(1024 * 1024);
      final repo = repository(
        host,
        client: MockClient.streaming(
          (_, _) async => http.StreamedResponse(
            Stream<List<int>>.fromIterable(List.filled(33, block)),
            200,
          ),
        ),
      );
      await expectLater(
        repo.installExtension(_packageUrl),
        _apiCode('PACKAGE_TOO_LARGE'),
      );
      expect(host.requests.map((r) => r['method']), ['initialize']);
    },
  );

  test(
    'corrupt staged APK is preserved and not sent to the host again',
    () async {
      final bytes = _packageBytes();
      var installations = 0;
      final host = _Host((_, _) {
        installations++;
        return {'installed': true};
      });
      final repo = repository(
        host,
        client: MockClient((_) async => http.Response.bytes(bytes, 200)),
      );
      await repo.installExtension(_packageUrl);
      final staged = File(
        '${directory.path}/staging/${sha256.convert(bytes)}.apk',
      );
      await staged.writeAsBytes([9, 8, 7]);
      await expectLater(
        repo.installExtension(_packageUrl),
        _apiCode('PACKAGE_CORRUPT'),
      );
      expect(installations, 1);
      expect(await staged.readAsBytes(), [9, 8, 7]);
    },
  );

  test(
    'source and extension records preserve exact string identities',
    () async {
      final host = _Host(
        (method, _) => method == 'sources'
            ? [
                {
                  'id': _sourceId,
                  'name': 'Original source',
                  'lang': 'vi',
                  'baseUrl': _source.baseUrl,
                },
              ]
            : [
                {
                  'id': 'eu.kanade.tachiyomi.extension.fixture',
                  'name': 'Fixture',
                  'version': '1.4.47',
                  'installed': true,
                  'packageUrl': _packageUrl,
                  'sourceIds': [_sourceId],
                  'loadError': 'Source factory cannot load',
                },
              ],
      );
      final repo = repository(host);
      final source = (await repo.listSources()).single;
      expect(source.id, _sourceId);
      expect(source.identity, 'tachimanga:$_sourceId');
      expect(source.kind, ContentKind.manga);
      expect(source.engine, SourceEngine.tachimanga);
      final extension = (await repo.extensions()).single;
      expect(extension.installed, isTrue);
      expect(extension.packageUrl, _packageUrl);
      expect(extension.version, '1.4.47');
      expect(extension.sourceIds, [_sourceId]);
      expect(extension.loadError, 'Source factory cannot load');
    },
  );

  test(
    'numeric JSON source IDs are rejected instead of coercing precision',
    () async {
      final repo = repository(
        _Host(
          (_, _) => [
            {'id': 9223372036854775806, 'name': 'Invalid ID'},
          ],
        ),
      );
      await expectLater(repo.listSources(), _apiCode('INVALID_SOURCE_DATA'));
    },
  );

  test(
    'Java search items envelope preserves page, source ID and metadata',
    () async {
      final host = _Host((method, args) {
        expect(method, 'search');
        expect(args, {'sourceId': _sourceId, 'query': 'Original', 'page': 3});
        return {
          'items': [
            {
              'ref': _book.ref,
              'title': _book.title,
              'author': 'Writer',
              'artist': 'Artist',
              'genres': ['Drama'],
              'description': 'Description',
              'coverUrl': 'https://source.example/cover.jpg',
            },
          ],
          'hasNextPage': false,
          'page': 3,
        };
      });
      final result = (await repository(
        host,
      ).search(_source, 'Original', page: 3)).single;
      expect(result.ref, _book.ref);
      expect(result.sourceId, _sourceId);
      expect(result.author, 'Writer');
      expect(result.artist, 'Artist');
      expect(result.genres, ['Drama']);
    },
  );

  test(
    'detail resolves the original URL without numeric companion IDs',
    () async {
      final host = _Host((method, args) {
        expect(method, 'detail');
        expect(args['sourceId'], _sourceId);
        expect(args['ref'], _book.ref);
        return {'ref': _book.ref, 'title': _book.title, 'status': 5};
      });
      final detail = await repository(host).detail(_book);
      expect(detail.identity, _book.identity);
      expect(detail.status, 5);
    },
  );

  test('chapter URL identity survives changing ordinals and never requests by index', () async {
    var listing = 0;
    final host = _Host((method, args) {
      expect(args['sourceId'], _sourceId);
      if (method == 'chapters') {
        listing++;
        return [
          {'ref': '/chapter/new', 'title': 'New chapter', 'index': 1},
          {
            'ref': _chapter.ref,
            'title': _chapter.title,
            'index': 0,
            'number': 2.5,
            'uploadedAt': 1790960000000,
            'scanlator': 'Original team',
          },
        ];
      }
      expect(method, 'chapter');
      expect(args['ref'], _chapter.ref);
      expect(args['bookRef'], _book.ref);
      expect(args['title'], _chapter.title);
      expect(args.containsKey('index'), isFalse);
      return {
        'images': ['https://images.example/page.jpg'],
        'imageHeaders': {},
      };
    });
    final repo = repository(host);
    final chapters = await repo.chapters(_book);
    expect(chapters.map((c) => c.ref), [_chapter.ref, '/chapter/new']);
    expect(chapters.first.number, 2.5);
    expect(
      chapters.first.uploadedAt,
      DateTime.fromMillisecondsSinceEpoch(1790960000000),
    );
    expect(chapters.first.scanlator, 'Original team');
    expect(chapters.last.number, isNull);
    expect(chapters.last.uploadedAt, isNull);
    await repo.chapter(_book, _chapter);
    await repo.chapter(_book, chapters.first);
    expect(listing, 1);
  });

  test('duplicate chapter URL or index is refused', () async {
    for (final bad in [
      [
        {'ref': '/chapter/a', 'title': 'A', 'index': 0},
        {'ref': '/chapter/a', 'title': 'B', 'index': 1},
      ],
      [
        {'ref': '/chapter/a', 'title': 'A', 'index': 0},
        {'ref': '/chapter/b', 'title': 'B', 'index': 0},
      ],
    ]) {
      await expectLater(
        repository(_Host((_, _) => bad)).chapters(_book),
        _apiCode('INVALID_SOURCE_DATA'),
      );
    }
  });

  test(
    'Java imageHeaders retain per-page Referer, Cookie and overrides',
    () async {
      final host = _Host((method, args) {
        expect(method, 'chapter');
        expect(args['ref'], _chapter.ref);
        return {
          'images': [
            'https://images.example/a.jpg',
            'https://images.example/b.jpg',
          ],
          'headers': {
            'User-Agent': 'Source client',
            'Referer': 'https://source.example/common',
          },
          'imageHeaders': {
            'https://images.example/a.jpg': {
              'Referer': 'https://source.example/chapter/1',
              'Cookie': 'reader=fixture-a',
            },
            'https://images.example/b.jpg': {'Cookie': 'reader=fixture-b'},
          },
        };
      });
      final content = await repository(host).chapter(_book, _chapter);
      expect(content.headersFor(content.images.first), {
        'User-Agent': 'Source client',
        'Referer': 'https://source.example/chapter/1',
        'Cookie': 'reader=fixture-a',
      });
      expect(content.headersFor(content.images.last), {
        'User-Agent': 'Source client',
        'Referer': 'https://source.example/common',
        'Cookie': 'reader=fixture-b',
      });
    },
  );

  test(
    'unresolved legacy numeric book and chapter IDs cannot reach runtime',
    () async {
      final host = _Host((_, _) => fail('Must not guess a legacy reference'));
      final repo = repository(host);
      const legacyBook = CatalogueBook(
        ref: '42',
        title: 'Old',
        sourceId: _sourceId,
        kind: ContentKind.manga,
        engine: SourceEngine.tachimanga,
      );
      await expectLater(
        repo.detail(legacyBook),
        _apiCode('RESTORED_TITLE_UNRESOLVED'),
      );
      await expectLater(
        repo.chapters(legacyBook),
        _apiCode('RESTORED_TITLE_UNRESOLVED'),
      );
      await expectLater(
        repo.chapter(
          _book,
          const CatalogueChapter(ref: '0', title: 'Old chapter', index: 0),
        ),
        _apiCode('CHAPTER_IDENTITY_CHANGED'),
      );
      expect(host.requests, isEmpty);
    },
  );

  test('restored numeric manga IDs do not block known chapter URLs or source image hooks', () async {
    const restored = CatalogueBook(
      ref: '42',
      title: 'Restored',
      sourceId: _sourceId,
      kind: ContentKind.manga,
      engine: SourceEngine.tachimanga,
    );
    final host = _Host((method, args) {
      expect(args['sourceId'], _sourceId);
      if (method == 'chapter') {
        expect(args['ref'], _chapter.ref);
        return {
          'images': ['https://images.example/a.jpg'],
        };
      }
      expect(method, 'image');
      expect(args['chapterRef'], _chapter.ref);
      return {
        'base64': base64Encode([255, 216, 255, 1]),
        'mimeType': 'image/jpeg',
      };
    });
    final repo = repository(host);
    final content = await repo.chapter(restored, _chapter);
    expect(content.images, ['https://images.example/a.jpg']);
    final image = await repo.fetchImage(
      restored,
      _chapter,
      0,
      content.images.single,
    );
    expect(image.bytes, [255, 216, 255, 1]);
    await expectLater(
      repo.detail(restored),
      _apiCode('RESTORED_TITLE_UNRESOLVED'),
    );
  });

  test(
    'inline image headers override root per-page headers without losing Cookie',
    () async {
      final repo = repository(
        _Host(
          (_, _) => {
            'images': [
              {
                'url': 'https://images.example/a.jpg',
                'headers': {'Referer': 'https://source.example/inline'},
              },
            ],
            'headers': {'User-Agent': 'Original source client'},
            'imageHeaders': {
              'https://images.example/a.jpg': {
                'Referer': 'https://source.example/root',
                'Cookie': 'reader=fixture',
              },
            },
          },
        ),
      );
      final content = await repo.chapter(_book, _chapter);
      expect(content.headersFor(content.images.single), {
        'User-Agent': 'Original source client',
        'Referer': 'https://source.example/inline',
        'Cookie': 'reader=fixture',
      });
    },
  );

  test('invalid image URLs and non-string image headers are refused', () async {
    for (final content in [
      {
        'images': ['file:///tmp/page.jpg'],
      },
      {
        'images': ['https://user:password@images.example/page.jpg'],
      },
      {
        'images': ['https://images.example/page.jpg'],
        'imageHeaders': {
          'https://images.example/page.jpg': {'Cookie': 42},
        },
      },
    ]) {
      await expectLater(
        repository(_Host((_, _) => content)).chapter(_book, _chapter),
        throwsA(isA<ApiException>()),
      );
    }
  });

  test(
    'Java preferences become usable UI props and saves target the exact key',
    () async {
      final preferences = [
        {
          'key': 'server_url',
          'title': 'Server URL',
          'summary': '',
          'type': 'String',
          'value': 'https://old.example',
          'defaultValue': '',
        },
        {
          'key': 'read_original',
          'title': 'Original pages',
          'summary': '',
          'type': 'Boolean',
          'value': false,
          'defaultValue': false,
        },
        {
          'key': 'quality',
          'title': 'Quality',
          'summary': '',
          'type': 'String',
          'value': 'full',
          'defaultValue': 'full',
          'entries': ['Full', 'Small'],
          'entryValues': ['full', 'small'],
        },
        {'key': null, 'type': 'PreferenceCategory', 'title': 'Account'},
      ];
      final changes = <Map<String, dynamic>>[];
      final host = _Host((method, args) {
        expect(args['sourceId'], _sourceId);
        if (method == 'preferences') return preferences;
        expect(method, 'setPreference');
        changes.add(args);
        return true;
      });
      final repo = repository(host);
      final result = await repo.sourcePreferences(_source);
      expect(result[0]['type'], 'EditTextPreference');
      expect(result[0]['props']['key'], 'server_url');
      expect(result[0]['props']['currentValue'], 'https://old.example');
      expect(result[1]['type'], 'SwitchPreferenceCompat');
      expect(result[1]['props']['currentValue'], isFalse);
      expect(result[2]['type'], 'ListPreference');
      expect(result[2]['props']['entries'], ['Full', 'Small']);
      await repo.setSourcePreference(_source, 0, 'https://new.example');
      await repo.setSourcePreference(_source, 1, true);
      await repo.setSourcePreference(_source, 2, 'small');
      expect(changes, [
        {
          'sourceId': _sourceId,
          'key': 'server_url',
          'value': 'https://new.example',
        },
        {'sourceId': _sourceId, 'key': 'read_original', 'value': true},
        {'sourceId': _sourceId, 'key': 'quality', 'value': 'small'},
      ]);
      await expectLater(
        repo.setSourcePreference(_source, 9, 'wrong'),
        throwsA(isA<ApiException>()),
      );
      expect(changes, hasLength(3));
      expect(result[3]['type'], 'PreferenceCategory');
      await expectLater(
        repo.setSourcePreference(_source, 3, 'unsupported'),
        _apiCode('UNSUPPORTED_CAPABILITY'),
      );
      expect(changes, hasLength(3));
    },
  );

  test(
    'native initialization failure is translated and a later call can retry',
    () async {
      var initializations = 0;
      final repo = NativeTachiRepository(
        storageDirectory: directory,
        executor: (raw) async {
          final request = jsonDecode(raw) as Map;
          if (request['method'] == 'initialize') {
            initializations++;
            if (initializations == 1) throw MissingPluginException();
          }
          return jsonEncode({
            'ok': true,
            'result': request['method'] == 'sources' ? [] : {},
          });
        },
      );
      addTearDown(repo.dispose);
      await expectLater(repo.listSources(), _apiCode('RUNTIME_MISSING'));
      expect(await repo.listSources(), isEmpty);
      expect(initializations, 2);
    },
  );

  test(
    'a displayed preference position cannot be redirected by a changed list',
    () async {
      var preferenceReads = 0;
      final writes = <Map<String, dynamic>>[];
      final host = _Host((method, args) {
        if (method == 'preferences') {
          final values = [
            {
              'key': 'original_key',
              'title': 'Original',
              'type': 'String',
              'value': 'old',
            },
            {
              'key': 'other_key',
              'title': 'Other',
              'type': 'String',
              'value': 'keep',
            },
          ];
          return ++preferenceReads == 1 ? values : values.reversed.toList();
        }
        expect(method, 'setPreference');
        writes.add(args);
        return true;
      });
      final repo = repository(host);
      await repo.sourcePreferences(_source);
      try {
        await repo.setSourcePreference(_source, 0, 'edited original');
      } on ApiException {
        // Refusing an obsolete preference snapshot is also safe.
        expect(writes, isEmpty);
        return;
      }
      expect(writes, [
        {
          'sourceId': _sourceId,
          'key': 'original_key',
          'value': 'edited original',
        },
      ]);
    },
  );

  test(
    'malformed native response is rejected without inventing a result',
    () async {
      final repo = NativeTachiRepository(
        storageDirectory: directory,
        executor: (_) async => 'not JSON',
      );
      addTearDown(repo.dispose);
      await expectLater(repo.listSources(), _apiCode('INVALID_SOURCE_DATA'));
    },
  );

  test(
    'image execution preserves chapter identity and uses decoded engine bytes',
    () async {
      final bytes = Uint8List.fromList([137, 80, 78, 71, 13, 10, 26, 10, 1]);
      final host = _Host((method, args) {
        expect(method, 'image');
        expect(args['sourceId'], _sourceId);
        expect(args['chapterRef'], _chapter.ref);
        expect(args['chapterTitle'], _chapter.title);
        expect(args['index'], 2);
        expect(args['url'], 'https://source.example/page.png');
        return {
          'base64': base64Encode(bytes),
          'mimeType': 'application/octet-stream',
        };
      });
      final repo = repository(host);
      final result = await repo.fetchImage(
        _book,
        _chapter,
        2,
        'https://source.example/page.png',
      );
      expect(result.bytes, bytes);
      expect(result.mimeType, 'image/png');
    },
  );

  test(
    'native image errors do not fall back to downloading the raw URL',
    () async {
      var calls = 0;
      final repo = NativeTachiRepository(
        storageDirectory: directory,
        executor: (raw) async {
          final method = (jsonDecode(raw) as Map)['method'];
          if (method == 'initialize') {
            return jsonEncode({'ok': true, 'result': {}});
          }
          calls++;
          return jsonEncode({
            'ok': false,
            'error': {
              'code': 'source_requires_browser',
              'message': 'Source requires verification',
            },
          });
        },
      );
      addTearDown(repo.dispose);
      await expectLater(
        repo.fetchImage(_book, _chapter, 0, 'https://source.example/page.png'),
        _apiCode('source_requires_browser'),
      );
      expect(calls, 1);
      await expectLater(
        repo.fetchImage(_book, _chapter, -1, 'https://source.example/page.png'),
        throwsA(isA<ApiException>()),
      );
      expect(calls, 1);
    },
  );

  test('source browser resolves the title URL and binds the saved session to its source ID', () async {
    final cookies = [
      {
        'name': 'cf_clearance',
        'value': 'fixture',
        'domain': 'source.example',
        'path': '/',
        'secure': true,
      },
    ];
    Map<String, dynamic>? saved;
    final host = _Host((method, args) {
      if (method == 'sources') {
        return [
          {'id': _sourceId, 'name': _source.name, 'baseUrl': _source.baseUrl},
        ];
      }
      expect(method, 'browserSession');
      saved = args;
      return true;
    });
    final repo = NativeTachiRepository(
      storageDirectory: directory,
      executor: host.execute,
      browser: (url) async {
        expect(url, 'https://source.example/series/original');
        return {
          'url': url,
          'userAgent': 'Actual WebKit user agent',
          'cookies': cookies,
          'sourceId': 'incorrect-browser-field',
          'cancelled': false,
        };
      },
    );
    addTearDown(repo.dispose);
    await repo.openWebsite(_book);
    expect(saved, {
      'sourceId': _sourceId,
      'url': 'https://source.example/series/original',
      'userAgent': 'Actual WebKit user agent',
      'cookies': cookies,
    });
  });

  test(
    'cancelled or malformed browser sessions do not replace source cookies',
    () async {
      for (final session in [
        {'cancelled': true},
        {
          'url': 'https://other.example/series/original',
          'userAgent': 'WebKit',
          'cookies': [],
        },
        {
          'url': 'https://source.example/series/original',
          'userAgent': 'WebKit',
          'cookies': 'not a list',
        },
      ]) {
        final host = _Host((method, args) {
          expect(method, 'sources');
          return [
            {'id': _sourceId, 'name': _source.name, 'baseUrl': _source.baseUrl},
          ];
        });
        final repo = NativeTachiRepository(
          storageDirectory: directory,
          executor: host.execute,
          browser: (_) async => session,
        );
        addTearDown(repo.dispose);
        if (session['cancelled'] == true) {
          await repo.openWebsite(_book);
        } else {
          await expectLater(
            repo.openWebsite(_book),
            throwsA(isA<ApiException>()),
          );
        }
        expect(host.requests.map((r) => r['method']), [
          'initialize',
          'sources',
        ]);
      }
    },
  );

  test(
    'source browser refuses other origins before presenting any native view',
    () async {
      var browserCalls = 0;
      final host = _Host((method, args) {
        expect(method, 'sources');
        return [
          {'id': _sourceId, 'name': _source.name, 'baseUrl': _source.baseUrl},
        ];
      });
      final repo = NativeTachiRepository(
        storageDirectory: directory,
        executor: host.execute,
        browser: (_) async {
          browserCalls++;
          return {};
        },
      );
      addTearDown(repo.dispose);
      for (final invalid in [
        'https://other.example/title',
        'https://user:password@source.example/title',
        'file:///series',
      ]) {
        await expectLater(
          repo.openWebsite(
            CatalogueBook(
              ref: invalid,
              title: _book.title,
              sourceId: _sourceId,
              kind: ContentKind.manga,
              engine: SourceEngine.tachimanga,
            ),
          ),
          throwsA(isA<ApiException>()),
        );
      }
      expect(browserCalls, 0);
      expect(host.requests.any((r) => r['method'] == 'browserSession'), false);
    },
  );
}
