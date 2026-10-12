import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data' show Endian;

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tachi_books/features/sources/data/native_vbook_package.dart';
import 'package:tachi_books/features/sources/data/native_vbook_repository.dart';
import 'package:tachi_books/features/sources/domain/catalogue.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('native-vbook-test-');
  });
  tearDown(() async {
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  test('install verifies original bytes and stable identity, restart loads scripts without HTTP', () async {
    final original = _package();
    final bytes = Uint8List.fromList(original);
    final expectedId =
        'vb-${sha256.convert(utf8.encode('Fixture Source\u0000https://source.test')).toString().substring(0, 24)}';
    var requests = 0;
    final repository = NativeVbookRepository(
      storageDirectory: directory,
      client: MockClient((request) async {
        requests++;
        return http.Response.bytes(bytes, 200);
      }),
      executor: _healthOnly,
    );
    await repository.installExtension('https://registry.test/source.zip');
    expect(bytes, original);
    expect(requests, 1);
    final sources = await repository.listSources();
    expect(sources.single.id, expectedId);
    expect(sources.single.engine, SourceEngine.vbook);
    expect((await repository.extensions()).single.installed, isTrue);
    final restarted = NativeVbookRepository(
      storageDirectory: directory,
      client: MockClient(
        (_) async => throw StateError('restart may not download'),
      ),
      executor: (method, args) async {
        if (method == 'health') return {'engine': 'vbook'};
        expect((args['scripts'] as Map)['detail.js'], contains('execute'));
        expect(args['script'], 'detail.js');
        return {
          'data': {
            'name': 'Stored story',
            'author': 'Author',
            'cover': '/cover.png',
          },
          'storage': <String, String>{},
        };
      },
    );
    final restoredSource = (await restarted.listSources()).single;
    expect(restoredSource.id, expectedId);
    final book = await restarted.detail(_book(restoredSource.id));
    expect(book.ref, 'https://source.test/story');
    expect(book.coverUrl, 'https://source.test/cover.png');
    expect(requests, 1);
  });

  test('malformed, unsafe, encrypted and incomplete packages retain prior installation', () async {
    final repository = NativeVbookRepository(
      storageDirectory: directory,
      executor: _healthOnly,
    );
    await repository.installBytes(_package());
    final index = File('${directory.path}/index.json');
    final before = await index.readAsBytes();
    for (final bad in [
      Uint8List.fromList([1, 2, 3]),
      _package(extra: {'../escape.js': 'bad'}),
      _package(extra: {'SRC/DETAIL.JS': 'bad'}),
      _package(encrypted: true),
      _package(missing: 'toc.js'),
    ]) {
      await expectLater(
        repository.installBytes(bad),
        throwsA(isA<ApiException>()),
      );
      expect(await index.readAsBytes(), before);
      expect((await repository.listSources()).single.name, 'Fixture Source');
    }
    expect(await Directory('${directory.path}/escape.js').exists(), isFalse);
  });

  test('corrupt persisted ZIP is rejected on restart and repaired by validated reinstall', () async {
    final repository = NativeVbookRepository(
      storageDirectory: directory,
      executor: _healthOnly,
    );
    final bytes = _package();
    await repository.installBytes(bytes);
    final package = NativeVbookPackage.parse(bytes);
    final stored = File(
      '${directory.path}/extensions/${package.id}/${package.hash}/package.zip',
    );
    await stored.writeAsBytes([0, 1, 2], flush: true);
    final restarted = NativeVbookRepository(
      storageDirectory: directory,
      executor: _healthOnly,
    );
    await expectLater(
      restarted.listSources(),
      throwsA(
        isA<ApiException>().having((e) => e.code, 'code', 'PACKAGE_CORRUPT'),
      ),
    );
    await restarted.installBytes(bytes);
    expect(await stored.readAsBytes(), bytes);
    expect((await restarted.listSources()).single.id, package.id);
  });

  test(
    'failed native registration cannot publish a fake installed extension',
    () async {
      final repository = NativeVbookRepository(
        storageDirectory: directory,
        executor: (_, _) async => throw MissingPluginException(),
      );
      await expectLater(
        repository.installBytes(_package()),
        throwsA(
          isA<ApiException>().having(
            (e) => e.code,
            'code',
            'ENGINE_UNAVAILABLE',
          ),
        ),
      );
      expect(await File('${directory.path}/index.json').exists(), isFalse);
    },
  );

  test(
    'atomic upgrade keeps stable source ID, prior bytes and source storage',
    () async {
      final repository = NativeVbookRepository(
        storageDirectory: directory,
        executor: (method, args) async {
          if (method == 'health') return {'engine': 'vbook'};
          return {
            'data': {'name': 'Versioned'},
            'storage': {'keep': 'saved'},
          };
        },
      );
      final first = _package(version: 1), second = _package(version: 2);
      final old = NativeVbookPackage.parse(first),
          next = NativeVbookPackage.parse(second);
      await repository.installBytes(
        first,
        origin: 'https://registry.test/v1.zip',
      );
      await repository.detail(_book(old.id));
      await repository.installBytes(
        second,
        origin: 'https://registry.test/v2.zip',
      );
      expect(next.id, old.id);
      expect(next.hash, isNot(old.hash));
      expect((await repository.extensions()).single.version, '2');
      expect(
        await File(
          '${directory.path}/extensions/${old.id}/${old.hash}/package.zip',
        ).readAsBytes(),
        first,
      );
      expect(
        await File(
          '${directory.path}/extensions/${next.id}/${next.hash}/package.zip',
        ).readAsBytes(),
        second,
      );
      expect(
        jsonDecode(
          await File('${directory.path}/extensions/${old.id}/storage.json')
              .readAsString(),
        ),
        {'keep': 'saved'},
      );
      final files = await directory.list(recursive: true).toList();
      expect(files.where((f) => f.path.contains('.pending-')), isEmpty);
    },
  );

  test('invalid existing index is kept byte-for-byte when publication cannot proceed', () async {
    final repository = NativeVbookRepository(
      storageDirectory: directory,
      executor: _healthOnly,
    );
    await repository.installBytes(_package());
    final index = File('${directory.path}/index.json');
    final invalid = utf8.encode('{invalid JSON retained');
    await index.writeAsBytes(invalid, flush: true);
    await expectLater(
      repository.installBytes(_package(version: 2)),
      throwsA(
        isA<ApiException>().having(
          (e) => e.code,
          'code',
          'INVALID_RUNTIME_DATA',
        ),
      ),
    );
    expect(await index.readAsBytes(), invalid);
  });

  test('concurrent repository handles publish both installations without losing index entries', () async {
    final first = NativeVbookRepository(
      storageDirectory: directory,
      executor: _healthOnly,
    );
    final second = NativeVbookRepository(
      storageDirectory: directory,
      executor: _healthOnly,
    );
    expect(await first.listSources(), isEmpty);
    expect(await second.listSources(), isEmpty);
    await Future.wait([
      first.installBytes(_package()),
      second.installBytes(_package(name: 'Second Source')),
    ]);
    final restarted = NativeVbookRepository(
      storageDirectory: directory,
      executor: _healthOnly,
    );
    expect((await restarted.listSources()).map((s) => s.name).toSet(), {
      'Fixture Source',
      'Second Source',
    });
    for (final handle in [first, second]) {
      expect((await handle.listSources()).map((s) => s.name).toSet(), {
        'Fixture Source',
        'Second Source',
      });
      expect((await handle.extensions()).map((e) => e.name).toSet(), {
        'Fixture Source',
        'Second Source',
      });
    }
  });

  test('CRC damage, oversized entries and too many ZIP entries are rejected before native calls', () async {
    var calls = 0;
    final repository = NativeVbookRepository(
      storageDirectory: directory,
      executor: (method, args) async {
        calls++;
        return {'engine': 'vbook'};
      },
    );
    final crc = _package();
    for (var i = 0; i < crc.length - 46; i++) {
      if (ByteData.sublistView(crc).getUint32(i, Endian.little) == 0x02014b50) {
        crc[i + 16] ^= 0xff;
        break;
      }
    }
    final oversize = _package();
    for (var i = 0; i < oversize.length - 46; i++) {
      if (ByteData.sublistView(oversize).getUint32(i, Endian.little) ==
          0x02014b50) {
        ByteData.sublistView(oversize)
            .setUint32(i + 24, 11 * 1024 * 1024, Endian.little);
        break;
      }
    }
    for (final bytes in [
      crc,
      oversize,
      _package(extra: {for (var i = 0; i < 513; i++) 'extra/$i.txt': 'small'}),
    ]) {
      await expectLater(
        repository.installBytes(bytes),
        throwsA(
          isA<ApiException>().having((e) => e.code, 'code', 'INVALID_PACKAGE'),
        ),
      );
    }
    expect(calls, 0);
    expect(await File('${directory.path}/index.json').exists(), isFalse);
  });

  test('package HTTP redirects are validated and oversized declarations never publish', () async {
    final repository = NativeVbookRepository(
      storageDirectory: directory,
      executor: _healthOnly,
      client: MockClient.streaming(
        (request, _) async => request.url.path.endsWith('redirect.zip')
            ? http.StreamedResponse(
                const Stream.empty(),
                302,
                headers: {
                  'location': 'https://user:password@registry.test/source.zip',
                },
              )
            : http.StreamedResponse(
                const Stream.empty(),
                200,
                contentLength: NativeVbookPackage.maxArchiveBytes + 1,
                headers: {
                  'content-length': '${NativeVbookPackage.maxArchiveBytes + 1}',
                },
              ),
      ),
    );
    await expectLater(
      repository.installExtension('https://registry.test/redirect.zip'),
      throwsA(isA<ApiException>().having((e) => e.code, 'code', 'INVALID_URL')),
    );
    await expectLater(
      repository.installExtension('https://registry.test/oversized.zip'),
      throwsA(
        isA<ApiException>().having((e) => e.code, 'code', 'DOWNLOAD_FAILED'),
      ),
    );
    expect(await File('${directory.path}/index.json').exists(), isFalse);
  });

  test('search/detail/page/TOC/chapter map exact URLs, preserve ordering and sanitize novel', () async {
    final calls = <String>[];
    final repository = NativeVbookRepository(
      storageDirectory: directory,
      executor: (method, args) async {
        if (method == 'health') return {'engine': 'vbook'};
        final script = args['script'] as String,
            arguments = args['args'] as List;
        calls.add('$script:${arguments.join('|')}');
        final data = switch (script) {
          'search.js' => [
            {'name': 'Result', 'link': '/story', 'cover': '/cover.png'},
          ],
          'detail.js' => {
            'name': 'Detailed',
            'author': 'Writer',
            'description': 'Intro',
          },
          'page.js' => ['/toc-1', '/toc-2'],
          'toc.js' when arguments.first == 'https://source.test/toc-1' => [
            {'name': 'First', 'url': '/chapter-1'},
            {'name': 'Second', 'url': '/chapter-2'},
          ],
          'toc.js' => [
            {'name': 'Second', 'url': '/chapter-2'},
            {'name': 'Third', 'url': '/chapter-3'},
          ],
          'chap.js' => '<script>bad()</script><p onclick="bad()">Safe <img src="../image.png"></p><a href="javascript:bad()">link</a>',
          _ => throw StateError(script),
        };
        return {'data': data, 'storage': <String, String>{}};
      },
    );
    await repository.installBytes(_package(withPages: true));
    final source = (await repository.listSources()).single;
    final found = (await repository.search(source, 'query', page: 2)).single;
    expect(found.ref, 'https://source.test/story');
    final detailed = await repository.detail(found);
    expect(detailed.title, 'Detailed');
    expect(detailed.ref, found.ref);
    final toc = await repository.chapters(detailed);
    expect(toc.map((c) => c.index), [0, 1, 2]);
    expect(toc.map((c) => c.ref), [
      'https://source.test/chapter-1',
      'https://source.test/chapter-2',
      'https://source.test/chapter-3',
    ]);
    final content = await repository.chapter(detailed, toc.last);
    expect(content.html, contains('https://source.test/image.png'));
    expect(content.html, contains('Safe'));
    expect(content.html, isNot(contains('script')));
    expect(content.html, isNot(contains('onclick')));
    expect(content.html, isNot(contains('javascript:')));
    expect(calls, contains('search.js:query|2'));
    expect(calls.last, 'chap.js:https://source.test/chapter-3');
  });

  test('comic image request headers and URL identity survive native response mapping', () async {
    final repository = NativeVbookRepository(
      storageDirectory: directory,
      executor: (method, args) async {
        if (method == 'health') return {'engine': 'vbook'};
        return {
          'data': [
            {
              'url': '/one.png',
              'headers': {'Referer': 'https://source.test/story'},
            },
            'two.png',
          ],
          'storage': <String, String>{},
        };
      },
    );
    await repository.installBytes(_package(comic: true));
    final source = (await repository.listSources()).single;
    final content = await repository.chapter(
      _book(source.id, kind: ContentKind.manga),
      const CatalogueChapter(
        ref: 'https://source.test/chapter/1',
        title: 'One',
        index: 0,
      ),
    );
    expect(content.kind, ContentKind.manga);
    expect(content.images, [
      'https://source.test/one.png',
      'https://source.test/chapter/two.png',
    ]);
    expect(content.headersFor(content.images.first), {
      'Referer': 'https://source.test/story',
    });
  });

  test(
    'per-source execution is serialized and localStorage survives restart',
    () async {
      var active = 0, maxActive = 0;
      Future<Map<String, dynamic>> executor(
        String method,
        Map<String, dynamic> args,
      ) async {
        if (method == 'health') return {'engine': 'vbook'};
        active++;
        if (active > maxActive) maxActive = active;
        final storage = Map<String, dynamic>.from(args['storage'] as Map);
        final count = int.parse(storage['counter'] as String? ?? '0') + 1;
        await Future<void>.delayed(const Duration(milliseconds: 15));
        active--;
        return {
          'data': {'name': 'Count $count'},
          'storage': {'counter': '$count'},
        };
      }

      final repository = NativeVbookRepository(
        storageDirectory: directory,
        executor: executor,
      );
      await repository.installBytes(_package());
      final book = _book((await repository.listSources()).single.id);
      final results = await Future.wait([
        repository.detail(book),
        repository.detail(book),
      ]);
      expect(results.map((b) => b.title), ['Count 1', 'Count 2']);
      expect(maxActive, 1);
      final restarted = NativeVbookRepository(
        storageDirectory: directory,
        executor: executor,
      );
      expect((await restarted.detail(book)).title, 'Count 3');
    },
  );

  test('an active script keeps its package snapshot and queued work rejects a changed content kind', () async {
    final started = Completer<void>(), release = Completer<void>();
    var calls = 0;
    final reader = NativeVbookRepository(
      storageDirectory: directory,
      executor: (method, args) async {
        if (method == 'health') return {'engine': 'vbook'};
        calls++;
        if (calls == 1) {
          started.complete();
          await release.future;
        }
        return {
          'data': '<p>Original novel chapter</p>',
          'storage': <String, String>{},
        };
      },
    );
    await reader.installBytes(_package());
    final book = _book((await reader.listSources()).single.id);
    const chapter = CatalogueChapter(
      ref: 'https://source.test/chapter/1',
      title: 'One',
      index: 0,
    );
    final active = reader.chapter(book, chapter);
    await started.future;
    final queued = reader.chapter(book, chapter);
    final queuedFailure = expectLater(
      queued,
      throwsA(
        isA<ApiException>().having(
          (error) => error.code,
          'code',
          'SOURCE_KIND_CHANGED',
        ),
      ),
    );
    await reader.installBytes(_package(version: 2, comic: true));
    release.complete();
    final original = await active;
    expect(original.kind, ContentKind.novel);
    expect(original.html, contains('Original novel chapter'));
    await queuedFailure;
    expect(
      calls,
      1,
      reason:
          'A new comic script cannot execute against the open novel identity.',
    );
    expect((await reader.listSources()).single.kind, ContentKind.manga);
  });

  test('a queued source request reloads an installation published by another handle', () async {
    final started = Completer<void>(), release = Completer<void>();
    final versions = <int>[];
    final reader = NativeVbookRepository(
      storageDirectory: directory,
      executor: (method, args) async {
        if (method == 'health') return {'engine': 'vbook'};
        final metadata = (args['manifest'] as Map)['metadata'] as Map;
        final version = metadata['version'] as int;
        versions.add(version);
        if (versions.length == 1) {
          started.complete();
          await release.future;
        }
        return {
          'data': {'name': 'Version $version'},
          'storage': <String, String>{},
        };
      },
    );
    await reader.installBytes(_package());
    final book = _book((await reader.listSources()).single.id);
    final active = reader.detail(book);
    await started.future;
    final queued = reader.detail(book);
    final writer = NativeVbookRepository(
      storageDirectory: directory,
      executor: _healthOnly,
    );
    await writer.installBytes(_package(version: 2));
    release.complete();
    expect((await active).title, 'Version 1');
    expect((await queued).title, 'Version 2');
    expect(versions, [1, 2]);
  });

  test('native MethodChannel returns structured payload and platform errors remain errors', () async {
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(NativeVbookRepository.channel, (call) async {
          calls.add(call);
          if (call.method == 'health') {
            return {'engine': 'vbook', 'runtime': 'fixture'};
          }
          throw PlatformException(
            code: 'SOURCE_ERROR',
            message: 'Source failed',
          );
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(NativeVbookRepository.channel, null),
    );
    final repository = NativeVbookRepository(storageDirectory: directory);
    await repository.installBytes(_package());
    final book = _book((await repository.listSources()).single.id);
    await expectLater(
      repository.detail(book),
      throwsA(
        isA<ApiException>().having((e) => e.code, 'code', 'SOURCE_ERROR'),
      ),
    );
    final execute = calls.last;
    expect(execute.method, 'execute');
    expect((execute.arguments as Map)['script'], 'detail.js');
    expect((execute.arguments as Map)['args'], ['https://source.test/story']);
    expect((execute.arguments as Map)['scripts'], contains('detail.js'));
    expect(
      await File('${directory.path}/extensions/${book.sourceId}/storage.json')
          .exists(),
      isFalse,
    );
  });
}

Future<Map<String, dynamic>> _healthOnly(
  String method,
  Map<String, dynamic> _,
) async {
  if (method != 'health') throw StateError('Unexpected execution');
  return {'engine': 'vbook', 'runtime': 'fixture'};
}

CatalogueBook _book(String sourceId, {ContentKind kind = ContentKind.novel}) =>
    CatalogueBook(
      ref: 'https://source.test/story',
      title: 'Story',
      sourceId: sourceId,
      kind: kind,
      engine: SourceEngine.vbook,
    );

Uint8List _package({
  bool encrypted = false,
  bool comic = false,
  bool withPages = false,
  int version = 1,
  String name = 'Fixture Source',
  String? missing,
  Map<String, String> extra = const {},
}) {
  final manifest = {
    'metadata': {
      'name': name,
      'source': 'https://source.test',
      'locale': 'vi',
      'type': comic ? 'comic' : 'novel',
      'encrypt': encrypted,
      'version': version,
    },
    'script': {
      'search': 'search.js',
      'detail': 'detail.js',
      'toc': 'toc.js',
      'chap': 'chap.js',
      if (withPages) 'page': 'page.js',
    },
  };
  final files = {
    'plugin.json': jsonEncode(manifest),
    for (final name in [
      'search.js',
      'detail.js',
      'toc.js',
      'chap.js',
      if (withPages) 'page.js',
    ])
      if (name != missing)
        'src/$name': 'function execute() { return Response.success([]); }',
    ...extra,
  };
  final archive = Archive();
  for (final entry in files.entries) {
    archive.add(ArchiveFile.bytes(entry.key, utf8.encode(entry.value)));
  }
  return Uint8List.fromList(ZipEncoder().encode(archive));
}
