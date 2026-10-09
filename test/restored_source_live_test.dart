import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:tachi_books/features/sources/data/source_repository.dart';
import 'package:tachi_books/features/sources/domain/catalogue.dart';

void main() {
  test(
    'restored URL references execute original Komga source and return actual PNG pages',
    () async {
      final client = http.Client();
      final repo = SourceRepository(
        tachimangaUrl: 'http://127.0.0.1:4567',
        vbookUrl: '',
        client: client,
      );
      addTearDown(client.close);
      final response = await client.post(
        Uri.parse('http://127.0.0.1:4567/api/graphql'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'query': r'query Fixture($condition: MangaConditionInput!) { mangas(condition: $condition, first: 2) { nodes { id sourceId url title } } }',
          'variables': {
            'condition': {
              'sourceId': '4508733312114627536',
              'title': 'Tachi Books Runtime Fixture',
            },
          },
        }),
      );
      final node =
          (decodeCatalogueJson(
                response.body,
              ) as Map)['data']['mangas']['nodes'].single
              as Map;
      for (final reference in [node['url'] as String, '${node['id']}']) {
        final book = CatalogueBook(
          ref: reference,
          title: node['title'] as String,
          sourceId: node['sourceId'] as String,
          kind: ContentKind.manga,
          engine: SourceEngine.tachimanga,
        );
        final detail = await repo.detail(book);
        expect(
          detail.ref,
          book.ref,
          reason: 'Keep the restored URL as the local identity.',
        );
        final chapters = await repo.chapters(book);
        expect(chapters.length, 1);
        expect(chapters.single.ref, isNot('0'));
        final content = await repo.chapter(book, chapters.single);
        expect(content.images.length, 2);
        for (final page in content.images) {
          final image = await client.get(Uri.parse(page));
          expect(image.statusCode, 200);
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
      }
    },
    skip: Platform.environment['TACHI_RESTORED_SOURCE_LIVE'] != '1'
        ? 'Opt-in real Suwayomi + original Komga APK and authored fixture.'
        : false,
  );
}
