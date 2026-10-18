import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tachi_books/features/settings/settings_controller.dart';
import 'package:http/testing.dart';
import 'package:http/http.dart' as http;
import 'package:tachi_books/features/sources/data/native_tachi_repository.dart';
import 'package:tachi_books/features/sources/data/source_cover_cache.dart';
import 'package:tachi_books/features/sources/data/on_device_source_repository.dart';
import 'package:tachi_books/features/sources/data/source_repository.dart';
import 'package:tachi_books/features/sources/domain/catalogue.dart';
import 'package:tachi_books/features/sources/domain/native_source_engine.dart';

CatalogueBook _book(
  String url, {
  String sourceId = '9223372036854775806',
  String ref = '123',
}) => CatalogueBook(
  ref: ref, // Imported companion identity does not gate its saved cover.
  title: 'Title',
  sourceId: sourceId,
  coverUrl: url,
  kind: ContentKind.manga,
  engine: SourceEngine.tachimanga,
);

class _LegacyRuntime implements NativeSourceEngine {
  @override
  void dispose() {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _CoverRuntime extends _LegacyRuntime implements NativeCoverImageEngine {
  CatalogueBook? requested;

  @override
  Future<SourceImageData> fetchCover(CatalogueBook book) async {
    requested = book;
    return SourceImageData(
      bytes: Uint8List.fromList([1]),
      mimeType: 'image/png',
    );
  }
}

void main() {
  late Directory directory;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('tachi-cover-test-');
  });
  tearDown(() => directory.delete(recursive: true));

  NativeTachiRepository native(
    FutureOr<Object?> Function(String method, Map<String, dynamic> args)
    handler, {
    bool Function()? canCacheCover,
    int Function()? coverCacheEpoch,
    http.Client? client,
  }) {
    final repository = NativeTachiRepository(
      storageDirectory: directory,
      client:
          client ??
          MockClient((_) => throw StateError('No raw Dart cover HTTP')),
      canCacheCover: canCacheCover,
      coverCacheEpoch: coverCacheEpoch,
      executor: (raw) async {
        final request = jsonDecode(raw) as Map<String, dynamic>;
        final method = request['method'] as String;
        final result = method == 'initialize'
            ? <String, dynamic>{}
            : await handler(method, request['args'] as Map<String, dynamic>);
        return jsonEncode({'ok': true, 'result': result});
      },
    );
    addTearDown(repository.dispose);
    return repository;
  }

  test('invalidating a cover rejects old in-flight cache publication and starts a new request', () async {
    final started = Completer<void>(), release = Completer<void>();
    var calls = 0;
    final repository = native((_, _) async {
      final version = ++calls;
      if (version == 1) {
        started.complete();
        await release.future;
      }
      return {
        'base64': base64Encode([255, 216, 255, version]),
        'mimeType': 'image/jpeg',
      };
    });
    final book = _book('/refreshed.jpg');
    final old = repository.fetchCover(book);
    await started.future;
    await repository.invalidateCover(book);
    final fresh = repository.fetchCover(book);
    for (var i = 0; i < 20; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
      if (calls == 2) break;
    }
    release.complete();
    final images = await Future.wait([old, fresh]);
    expect(calls, 2);
    expect(images.last.bytes.last, 2);
    expect((await repository.fetchCover(book)).bytes.last, 2);
    expect(calls, 2);
  });

  test(
    'two restored books sharing a retired URL keep their own refreshed covers',
    () async {
      var coverCalls = 0;
      final repository = native((method, args) {
        if (method == 'detail') {
          return {
            'ref': args['ref'],
            'title': 'Fixture',
            'coverUrl': '${args['ref']}.jpg',
          };
        }
        expect(method, 'cover');
        coverCalls++;
        if (args['url'] == '/retired.jpg') {
          throw const ApiException('Expired', statusCode: 404);
        }
        return {
          'base64': base64Encode([
            255,
            216,
            255,
            args['url'] == '/first.jpg' ? 1 : 2,
          ]),
          'mimeType': 'image/jpeg',
        };
      });
      final first = _book('/retired.jpg', ref: '/first');
      final second = _book('/retired.jpg', ref: '/second');
      expect((await repository.fetchCover(first)).bytes.last, 1);
      expect((await repository.fetchCover(second)).bytes.last, 2);
      expect((await repository.fetchCover(first)).bytes.last, 1);
      expect(coverCalls, 4);
    },
  );

  test('cover disk cache survives runtime restart, distinguishes sources and invalidates one cover', () async {
    var calls = 0;
    Object image(String method, Map<String, dynamic> args) {
      expect(method, 'cover');
      calls++;
      return {
        'base64': base64Encode([255, 216, 255, 1]),
        'mimeType': 'image/jpeg',
      };
    }

    final first = native(image);
    final book = _book('https://cdn.example/same.jpg');
    await Future.wait([first.fetchCover(book), first.fetchCover(book)]);
    expect(calls, 1);
    first.dispose();
    final reopened = native(image);
    await reopened.fetchCover(book);
    expect(calls, 1); // No initialize/source/network call after reopening.
    await reopened.fetchCover(_book(book.coverUrl, sourceId: '123'));
    expect(calls, 2);
    await reopened.invalidateCover(book);
    await reopened.fetchCover(book);
    expect(calls, 3);
  });

