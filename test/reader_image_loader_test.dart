import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tachi_books/features/library/domain/library_book.dart';
import 'package:tachi_books/features/reader/presentation/reader_image_loader.dart';

void main() {
  test(
    'ordinary images retain per-page headers and stream the original bytes',
    () async {
      final content = ReaderContent(
        kind: 'manga',
        images: ['https://fixture.invalid/page.png'],
        headers: {'Referer': 'https://fixture.invalid/chapter'},
        imageHeaders: {
          'https://fixture.invalid/page.png': {'Token': 'fixture-action'},
        },
      );
      final client = MockClient((request) async {
        expect(request.headers['Referer'], 'https://fixture.invalid/chapter');
        expect(request.headers['Token'], 'fixture-action');
        return http.Response.bytes(
          [1, 2, 3],
          200,
          headers: {'content-type': 'image/png'},
        );
      });
      addTearDown(client.close);
      final result = await loadOrdinaryReaderImage(content, 0, client: client);
      expect(result.bytes, [1, 2, 3]);
      expect(result.mimeType, 'image/png');
    },
  );

  test('native locators and invalid URLs never reach ordinary HTTP', () async {
    final client = MockClient((_) async => fail('Must not send this URL'));
    addTearDown(client.close);
    for (final url in [
      'https://page.tachibooks.invalid/fixture',
      'file:///input',
      'https://user:pass@fixture.invalid/a',
      'relative',
    ]) {
      await expectLater(
        loadOrdinaryReaderImage(
          ReaderContent(kind: 'manga', images: [url]),
          0,
          client: client,
        ),
        throwsA(anything),
      );
    }
  });

  test(
    'ordinary image HTTP errors and undeclared oversized streams are rejected',
    () async {
      final content = ReaderContent(
        kind: 'manga',
        images: ['https://fixture.invalid/page.png'],
      );
      final errorClient = MockClient((_) async => http.Response('', 503));
      await expectLater(
        loadOrdinaryReaderImage(content, 0, client: errorClient),
        throwsA(anything),
      );
      errorClient.close();
      final oversized = MockClient.streaming(
        (_, _) async => http.StreamedResponse(
          Stream.fromIterable(List.filled(9, List.filled(1024 * 1024, 0))),
          200,
        ),
      );
      await expectLater(
        loadOrdinaryReaderImage(content, 0, client: oversized),
        throwsFormatException,
      );
      oversized.close();
      final inline = ReaderContent(
        kind: 'manga',
        images: [
          'data:image/png;base64,${base64Encode([1, 2, 3])}',
        ],
      );
      expect((await loadOrdinaryReaderImage(inline, 0)).bytes, [1, 2, 3]);
    },
  );
}
