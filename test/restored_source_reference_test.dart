import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tachi_books/features/sources/data/source_repository.dart';
import 'package:tachi_books/features/sources/domain/catalogue.dart';

const restored = CatalogueBook(
  ref: '/title/original',
  title: 'Same title',
  sourceId: '9007199254740995',
  kind: ContentKind.manga,
  engine: SourceEngine.tachimanga,
);
http.Response json(Object value) => http.Response(
  jsonEncode(value),
  200,
  headers: {'content-type': 'application/json'},
);
SourceRepository repo(Future<http.Response> Function(http.Request) handler) =>
    SourceRepository(
      tachimangaUrl: 'http://localhost:4567/prefix',
      vbookUrl: '',
      client: MockClient(handler),
    );

void main() {
  test('backup URL resolves exact source and maps original chapter URL to runtime index', () async {
    var resolutions = 0;
    final repository = repo((request) async {
      if (request.url.path.endsWith('/api/graphql')) {
        resolutions++;
        final condition =
            (jsonDecode(request.body) as Map)['variables']['condition'];
        expect(condition, {'sourceId': restored.sourceId, 'url': restored.ref});
        return json({
          'data': {
            'mangas': {
              'nodes': [
                {'id': 42, 'sourceId': restored.sourceId, 'url': restored.ref},
              ],
            },
          },
        });
      }
      if (request.url.path.endsWith('/manga/42')) {
        return json({
          'id': 42,
          'sourceId': restored.sourceId,
          'url': restored.ref,
        });
      }
      if (request.url.path.endsWith('/manga/42/chapters')) {
        return json([
          {'url': '/chapters/original-2', 'name': 'Chapter two', 'index': 2},
          {'url': '/chapters/original-1', 'name': 'Chapter one', 'index': 1},
        ]);
      }
      expect(request.url.path, '/prefix/api/v1/manga/42/chapter/1');
      return json({
        'pageCount': 2,
        'url': '/chapters/original-1',
        'index': 1,
        'name': 'Chapter one',
      });
    });
    final chapters = await repository.chapters(restored);
    expect(chapters.map((chapter) => chapter.ref), [
      '/chapters/original-1',
      '/chapters/original-2',
    ]);
    final content = await repository.chapter(
      restored,
      const CatalogueChapter(
        ref: '/chapters/original-1',
        title: 'Chapter one',
        index: 0,
      ),
    );
    expect(
      content.images.first,
      'http://localhost:4567/prefix/api/v1/manga/42/chapter/1/page/0?updateProgress=false',
    );
    expect(content.images.length, 2);
    expect(resolutions, 1);
  });

  test('missing restored entry searches original source and rejects same title at another URL', () async {
    var searches = 0;
    final repository = repo((request) async {
      if (request.url.path.endsWith('/api/graphql')) {
        return json({
          'data': {
            'mangas': {'nodes': []},
          },
        });
      }
      expect(
        request.url.path,
        '/prefix/api/v1/source/${restored.sourceId}/quick-search',
      );
      searches++;
      return json({
        'mangaList': [
          {
            'id': 99,
            'title': restored.title,
            'sourceId': restored.sourceId,
            'url': '/different-title',
          },
        ],
      });
    });
    await expectLater(
      repository.chapters(restored),
      throwsA(
        isA<ApiException>().having(
          (e) => e.code,
          'unresolved',
          'RESTORED_TITLE_UNRESOLVED',
        ),
      ),
    );
    expect(searches, 1);
  });

  test('search resolves only exact original URL and missing chapter is never replaced by its list position', () async {
    final repository = repo((request) async {
      if (request.url.path.endsWith('/api/graphql')) {
        return json({
          'data': {
            'mangas': {'nodes': []},
          },
        });
      }
      if (request.url.path.endsWith('/quick-search')) {
        return json({
          'mangaList': [
            {'id': 42, 'sourceId': restored.sourceId, 'url': restored.ref},
          ],
        });
      }
      if (request.url.path.endsWith('/manga/42')) {
        return json({
          'id': 42,
          'sourceId': restored.sourceId,
          'url': restored.ref,
        });
      }
      expect(request.url.path, '/prefix/api/v1/manga/42/chapters');
      return json([
        {'url': '/chapter/different', 'name': 'Same chapter name', 'index': 0},
      ]);
    });
    await expectLater(
      repository.chapter(
        restored,
        const CatalogueChapter(
          ref: '/chapter/missing',
          title: 'Same chapter name',
          index: 0,
        ),
      ),
      throwsA(isA<ApiException>()),
    );
  });
}
