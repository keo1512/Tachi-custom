import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tachi_books/features/sources/data/source_repository.dart';
import 'package:tachi_books/features/sources/domain/catalogue.dart';

const _book = CatalogueBook(
  ref: '42',
  title: 'Fixture manga',
  sourceId: '9007199254740995',
  kind: ContentKind.manga,
  engine: SourceEngine.tachimanga,
);
const _legacyChapter = CatalogueChapter(
  ref: '7',
  title: 'Original chapter',
  index: 7,
);
const _urlChapter = CatalogueChapter(
  ref: '/chapter/original',
  title: 'Original chapter',
  index: 7,
);
Map<String, dynamic> _chapter({
  int index = 7,
  String url = '/chapter/original',
  String title = 'Original chapter',
}) => {'index': index, 'url': url, 'name': title, 'pageCount': 2};
http.Response _json(Object value) => http.Response(
  jsonEncode(value),
  200,
  headers: {'content-type': 'application/json'},
);

class _Fixture {
  _Fixture() {
    repository = SourceRepository(
      tachimangaUrl: 'http://localhost:4567/prefix',
      vbookUrl: '',
      client: MockClient((request) async {
        requests.add(request.url.path);
        if (request.url.path.endsWith('/manga/42')) return _json(manga);
        if (request.url.path.endsWith('/chapters')) return _json(chapters);
        if (request.url.path.contains('/chapter/')) {
          return _json(info ?? chapters.single);
        }
        throw StateError('Unexpected request ${request.url}');
      }),
    );
  }
  late final SourceRepository repository;
  final requests = <String>[];
  Map<String, dynamic> manga = {
    'id': 42,
    'sourceId': _book.sourceId,
    'url': '/book/original',
  };
  List<Map<String, dynamic>> chapters = [_chapter()];
  Map<String, dynamic>? info;
  bool get requestedChapter =>
      requests.any((path) => path.contains('/chapter/'));
}

Matcher _identityError([String code = 'CHAPTER_IDENTITY_CHANGED']) => throwsA(
  isA<ApiException>().having((error) => error.code, 'identity code', code),
);

void main() {
  test('Suwayomi newest-first TOC becomes chronological next-chapter order with stable URLs', () async {
    final fixture = _Fixture()
      ..chapters = [
        _chapter(index: 3, url: '/chapter/third', title: 'Third'),
        _chapter(index: 2, url: '/chapter/second', title: 'Second'),
        _chapter(index: 1, url: '/chapter/first', title: 'First'),
      ];
    final chapters = await fixture.repository.chapters(_book);
    expect(chapters.map((chapter) => chapter.ref), [
      '/chapter/first',
      '/chapter/second',
      '/chapter/third',
    ]);
    expect(chapters.map((chapter) => chapter.index), [1, 2, 3]);
    fixture.info = _chapter(index: 2, url: '/chapter/second', title: 'Second');
    final next = await fixture.repository.chapter(_book, chapters[1]);
    expect(next.images.first, contains('/chapter/2/page/0'));
  });

  test('vBook chapter order remains the order explicitly returned by the extension', () async {
    final repository = SourceRepository(
      tachimangaUrl: '',
      vbookUrl: 'http://localhost:4570',
      client: MockClient((request) async {
        expect(request.url.path, '/v1/sources/fixture/chapters');
        return _json([
          {'ref': '/chapter/z', 'title': 'First in extension', 'index': 9},
          {'ref': '/chapter/a', 'title': 'Next in extension', 'index': 1},
        ]);
      }),
    );
    final chapters = await repository.chapters(
      const CatalogueBook(
        ref: '/book',
        title: 'Novel',
        sourceId: 'fixture',
        kind: ContentKind.novel,
        engine: SourceEngine.vbook,
      ),
    );
    expect(chapters.map((chapter) => chapter.ref), [
      '/chapter/z',
      '/chapter/a',
    ]);
    expect(chapters.map((chapter) => chapter.index), [9, 1]);
  });

  test('new numeric-ref titles retain chapter URLs when remote order and title change', () async {
    final fixture = _Fixture();
    final original = (await fixture.repository.chapters(_book)).single;
    expect(original.ref, '/chapter/original');
    expect(original.index, 7);
    fixture.chapters = [_chapter(index: 2, title: 'Renamed chapter')];
    final current = (await fixture.repository.chapters(_book)).single;
    expect(current.ref, original.ref);
    expect(current.index, 2);
    final content = await fixture.repository.chapter(_book, original);
    expect(
      content.images.first,
      'http://localhost:4567/prefix/api/v1/manga/42/chapter/2/page/0?updateProgress=false',
    );
  });

  test(
    'a source change is rejected before fetching the chapter list',
    () async {
      final fixture = _Fixture()..manga['sourceId'] = '9007199254740996';
      await expectLater(
        fixture.repository.chapter(_book, _urlChapter),
        _identityError('MANGA_IDENTITY_CHANGED'),
      );
      expect(fixture.requests, ['/prefix/api/v1/manga/42']);
    },
  );

  test('unchanged legacy title and ordinal still execute without changing local refs', () async {
    final fixture = _Fixture();
    final content = await fixture.repository.chapter(_book, _legacyChapter);
    expect(content.images.length, 2);
    expect(content.images.first, contains('/chapter/7/page/0'));
    expect(_legacyChapter.ref, '7');
  });

  test(
    'legacy ordinals never follow an exact title that moved to another index',
    () async {
      final fixture = _Fixture()
        ..chapters = [
          _chapter(index: 7, url: '/chapter/other', title: 'Different chapter'),
          _chapter(index: 8),
        ];
      await expectLater(
        fixture.repository.chapter(_book, _legacyChapter),
        _identityError(),
      );
      expect(fixture.requestedChapter, isFalse);
    },
  );

  test(
    'legacy repeated chapter titles are ambiguous even at a matching ordinal',
    () async {
      final fixture = _Fixture()
        ..chapters = [
          _chapter(),
          _chapter(index: 8, url: '/chapter/duplicate-title'),
        ];
      await expectLater(
        fixture.repository.chapter(_book, _legacyChapter),
        _identityError(),
      );
      expect(fixture.requestedChapter, isFalse);
    },
  );

  test('a legacy stored index differing from its ref is rejected', () async {
    final fixture = _Fixture();
    await expectLater(
      fixture.repository.chapter(
        _book,
        const CatalogueChapter(ref: '7', title: 'Original chapter', index: 8),
      ),
      _identityError(),
    );
    expect(fixture.requestedChapter, isFalse);
  });

  test(
    'duplicate URL matches are never selected by their list position',
    () async {
      final fixture = _Fixture()..chapters = [_chapter(), _chapter(index: 8)];
      await expectLater(
        fixture.repository.chapter(_book, _urlChapter),
        _identityError(),
      );
      expect(fixture.requestedChapter, isFalse);
    },
  );

  test('duplicate runtime ordinals cannot produce page URLs', () async {
    final fixture = _Fixture()
      ..chapters = [
        _chapter(),
        _chapter(url: '/chapter/other', title: 'Different'),
      ];
    await expectLater(
      fixture.repository.chapter(_book, _urlChapter),
      _identityError(),
    );
    expect(fixture.requestedChapter, isFalse);
  });

  test(
    'a chapter that changes between TOC and metadata requests is rejected',
    () async {
      final fixture = _Fixture()..info = _chapter(url: '/chapter/changed');
      await expectLater(
        fixture.repository.chapter(_book, _urlChapter),
        _identityError(),
      );
      expect(fixture.requestedChapter, isTrue);
    },
  );
}
