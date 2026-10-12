import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tachi_books/features/sources/data/on_device_source_repository.dart';
import 'package:tachi_books/features/sources/domain/catalogue.dart';
import 'package:tachi_books/features/sources/domain/native_source_engine.dart';

const _source = CatalogueSource(
  id: '9223372036854775806',
  name: 'Installed source',
  lang: 'vi',
  baseUrl: 'https://source.example',
  kind: ContentKind.manga,
  engine: SourceEngine.tachimanga,
);
const _book = CatalogueBook(
  ref: '/series/original',
  title: 'Original title',
  sourceId: '9223372036854775806',
  kind: ContentKind.manga,
  engine: SourceEngine.tachimanga,
);
const _chapter = CatalogueChapter(
  ref: '/chapter/original',
  title: 'Original chapter',
  index: 3,
);

class _Runtime implements NativeSourceEngine {
  final calls = <String>[];
  CatalogueSource? searchedSource;
  String? query;
  int? page;
  CatalogueBook? openedBook;
  CatalogueChapter? openedChapter;
  String? packageUrl;
  int? preferencePosition;
  dynamic preferenceValue;
  bool failHealth = false;

  @override
  Future<Map<String, dynamic>> health() async {
    calls.add('health');
    if (failHealth) {
      throw const ApiException(
        'Native engine unavailable',
        code: 'RUNTIME_MISSING',
      );
    }
    return {'engine': 'tachi', 'protocolVersion': 1};
  }

  @override
  Future<List<CatalogueSource>> listSources() async {
    calls.add('sources');
    return [_source];
  }

  @override
  Future<List<CatalogueExtension>> extensions() async {
    calls.add('extensions');
    return [
      const CatalogueExtension(
        id: 'original.package',
        name: 'Original',
        version: '1',
        engine: SourceEngine.tachimanga,
        installed: true,
      ),
    ];
  }

  @override
  Future<void> installExtension(String packageUrl) async {
    calls.add('install');
    this.packageUrl = packageUrl;
  }

  @override
  Future<List<CatalogueBook>> search(
    CatalogueSource source,
    String query, {
    int page = 1,
  }) async {
    calls.add('search');
    searchedSource = source;
    this.query = query;
    this.page = page;
    return [_book];
  }

  @override
  Future<CatalogueBook> detail(CatalogueBook book) async {
    calls.add('detail');
    openedBook = book;
    return book;
  }

  @override
  Future<List<CatalogueChapter>> chapters(CatalogueBook book) async {
    calls.add('chapters');
    openedBook = book;
    return [_chapter];
  }

  @override
  Future<ChapterContent> chapter(
    CatalogueBook book,
    CatalogueChapter chapter,
  ) async {
    calls.add('chapter');
    openedBook = book;
    openedChapter = chapter;
    return const ChapterContent(
      kind: ContentKind.manga,
      images: ['https://images.example/1.png'],
      imageHeaders: {
        'https://images.example/1.png': {
          'Referer': 'https://source.example',
          'Cookie': 'reader=fixture',
        },
      },
    );
  }

  @override
  Future<List<Map<String, dynamic>>> sourcePreferences(
    CatalogueSource source,
  ) async {
    calls.add('preferences');
    return [
      {
        'type': 'EditTextPreference',
        'props': {'key': 'base_url', 'currentValue': 'https://source.example'},
      },
    ];
  }

  @override
  Future<void> setSourcePreference(
    CatalogueSource source,
    int position,
    dynamic value,
  ) async {
    calls.add('setPreference');
    preferencePosition = position;
    preferenceValue = value;
  }

  @override
  void dispose() => calls.add('dispose');
}

