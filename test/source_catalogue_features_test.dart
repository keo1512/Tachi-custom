import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tachi_books/features/settings/settings_controller.dart';
import 'package:tachi_books/features/sources/data/native_tachi_repository.dart';
import 'package:tachi_books/features/sources/data/source_repository.dart';
import 'package:tachi_books/features/sources/domain/catalogue.dart';
import 'package:tachi_books/features/sources/presentation/global_search_controller.dart';
import 'package:tachi_books/features/sources/presentation/extension_file_import.dart';
import 'package:tachi_books/features/sources/presentation/source_catalogue_tools.dart';

CatalogueSource source(String id) => CatalogueSource(
  id: id,
  name: id,
  lang: 'vi',
  baseUrl: 'https://example.test',
  kind: ContentKind.manga,
  engine: SourceEngine.tachimanga,
);
CatalogueExtension extension(
  String id,
  String version, {
  bool installed = false,
}) => CatalogueExtension(
  id: id,
  name: id,
  version: version,
  installed: installed,
  engine: SourceEngine.tachimanga,
);

void main() {
  test(
    'Files APK stream stops at the byte limit and releases the rejected stream',
    () async {
      var cancelled = false;
      final chunks = StreamController<List<int>>(
        onCancel: () => cancelled = true,
      );
      final reading = readExtensionPackage(chunks.stream);
      chunks.add(Uint8List(maxExtensionPackageBytes));
      chunks.add([1]);
      await expectLater(reading, throwsA(isA<ApiException>()));
      expect(cancelled, true);
      await chunks.close();
      expect(
        await readExtensionPackage(
          Stream.fromIterable([
            [0x50, 0x4b],
            [3, 4],
          ]),
        ),
        [0x50, 0x4b, 3, 4],
      );
    },
  );

  test(
    'global search retains at most six unique preview books per source',
    () async {
      final repo = _Search(
        (item, _) async => List.generate(
          20,
          (i) => CatalogueBook(
            ref: '/$i',
            title: '$i',
            sourceId: item.id,
            kind: item.kind,
            engine: item.engine,
          ),
        ),
      );
      final controller = GlobalSearchController(repo);
      await controller.search('story', [source('1')]);
      expect(controller.results.single.books, hasLength(6));
      controller.dispose();
      repo.dispose();
    },
  );
  test('global search publishes independent partial results and limits concurrent sources to three', () async {
    final pending = <String, Completer<List<CatalogueBook>>>{};
    final repo = _Search(
      (item, query) => (pending[item.id] = Completer()).future,
    );
    final controller = GlobalSearchController(repo);
    final done = controller.search(
      'story',
      List.generate(5, (i) => source('$i')),
    );
    await Future<void>.delayed(Duration.zero);
    expect(pending.keys, ['0', '1', '2']);
    expect(
      controller.results.where((r) => r.phase == SourceSearchPhase.queued),
      hasLength(2),
    );
    pending['1']!.complete([]);
    await Future<void>.delayed(Duration.zero);
    expect(controller.results[1].phase, SourceSearchPhase.complete);
    expect(controller.results[0].phase, SourceSearchPhase.loading);
    expect(pending.keys, ['0', '1', '2', '3']);
    pending['2']!.completeError(const ApiException('one source failed'));
    await Future<void>.delayed(Duration.zero);
    expect(controller.results[2].error, 'one source failed');
    expect(pending.keys, ['0', '1', '2', '3', '4']);
    for (final id in ['0', '3', '4']) {
      pending[id]!.complete([]);
    }
    await done;
    expect(controller.busy, false);
    controller.dispose();
    repo.dispose();
  });

  test(
    'a superseded query and disposal reject old asynchronous responses',
    () async {
      final old = Completer<List<CatalogueBook>>(),
          current = Completer<List<CatalogueBook>>();
      final repo = _Search(
        (_, query) => query == 'old' ? old.future : current.future,
      );
      await Future<void>.delayed(Duration.zero);
      final controller = GlobalSearchController(repo);
      final first = controller.search('old', [source('large-id')]);
      await Future<void>.delayed(Duration.zero);
      final second = controller.search('new', [source('large-id')]);
      current.complete([]);
      await second;
      old.completeError(const ApiException('late old failure'));
      await first;
      expect(controller.query, 'new');
      expect(controller.results.single.error, isNull);
      final delayed = Completer<List<CatalogueBook>>();
      final disposed = GlobalSearchController(
        _Search((_, _) => delayed.future),
      );
      var changes = 0;
      disposed.addListener(() => changes++);
      final operation = disposed.search('q', [source('1')]);
      final before = changes;
      disposed.dispose();
      delayed.complete([]);
      await operation;
      expect(changes, before);
      controller.dispose();
      repo.dispose();
    },
  );

  test('update planning chooses highest numeric release and rejects downgrade, unknown release and foreign IDs', () {
    expect(
      availableExtensionUpdates(
        [
          extension('a', '1.6.2'),
          extension('a', '1.6.10'),
          extension('b', '1.4'),
          extension('c', 'nightly'),
          extension('unknown', '9'),
        ],
        [
          extension('a', '1.6.1', installed: true),
          extension('b', '1.6', installed: true),
          extension('c', '1', installed: true),
        ],
      ).map((e) => e.version),
      ['1.6.10'],
    );
    expect(compareExtensionVersions('1.2', '1.2.0'), 0);
    expect(compareExtensionVersions('x', '1'), isNull);
  });

  test(
    'pinned source reorder preserves hidden pins and a concurrent pin toggle',
    () async {
      SharedPreferences.setMockInitialValues({
        'pinnedSources': ['a', 'hidden', 'b'],
      });
      final prefs = await SharedPreferences.getInstance();
      final container = ProviderContainer(
        overrides: [preferencesProvider.overrideWithValue(prefs)],
      );
      final settings = container.read(settingsProvider.notifier);
      await Future.wait([
        settings.setPinnedSourceOrder(['b', 'a', 'foreign', 'b']),
        settings.toggleSourcePin('c'),
      ]);
      expect(prefs.getStringList('pinnedSources'), ['b', 'a', 'hidden', 'c']);
      expect(container.read(settingsProvider).pinnedSources, [
        'b',
        'a',
        'hidden',
        'c',
      ]);
      container.dispose();
    },
  );

  test('native catalogue mode and package removal forward original IDs without using a companion', () async {
    final dir = await Directory.systemTemp.createTemp('tachi-native-browse-');
    final calls = <Map<String, dynamic>>[];
    final repo = NativeTachiRepository(
      storageDirectory: dir,
      executor: (raw) async {
        final request = jsonDecode(raw) as Map<String, dynamic>;
        calls.add(request);
        return jsonEncode({
          'ok': true,
          'result': request['method'] == 'initialize'
              ? {}
              : request['method'] == 'uninstall'
              ? true
              : {'items': []},
        });
      },
    );
    await repo.browse(
      source('9223372036854775806'),
      mode: SourceBrowseMode.popular,
      page: 3,
    );
    await repo.browse(
      source('9223372036854775806'),
      mode: SourceBrowseMode.latest,
    );
    await repo.uninstallExtension('eu.kanade.tachiyomi.extension.vi.example');
    expect(calls[1]['args'], {
      'sourceId': '9223372036854775806',
      'mode': 'popular',
      'page': 3,
    });
    expect(calls[2]['args'], {
      'sourceId': '9223372036854775806',
      'mode': 'latest',
      'page': 1,
    });
    expect(calls[3]['args'], {
      'id': 'eu.kanade.tachiyomi.extension.vi.example',
    });
    repo.dispose();
    await dir.delete(recursive: true);
  });

  test('chapter metadata preserves dates and fractional numbers, unknown values remain nullable', () {
    expect(catalogueChapterNumber(2.5), 2.5);
    expect(catalogueChapterNumber(-1), isNull);
    expect(catalogueChapterNumber(double.nan), isNull);
    expect(
      catalogueUploadDate(1790000000000)!.millisecondsSinceEpoch,
      1790000000000,
    );
    expect(catalogueUploadDate(0), isNull);
    expect(catalogueUploadDate('2026'), isNull);
    expect(catalogueStatus('PUBLISHING_FINISHED'), 4);
    expect(catalogueStatus(6), 6);
    expect(catalogueStatus('unknown-provider-status'), 0);
  });
}

class _Search extends SourceRepository {
  _Search(this.searcher) : super(tachimangaUrl: '', vbookUrl: '');
  final Future<List<CatalogueBook>> Function(CatalogueSource, String) searcher;
  @override
  Future<List<CatalogueBook>> search(
    CatalogueSource source,
    String query, {
    int page = 1,
  }) => searcher(source, query);
}
