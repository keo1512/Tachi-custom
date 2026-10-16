import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tachi_books/features/library/presentation/library_view_model.dart';
import 'package:tachi_books/features/settings/settings_controller.dart';
import 'package:tachi_books/features/sources/data/extension_index.dart';
import 'package:tachi_books/features/sources/data/source_repository.dart';
import 'package:tachi_books/features/sources/domain/catalogue.dart';
import 'package:tachi_books/features/sources/domain/source_languages.dart';
import 'package:tachi_books/features/sources/presentation/extension_catalogue_controller.dart';
import 'package:tachi_books/features/sources/presentation/source_languages_sheet.dart';

class _Sources extends SourceRepository {
  _Sources() : super(tachimangaUrl: '', vbookUrl: '');
  bool fail = false;
  Completer<void>? gate;
  String failure = 'Nguồn tạm thời không phản hồi.';
  bool empty = false;
  @override
  bool requiresExternalConnection(SourceEngine engine) => false;
  @override
  Future<List<CatalogueSource>> listSources(SourceEngine engine) async {
    await gate?.future;
    if (fail) throw ApiException(failure);
    return engine == SourceEngine.tachimanga && !empty
        ? [
            const CatalogueSource(
              id: '1',
              name: 'Nguồn',
              lang: 'vi',
              baseUrl: 'https://source.test',
              kind: ContentKind.manga,
              engine: SourceEngine.tachimanga,
            ),
          ]
        : [];
  }
}

class _Catalogue extends ExtensionCatalogueController {
  _Catalogue(this.values, {this.error});
  final List<ExtensionIndex> values;
  final Object? error;
  @override
  Future<List<ExtensionIndex>> build() async {
    if (error != null) throw error!;
    return values;
  }
}

void main() {
  Future<SharedPreferences> mount(
    WidgetTester tester,
    _Sources repository, {
    List<ExtensionIndex> indexes = const [],
    Object? catalogueError,
    Size? size,
  }) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    if (size != null) {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = size;
      addTearDown(tester.view.reset);
    }
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          preferencesProvider.overrideWithValue(prefs),
          sourceRepositoryProvider.overrideWithValue(repository),
          extensionCatalogueProvider.overrideWith(
            () => _Catalogue(indexes, error: catalogueError),
          ),
        ],
        child: MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(size == null ? 1 : 1.5)),
            child: child!,
          ),
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => showAvailableSourceLanguages(context),
                child: const Text('Ngôn ngữ nguồn truyện'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Ngôn ngữ nguồn truyện'));
    await tester.pump();
    return prefs;
  }

  testWidgets(
    'settings language sheet waits for sources and includes repository languages',
    (tester) async {
      final repository = _Sources()..gate = Completer<void>();
      addTearDown(repository.dispose);
      final prefs = await mount(
        tester,
        repository,
        indexes: [
          const ExtensionIndex('https://repo.test', SourceEngine.vbook, [
            CatalogueExtension(
              id: 'new',
              name: 'Mới',
              version: '1',
              lang: 'ja',
              engine: SourceEngine.vbook,
            ),
          ]),
        ],
      );
      expect(find.text('Đóng'), findsOneWidget);
      expect(find.text('Lưu'), findsNothing);
      repository.gate!.complete();
      await tester.pumpAndSettle();
      expect(find.text('Tiếng Việt'), findsOneWidget);
      expect(find.text('日本語'), findsOneWidget);
      await tester.tap(find.widgetWithText(CheckboxListTile, '日本語'));
      await tester.tap(find.text('Lưu'));
      await tester.pumpAndSettle();
      expect(
        SourceLanguages.decode(prefs.getString('sourceLanguagesV1')).enabled,
        {'vi'},
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'catalogue failure is handled while source loading remains pending',
    (tester) async {
      final repository = _Sources()..gate = Completer<void>();
      addTearDown(repository.dispose);
      await mount(
        tester,
        repository,
        catalogueError: const FormatException('Kho bị lỗi.'),
      );
      await tester.pump(const Duration(milliseconds: 100));
      expect(tester.takeException(), isNull);
      repository.gate!.complete();
      await tester.pumpAndSettle();
      expect(find.text('Tiếng Việt'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'landscape empty and long error states scroll without overflow at 150 percent',
    (tester) async {
      final repository = _Sources()
        ..fail = true
        ..failure =
            'Không tải được danh sách ngôn ngữ. Hãy kiểm tra địa chỉ nguồn và kết nối Internet rồi thử lại để tiếp tục chọn ngôn ngữ truyện.';
      addTearDown(repository.dispose);
      await mount(tester, repository, size: const Size(568, 320));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.scrollUntilVisible(find.text('Thử lại'), 100);
      repository.fail = false;
      repository.empty = true;
      await tester.tap(find.text('Thử lại'));
      await tester.pumpAndSettle();
      expect(find.text('Tất cả ngôn ngữ'), findsOneWidget);
      expect(find.text('Lưu'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Lưu'));
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'settings language load error retries and keeps the sheet usable',
    (tester) async {
      final repository = _Sources()..fail = true;
      addTearDown(repository.dispose);
      await mount(tester, repository);
      await tester.pumpAndSettle();
      expect(find.text('Thử lại'), findsOneWidget);
      expect(find.text('Lưu'), findsNothing);
      repository.fail = false;
      await tester.tap(find.text('Thử lại'));
      await tester.pumpAndSettle();
      expect(find.text('Tiếng Việt'), findsOneWidget);
      expect(find.text('Lưu'), findsOneWidget);
      expect(find.text('Thử lại'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