void main() {
  test(
    'installed Tachi routes every operation locally without companion HTTP',
    () async {
      var companionRequests = 0;
      final runtime = _Runtime();
      await http.runWithClient(
        () async {
          final repository = OnDeviceSourceRepository(
            tachimangaUrl: 'http://localhost:4567',
            vbookUrl: 'http://localhost:4570',
            runtimes: {SourceEngine.tachimanga: runtime},
          );
          expect(
            repository.requiresExternalConnection(SourceEngine.tachimanga),
            isFalse,
          );
          expect(
            repository.requiresExternalConnection(SourceEngine.vbook),
            isTrue,
          );
          expect(
            (await repository.health(
              SourceEngine.tachimanga,
            ))['protocolVersion'],
            1,
          );
          expect(
            (await repository.listSources(SourceEngine.tachimanga)).single.id,
            _source.id,
          );
          expect(
            (await repository.extensions(SourceEngine.tachimanga))
                .single
                .installed,
            isTrue,
          );
          await repository.installExtension(
            SourceEngine.tachimanga,
            'https://repo.example/original.apk',
          );
          expect(runtime.packageUrl, 'https://repo.example/original.apk');
          expect(
            (await repository.search(_source, 'Original', page: 4)).single.ref,
            _book.ref,
          );
          expect(runtime.searchedSource, same(_source));
          expect(runtime.query, 'Original');
          expect(runtime.page, 4);
          expect(await repository.detail(_book), same(_book));
          expect((await repository.chapters(_book)).single, same(_chapter));
          final content = await repository.chapter(_book, _chapter);
          expect(runtime.openedBook, same(_book));
          expect(runtime.openedChapter, same(_chapter));
          expect(content.headersFor(content.images.single), {
            'Referer': 'https://source.example',
            'Cookie': 'reader=fixture',
          });
          expect(
            (await repository.sourcePreferences(_source))
                .single['props']['key'],
            'base_url',
          );
          await repository.setSourcePreference(
            _source,
            2,
            'https://new.example',
          );
          expect(runtime.preferencePosition, 2);
          expect(runtime.preferenceValue, 'https://new.example');
          repository.dispose();
        },
        () => MockClient((_) async {
          companionRequests++;
          throw StateError('On-device Tachi must not issue companion HTTP');
        }),
      );
      expect(companionRequests, 0);
      expect(runtime.calls, [
        'health',
        'sources',
        'extensions',
        'install',
        'search',
        'detail',
        'chapters',
        'chapter',
        'preferences',
        'setPreference',
        'dispose',
      ]);
    },
  );

  test(
    'an unavailable native engine fails without silently using a companion',
    () async {
      var companionRequests = 0;
      final runtime = _Runtime()..failHealth = true;
      await http.runWithClient(
        () async {
          final repository = OnDeviceSourceRepository(
            tachimangaUrl: 'http://localhost:4567',
            vbookUrl: '',
            runtimes: {SourceEngine.tachimanga: runtime},
          );
          await expectLater(
            repository.health(SourceEngine.tachimanga),
            throwsA(
              isA<ApiException>().having(
                (error) => error.code,
                'code',
                'RUNTIME_MISSING',
              ),
            ),
          );
          expect(
            repository.requiresExternalConnection(SourceEngine.tachimanga),
            isFalse,
          );
          repository.dispose();
        },
        () => MockClient((_) async {
          companionRequests++;
          return http.Response('{}', 200);
        }),
      );
      expect(companionRequests, 0);
    },
  );

  test(
    'the other engine retains its existing companion route independently',
    () async {
      final requestedUrls = <String>[];
      final runtime = _Runtime();
      await http.runWithClient(
        () async {
          final repository = OnDeviceSourceRepository(
            tachimangaUrl: 'http://localhost:4567',
            vbookUrl: 'http://localhost:4570/prefix',
            runtimes: {SourceEngine.tachimanga: runtime},
          );
          expect(
            repository.requiresExternalConnection(SourceEngine.vbook),
            isTrue,
          );
          final sources = await repository.listSources(SourceEngine.vbook);
          expect(sources.single.engine, SourceEngine.vbook);
          expect(sources.single.kind, ContentKind.novel);
          expect(sources.single.id, 'vbook-source');
          expect(runtime.calls, isEmpty);
          repository.dispose();
        },
        () => MockClient((request) async {
          requestedUrls.add(request.url.toString());
          return http.Response(
            jsonEncode([
              {
                'id': 'vbook-source',
                'name': 'Original vBook source',
                'lang': 'vi',
                'kind': 'novel',
              },
            ]),
            200,
          );
        }),
      );
      expect(requestedUrls, ['http://localhost:4570/prefix/v1/sources']);
    },
  );
}
