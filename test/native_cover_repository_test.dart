import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:tachi_books/features/sources/data/native_tachi_repository.dart';
import 'package:tachi_books/features/sources/data/on_device_source_repository.dart';
import 'package:tachi_books/features/sources/data/source_repository.dart';
import 'package:tachi_books/features/sources/domain/catalogue.dart';
import 'package:tachi_books/features/sources/domain/native_source_engine.dart';

CatalogueBook _book(String url, {String sourceId = '9223372036854775806'}) =>
    CatalogueBook(
      ref: '123', // Imported companion identity does not gate its saved cover.
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
    handler,
  ) {
    final repository = NativeTachiRepository(
      storageDirectory: directory,
      client: MockClient((_) => throw StateError('No raw Dart cover HTTP')),
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

  test(
    'a failed cover does not poison queued cover or chapter image requests',
    () async {
      final first = Completer<void>();
      final firstStarted = Completer<void>();
      final started = <String>[];
      var covers = 0;
      final repository = native((method, args) async {
        started.add(method);
        if (method == 'cover' && covers++ == 0) {
          firstStarted.complete();
          await first.future;
          throw const ApiException('Retry cover');
        }
        return {
          'base64': base64Encode([255, 216, 255, 1]),
          'mimeType': 'image/jpeg',
        };
      });
      final failed = repository.fetchCover(_book('/first.jpg'));
      final assertion = expectLater(failed, throwsA(isA<ApiException>()));
      final cover = repository.fetchCover(_book('/second.jpg'));
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
      await firstStarted.future;
      expect(started, ['cover']);
      first.complete();
      await assertion;
      expect((await cover).mimeType, 'image/jpeg');
      expect((await page).mimeType, 'image/jpeg');
      expect(started, ['cover', 'cover', 'image']);
    },
  );
}
