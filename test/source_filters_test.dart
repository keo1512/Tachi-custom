import 'dart:convert';
import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tachi_books/core/theme/app_theme.dart';
import 'package:tachi_books/features/library/data/library_repository.dart';
import 'package:tachi_books/features/library/presentation/library_view_model.dart';
import 'package:tachi_books/features/settings/settings_controller.dart';
import 'package:tachi_books/features/sources/data/native_tachi_repository.dart';
import 'package:tachi_books/features/sources/data/on_device_source_repository.dart';
import 'package:tachi_books/features/sources/data/source_repository.dart';
import 'package:tachi_books/features/sources/domain/catalogue.dart';
import 'package:tachi_books/features/sources/domain/source_filters.dart';
import 'package:tachi_books/features/sources/presentation/source_filter_presets.dart';
import 'package:tachi_books/features/sources/presentation/source_filter_sheet.dart';
import 'package:tachi_books/features/sources/presentation/source_search_screen.dart';
import 'package:tachi_books/features/sources/presentation/source_preferences_dialog.dart';

const _source = CatalogueSource(
  id: '9223372036854775806',
  name: 'Original source',
  lang: 'vi',
  baseUrl: 'https://source.test',
  kind: ContentKind.manga,
  engine: SourceEngine.tachimanga,
);
const _schema =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
SourceFilterSet _filters() => const SourceFilterSet(
  schema: _schema,
  filters: [
    SourceFilterNode(
      name: 'Country',
      type: SourceFilterType.select,
      values: ['Any', 'Vietnam'],
      state: 0,
    ),
    SourceFilterNode(
      name: 'Genres',
      type: SourceFilterType.group,
      children: [
        SourceFilterNode(
          name: 'Adventure',
          type: SourceFilterType.tristate,
          state: 0,
        ),
        SourceFilterNode(
          name: 'Completed',
          type: SourceFilterType.checkbox,
          state: false,
        ),
      ],
    ),
    SourceFilterNode(
      name: 'Original custom control',
      type: SourceFilterType.unsupported,
      className: 'original.CustomFilter',
    ),
  ],
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  test('filter roundtrip preserves nested typed state and explicitly unsupported original controls', () {
    final original = _filters(), copied = original.clone();
    expect(copied.toJson(), original.toJson());
    expect(copied.filters[1].children[0].state, 0);
    expect(copied.filters.last.type, SourceFilterType.unsupported);
    expect(copied.filters.last.toJson().containsKey('state'), false);
    final invalid = original.toJson();
    (invalid['filters'] as List).first['state'] = 20;
    expect(
      () => SourceFilterSet.fromJson(invalid),
      throwsA(isA<ApiException>()),
    );
    invalid['schema'] = 'wrong';
    expect(
      () => SourceFilterSet.fromJson(invalid),
      throwsA(isA<ApiException>()),
    );
  });

  test('native filter RPC and search apply exact IDs, schema, states and page without fallback', () async {
    final directory = await Directory.systemTemp.createTemp(
      'source-filters-test-',
    );
    final requests = <Map<String, dynamic>>[];
    final native = NativeTachiRepository(
      storageDirectory: directory,
      executor: (raw) async {
        final request = jsonDecode(raw) as Map<String, dynamic>;
        requests.add(request);
        return jsonEncode({
          'ok': true,
          'result': switch (request['method']) {
            'filters' => _filters().toJson(),
            'search' => {'items': []},
            _ => {},
          },
        });
      },
    );
    final repository = OnDeviceSourceRepository(
      tachimangaUrl: '',
      vbookUrl: '',
      runtimes: {SourceEngine.tachimanga: native},
    );
    expect(repository.supportsSourceFilters(SourceEngine.tachimanga), true);
    expect(repository.supportsSourceFilters(SourceEngine.vbook), false);
    final filters = await repository.sourceFilters(_source);
    await repository.searchFiltered(_source, '', filters, page: 2);
    expect(requests[1], {
      'method': 'filters',
      'args': {'sourceId': _source.id},
    });
    expect(requests.last['args'], {
      'sourceId': _source.id,
      'query': '',
      'page': 2,
      'filterSchema': _schema,
      'filters': filters.toJson()['filters'],
    });
    repository.dispose();
    await directory.delete(recursive: true);
  });

  test('filter presets retain separate sources, survive reload and serialized edits, preserve corrupt input', () async {
    final preferences = await SharedPreferences.getInstance();
    final store = SourceFilterPresetStore(preferences);
    await Future.wait([
      store.save(_source.identity, 'Series', _filters()),
      store.save('tachimanga:other', 'Other source', _filters()),
      store.save(_source.identity, 'Adventure', _filters()),
    ]);
    final reloaded = SourceFilterPresetStore(preferences);
    expect(reloaded.list(_source.identity).map((p) => p.name), [
      'Series',
      'Adventure',
    ]);
    await reloaded.remove(_source.identity, 'Series');
    expect(reloaded.list(_source.identity).single.name, 'Adventure');
    expect(reloaded.list('tachimanga:other').single.name, 'Other source');
    await preferences.setString(
      SourceFilterPresetStore.key,
      '{invalid saved file',
    );
    await expectLater(
      reloaded.save(_source.identity, 'Replacement', _filters()),
      throwsA(isA<ApiException>()),
    );
    expect(
      preferences.getString(SourceFilterPresetStore.key),
      '{invalid saved file',
    );
  });

  test('editing a saved filter renames atomically without overwriting another preset or reviving a removed one', () async {
    final preferences = await SharedPreferences.getInstance();
    var current = true;
    final store = SourceFilterPresetStore(
      preferences,
      isCurrent: () => current,
    );
    await store.save(_source.identity, 'Original', _filters());
    await store.save(_source.identity, 'Keep', _filters());
    final changed = SourceFilterSet(
      schema: _schema,
      filters: [
        _filters().filters.first.copyWith(state: 1),
        ..._filters().filters.skip(1),
      ],
    );
    final before = preferences.getString(SourceFilterPresetStore.key);
    await expectLater(
      store.replace(_source.identity, 'Original', 'Keep', changed),
      throwsA(isA<ApiException>()),
    );
    expect(preferences.getString(SourceFilterPresetStore.key), before);
    await store.replace(_source.identity, 'Original', 'Renamed', changed);
    expect(store.list(_source.identity).map((p) => p.name), [
      'Keep',
      'Renamed',
    ]);
    expect(store.list(_source.identity).last.filters.filters.first.state, 1);
    await store.remove(_source.identity, 'Renamed');
    await expectLater(
      store.replace(_source.identity, 'Renamed', 'Revived', changed),
      throwsA(isA<ApiException>()),
    );
    current = false;
    await expectLater(
      store.save(_source.identity, 'Stale', changed),
      throwsA(isA<ApiException>()),
    );
    expect(store.list(_source.identity).single.name, 'Keep');
  });

  for (final size in [const Size(320, 568), const Size(430, 932)]) {
    testWidgets(
      'original controls apply filtered search, save/reset/reload/delete presets at $size',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = size;
        addTearDown(tester.view.reset);
        final preferences = await SharedPreferences.getInstance(),
            repo = _Repository();
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              preferencesProvider.overrideWithValue(preferences),
              sourceRepositoryProvider.overrideWithValue(repo),
              libraryRepositoryProvider.overrideWithValue(
                MemoryLibraryRepository(),
              ),
            ],
            child: MaterialApp(
              theme: appTheme(Brightness.dark),
              home: const SourceSearchScreen(source: _source),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Bộ lọc của nguồn'));
        await tester.pumpAndSettle();
        await tester.scrollUntilVisible(
          find.byKey(const ValueKey('source-filter-2')),
          80,
          scrollable: find
              .descendant(
                of: find.byType(SourceFilterSheet),
                matching: find.byType(Scrollable),
              )
              .first,
        );
        expect(
          find.textContaining('Bộ lọc này chưa được engine hỗ trợ'),
          findsOneWidget,
        );
        await Scrollable.ensureVisible(
          tester.element(find.byType(DropdownButton<int>).first),
          alignment: .5,
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byType(DropdownButton<int>).first);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Vietnam').last);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Lưu bộ lọc'));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byType(CupertinoTextField).last,
          'VN books',
        );
        await tester.tap(find.text('Lưu'));
        await tester.pumpAndSettle();
        expect(
          SourceFilterPresetStore(preferences)
              .list(_source.identity)
              .single
              .filters
              .filters
              .first
              .state,
          1,
        );
        await tester.tap(find.text('Đặt lại'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Bộ lọc đã lưu'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('VN books'));
        await tester.pumpAndSettle();
        await Scrollable.ensureVisible(
          tester.element(find.byTooltip('Đặt lại Country')),
          alignment: .5,
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Đặt lại Country'));
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<DropdownButton<int>>(
                find.byType(DropdownButton<int>).first,
              )
              .value,
          0,
        );
        await tester.tap(find.text('Bộ lọc đã lưu'));
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Sửa VN books'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Lưu thay đổi'));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byType(CupertinoTextField).last,
          'VN revised',
        );
        await tester.tap(find.text('Lưu'));
        await tester.pumpAndSettle();
        expect(
          SourceFilterPresetStore(preferences)
              .list(_source.identity)
              .single
              .name,
          'VN revised',
        );
        await tester.tap(find.text('Áp dụng'));
        await tester.pumpAndSettle();
        expect(repo.selected!.filters.first.state, 1);
        expect(repo.lastQuery, '');
        expect(repo.filteredCalls, 1);
        await tester.tap(find.byTooltip('Bộ lọc của nguồn'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Bộ lọc đã lưu'));
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Xóa VN revised'));
        await tester.pumpAndSettle();
        expect(
          SourceFilterPresetStore(preferences).list(_source.identity),
          isEmpty,
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
        repo.dispose();
      },
    );
  }

  testWidgets(
    'changed source filter schema resets stale selected conditions and disables stale preset',
    (tester) async {
      final preferences = await SharedPreferences.getInstance(),
          repo = _Repository();
      final old = SourceFilterSet(
        schema:
            'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
        filters: _filters().filters,
      );
      await SourceFilterPresetStore(preferences)
          .save(_source.identity, 'Old conditions', old);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            preferencesProvider.overrideWithValue(preferences),
            sourceRepositoryProvider.overrideWithValue(repo),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: SourceFilterSheet(source: _source, selected: old),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('Nguồn đã thay đổi bộ lọc.'), findsOneWidget);
      await tester.tap(find.text('Bộ lọc đã lưu'));
      await tester.pumpAndSettle();
      final tile = tester.widget<ListTile>(
        find.widgetWithText(ListTile, 'Old conditions'),
      );
      expect(tile.onTap, isNull);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      repo.dispose();
    },
  );

  testWidgets(
    'source multi-select preferences preserve selected values, cancel safely and save typed list',
    (tester) async {
      final repository = _Repository();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [sourceRepositoryProvider.overrideWithValue(repository)],
          child: MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () => showSourcePreferences(context, _source),
                  child: const Text('Options'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Options'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Languages'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('English'));
      await tester.tap(find.text('Hủy'));
      await tester.pumpAndSettle();
      expect(repository.preferenceValues, isEmpty);
      await tester.tap(find.text('Languages'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<CheckboxListTile>(
              find.widgetWithText(CheckboxListTile, 'Vietnamese'),
            )
            .value,
        true,
      );
      expect(
        tester
            .widget<CheckboxListTile>(
              find.widgetWithText(CheckboxListTile, 'English'),
            )
            .value,
        false,
      );
      await tester.tap(find.text('English'));
      await tester.tap(find.text('Lưu'));
      await tester.pumpAndSettle();
      expect(repository.preferenceValues.single, ['vi', 'en']);
      expect(find.text('2 lựa chọn'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      repository.dispose();
    },
  );
}

class _Repository extends SourceRepository {
  _Repository() : super(tachimangaUrl: '', vbookUrl: '');
  SourceFilterSet? selected;
  String? lastQuery;
  int filteredCalls = 0;
  final preferenceValues = <dynamic>[];
  @override
  Future<List<Map<String, dynamic>>> sourcePreferences(
    CatalogueSource source,
  ) async => [
    {
      'type': 'MultiSelectListPreference',
      'props': {
        'key': 'languages',
        'title': 'Languages',
        'entries': ['Vietnamese', 'English'],
        'entryValues': ['vi', 'en'],
        'currentValue': jsonDecode('["vi"]'),
      },
    },
  ];
  @override
  Future<void> setSourcePreference(
    CatalogueSource source,
    int position,
    dynamic value,
  ) async {
    expect(source.id, _source.id);
    expect(position, 0);
    preferenceValues.add(value);
  }

  @override
  bool supportsSourceFilters(SourceEngine engine) =>
      engine == SourceEngine.tachimanga;
  @override
  Future<SourceFilterSet> sourceFilters(CatalogueSource source) async =>
      _filters();
  @override
  Future<List<CatalogueBook>> searchFiltered(
    CatalogueSource source,
    String query,
    SourceFilterSet filters, {
    int page = 1,
  }) async {
    selected = filters;
    lastQuery = query;
    filteredCalls++;
    return [];
  }
}