  test(
    'covers started before an incognito transition cannot populate disk cache',
    () async {
      var private = false, epoch = 0, calls = 0;
      final gate = Completer<void>(), started = Completer<void>();
      final repository = native(
        (method, args) async {
          calls++;
          if (calls == 1) {
            started.complete();
            await gate.future;
          }
          return {
            'base64': base64Encode([255, 216, 255, 1]),
            'mimeType': 'image/jpeg',
          };
        },
        canCacheCover: () => !private,
        coverCacheEpoch: () => epoch,
      );
      final book = _book('/private.jpg');
      final pending = repository.fetchCover(book);
      await started.future;
      private = true;
      epoch++;
      private = false;
      epoch++;
      gate.complete();
      await pending;
      await repository.fetchCover(book);
      expect(calls, 2);
      await repository.fetchCover(book);
      expect(calls, 2);
    },
  );

  test('cover privacy epoch survives inactive provider listeners and settings rebuilds', () async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    final container = ProviderContainer(
      overrides: [preferencesProvider.overrideWithValue(preferences)],
    );
    addTearDown(container.dispose);
    final gate = Completer<void>(), started = Completer<void>();
    var calls = 0;
    final repository = native(
      (_, _) async {
        calls++;
        if (calls == 1) {
          started.complete();
          await gate.future;
        }
        return {
          'base64': base64Encode([255, 216, 255, 1]),
          'mimeType': 'image/jpeg',
        };
      },
      canCacheCover: () => !container.read(settingsProvider).incognitoMode,
      coverCacheEpoch: () =>
          container.read(settingsProvider.notifier).privacyGeneration,
    );
    final book = _book('/privacy-provider.jpg');
    final pending = repository.fetchCover(book);
    await started.future;
    final before = container.read(settingsProvider.notifier).privacyGeneration;
    await container.read(settingsProvider.notifier).update(incognitoMode: true);
    await container
        .read(settingsProvider.notifier)
        .update(incognitoMode: false);
    await container.read(settingsProvider.notifier).update(libraryColumns: 4);
    expect(
      container.read(settingsProvider.notifier).privacyGeneration,
      before + 2,
    );
    gate.complete();
    await pending;
    await repository.fetchCover(book);
    expect(calls, 2);
    await repository.fetchCover(book);
    expect(calls, 2);
  });

  test('an uninstalled source may load a public thumbnail but loaded-source failures never bypass its client', () async {
    var publicCalls = 0;
    final client = MockClient((request) async {
      publicCalls++;
      expect(request.headers, isEmpty);
      return http.Response.bytes([255, 216, 255, 1], 200);
    });
    final missing = native(
      (_, _) =>
          throw const ApiException('Missing', code: 'source_not_installed'),
      client: client,
    );
    expect(
      (await missing.fetchCover(_book('https://cdn.example/public.jpg')))
          .mimeType,
      'image/jpeg',
    );
    expect(publicCalls, 1);
    final blocked = native(
      (_, _) => throw const ApiException(
        'Challenge',
        code: 'source_requires_browser',
      ),
      client: client,
    );
    await expectLater(
      blocked.fetchCover(_book('https://cdn.example/blocked.jpg')),
      throwsA(isA<ApiException>()),
    );
    expect(publicCalls, 1);
  });

  test('cache expiry refetches and clearing preserves unrelated files and rejects old writes', () async {
    final cache = SourceCoverCache(Directory('${directory.path}/cache'));
    final key = 'a' * 64;
    await cache.write(key, {'base64': 'test'}, cache.generation);
    final file = File('${cache.directory.path}/$key.json');
    await file.setLastModified(
      DateTime.now().subtract(const Duration(days: 8)),
    );
    expect(await cache.read(key), isNull);
    final unrelated = File('${cache.directory.path}/chapter.json');
    await unrelated.writeAsString('offline chapter must survive');
    final previousGeneration = cache.generation;
    await cache.clear();
    await cache.write(key, {'base64': 'late'}, previousGeneration);
    expect(await file.exists(), isFalse);
    expect(await unrelated.readAsString(), 'offline chapter must survive');
  });

  test(
    'optional native cover capability preserves companion and old runtimes',
    () async {
      final book = _book('https://images.example/cover.jpg');
      final companion = SourceRepository(tachimangaUrl: '', vbookUrl: '');
      addTearDown(companion.dispose);
      expect(companion.usesNativeCoverLoader(book), isFalse);
      expect(() => companion.fetchCover(book), throwsUnsupportedError);
      final legacy = OnDeviceSourceRepository(
        tachimangaUrl: '',
        vbookUrl: '',
        runtimes: {SourceEngine.tachimanga: _LegacyRuntime()},
      );
      addTearDown(legacy.dispose);
      expect(legacy.usesNativeCoverLoader(book), isFalse);
      expect(() => legacy.fetchCover(book), throwsUnsupportedError);
      final runtime = _CoverRuntime();
      final repository = OnDeviceSourceRepository(
        tachimangaUrl: '',
        vbookUrl: '',
        runtimes: {SourceEngine.tachimanga: runtime},
      );
      addTearDown(repository.dispose);
      expect(repository.usesNativeCoverLoader(book), isTrue);
      expect((await repository.fetchCover(book)).bytes, [1]);
      expect(runtime.requested, same(book));
      expect(repository.usesNativeImageLoader(book), isFalse);
    },
  );

  test(
    'cover RPC keeps exact source ID, permits relative URLs and legacy refs',
    () async {
      final bytes = Uint8List.fromList([137, 80, 78, 71, 13, 10, 26, 10]);
      final requests = <Map<String, dynamic>>[];
      final repository = native((method, args) {
        expect(method, 'cover');
        requests.add(args);
        return {
          'base64': base64Encode(bytes),
          'mimeType': 'application/octet-stream',
        };
      });
      for (final url in [
        'https://cdn.example/cover.png',
        '/covers/a.png',
        '//cdn.example/a.png',
      ]) {
        final image = await repository.fetchCover(_book(url));
        expect(image.bytes, bytes);
        expect(image.mimeType, 'image/png');
        expect(requests.last, {'sourceId': '9223372036854775806', 'url': url});
      }
    },
  );

  test('invalid cover URLs and source IDs fail before JNI or HTTP', () async {
    final repository = native((_, _) => fail('Invalid cover reached host'));
    for (final url in [
      '',
      'file:///cover.jpg',
      'data:image/png;base64,AA==',
      'https://user:secret@cdn.example/a.jpg',
      '//user:secret@cdn.example/a.jpg',
      'https://cdn.example/a.jpg#fragment',
      'https://cdn.example/a\n.jpg',
      r'\cdn\a.jpg',
    ]) {
      await expectLater(
        repository.fetchCover(_book(url)),
        throwsA(isA<ApiException>()),
      );
    }
    await expectLater(
      repository.fetchCover(
        _book('/cover.jpg', sourceId: '18446744073709551616'),
      ),
      throwsA(isA<ApiException>()),
    );
  });

  test(
    'cover rejects empty, malformed, oversized and non-image native bodies',
    () async {
      for (final result in [
        {'base64': '', 'mimeType': 'image/png'},
        {'base64': '%%%broken%%%', 'mimeType': 'image/png'},
        {
          'base64': base64Encode(utf8.encode('<html>challenge</html>')),
          'mimeType': 'text/html',
        },
        {
          'base64': base64Encode(Uint8List(8 * 1024 * 1024 + 1)),
          'mimeType': 'image/png',
        },
      ]) {
        final repository = native((_, _) => result);
        await expectLater(
          repository.fetchCover(_book('/cover.png')),
          throwsA(isA<ApiException>()),
        );
      }
    },
  );

  test('reader pages start while slow covers remain pending and cover failures do not poison the queue', () async {
    final first = Completer<void>(), second = Completer<void>();
    final firstStarted = Completer<void>(), secondStarted = Completer<void>();
    final started = <String>[];
    final repository = native((method, args) async {
      final label = method == 'cover' ? args['url'] as String : method;
      started.add(label);
      if (label == '/first.jpg') {
        firstStarted.complete();
        await first.future;
        throw const ApiException('Retry cover');
      }
      if (label == '/second.jpg') {
        secondStarted.complete();
        await second.future;
      }
      return {
        'base64': base64Encode([255, 216, 255, 1]),
        'mimeType': 'image/jpeg',
      };
    });
    final failed = repository.fetchCover(_book('/first.jpg'));
    final assertion = expectLater(failed, throwsA(isA<ApiException>()));
    await firstStarted.future;
    final cover = repository.fetchCover(_book('/second.jpg'));
    await secondStarted.future;
    final page = repository.fetchImage(
      const CatalogueBook(
        ref: '/series/one',
        title: 'One',
        sourceId: '9223372036854775806',
        kind: ContentKind.manga,
        engine: SourceEngine.tachimanga,
      ),
      const CatalogueChapter(ref: '/chapter/one', title: 'One', index: 0),
      0,
      'https://cdn.example/page.jpg',
    );
    final laterCover = repository.fetchCover(_book('/third.jpg'));
    await page.timeout(const Duration(seconds: 1));
    expect(started, ['/first.jpg', '/second.jpg', 'image']);
    first.complete();
    await assertion;
    expect(started.take(3), ['/first.jpg', '/second.jpg', 'image']);
    second.complete();
    await cover;
    await page;
    await laterCover;
    expect(started, ['/first.jpg', '/second.jpg', 'image', '/third.jpg']);
  });
}
