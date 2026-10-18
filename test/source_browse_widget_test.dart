import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tachi_books/core/theme/app_theme.dart';
import 'package:tachi_books/features/library/data/library_repository.dart';
import 'package:tachi_books/features/library/domain/library_book.dart';
import 'package:tachi_books/features/library/presentation/library_view_model.dart';
import 'package:tachi_books/features/settings/settings_controller.dart';
import 'package:tachi_books/features/sources/data/source_repository.dart';
import 'package:tachi_books/features/sources/data/extension_index.dart';
import 'package:tachi_books/features/sources/domain/catalogue.dart';
import 'package:tachi_books/features/sources/domain/source_languages.dart';
import 'package:tachi_books/features/sources/presentation/browse_screen.dart';
import 'package:tachi_books/features/sources/presentation/browse_widgets.dart';
import 'package:tachi_books/features/sources/presentation/extension_catalogue_controller.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({
      'tachimangaUrl': 'http://tachi.test',
      'vbookUrl': 'http://vbook.test',
    });
  });

  for (final size in const [Size(320, 568), Size(430, 932)]) {
    testWidgets(
      'multiple languages filter installed sources and survive saved changes at $size',
      (tester) async {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(
          'sourceLanguagesV1',
          const SourceLanguages({'vi', 'en'}).encode(),
        );
        final repo = SourceRepository(
          tachimangaUrl: 'http://tachi.test',
          vbookUrl: '',
          client: MockClient(
            (request) async => http.Response(
              jsonEncode([
                for (final code in ['vi', 'en', 'ja'])
                  {
                    'id': code,
                    'name': 'Source $code',
                    'lang': code,
                    'baseUrl': 'https://$code.test',
                  },
              ]),
              200,
            ),
          ),
        );
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = size;
        addTearDown(tester.view.reset);
        final router = await mountBrowse(tester, prefs, repo);
        expect(find.text('Source vi'), findsOneWidget);
        expect(find.text('Source en'), findsOneWidget);
        expect(find.text('Source ja'), findsNothing);
        await tester.tap(find.byTooltip('Ngôn ngữ'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Chọn nhiều ngôn ngữ và lưu'));
        await tester.pumpAndSettle();
        final english = find.widgetWithText(CheckboxListTile, 'English');
        await tester.ensureVisible(english);
        await tester.tap(english);
        await tester.tap(find.text('Lưu'));
        await tester.pumpAndSettle();
        expect(
          SourceLanguages.decode(prefs.getString('sourceLanguagesV1')).enabled,
          {'vi'},
        );
        expect(find.text('Source en'), findsNothing);
        expect(find.text('Đã bật 1 ngôn ngữ'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        router.dispose();
        repo.dispose();
      },
    );
    testWidgets(
      'one failed engine preserves sources, pinning and recent navigation at $size',
      (tester) async {
        final prefs = await SharedPreferences.getInstance();
        final requests = <String>[];
        final repo = SourceRepository(
          tachimangaUrl: 'http://tachi.test',
          vbookUrl: 'http://vbook.test',
          client: MockClient((request) async {
            requests.add(request.url.toString());
            if (request.url.host == 'vbook.test') {
              return http.Response('unavailable', 503);
            }
            return http.Response(
              jsonEncode([
                {
                  'id': '9007199254740993',
                  'name': 'Manga source',
                  'lang': 'vi',
                  'baseUrl': 'https://source.test',
                },
                {
                  'id': '2',
                  'name': 'English source',
                  'lang': 'en',
                  'baseUrl': 'https://en.test',
                },
              ]),
              200,
            );
          }),
        );
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = size;
        addTearDown(tester.view.reset);
        final router = await mountBrowse(tester, prefs, repo);
        expect(find.text('Manga source'), findsOneWidget);
        expect(find.textContaining('vBook:'), findsOneWidget);
        expect(
          requests,
          containsAll([
            'http://tachi.test/api/v1/source/list',
            'http://vbook.test/v1/sources',
          ]),
        );
        expect(
          find.byType(CupertinoSegmentedControl<SourceEngine>),
          findsNothing,
        );
        expect(tester.takeException(), isNull);
        await tester.tap(find.byTooltip('Ghim Manga source'));
        await tester.pumpAndSettle();
        expect(prefs.getStringList('pinnedSources'), [
          'tachimanga:9007199254740993',
        ]);
        expect(find.text('Đã ghim'), findsOneWidget);
        final row = find.byWidgetPredicate(
          (w) => w is SourceBrowseRow && w.source.id == '9007199254740993',
        );
        await tester.ensureVisible(row.first);
        await tester.pumpAndSettle();
        await tester.tap(
          find.descendant(of: row.first, matching: find.text('Manga source')),
        );
        await tester.pumpAndSettle();
        expect(
          find.text('Source route: tachimanga:9007199254740993'),
          findsOneWidget,
        );
        expect(
          prefs.getStringList('recentSources')!.first,
          'tachimanga:9007199254740993',
        );
        router.pop();
        await tester.pumpAndSettle();
        expect(find.text('Sử dụng lần cuối'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        repo.dispose();
        router.dispose();
      },
    );
  }

  testWidgets(
    'both engines merge and link addition fetches a local repository catalogue',
    (tester) async {
      final prefs = await SharedPreferences.getInstance();
      final posts = <http.Request>[];
      var installed = false;
      final indexes = ExtensionIndexRepository(
        MockClient((request) async {
          expect(request.url.toString(), 'https://packages.test/registry.json');
          return http.Response(
            jsonEncode({
              'data': [
                {
                  'name': 'Catalogue fixture',
                  'path': 'fixture/plugin.zip',
                  'version': 1,
                  'locale': 'vi_VN',
                },
              ],
            }),
            200,
          );
        }),
      );
      final repo = SourceRepository(
        tachimangaUrl: 'http://tachi.test',
        vbookUrl: 'http://vbook.test',
        client: MockClient((request) async {
          if (request.method == 'POST') {
            posts.add(request);
            installed = true;
            return http.Response('{}', 200);
          }
          if (request.url.path.contains('extension')) {
            if (request.url.host == 'vbook.test' && installed) {
              return http.Response(
                jsonEncode([
                  {
                    'id': 'vb-installed-fixture',
                    'name': 'Catalogue fixture',
                    'version': 1,
                    'lang': 'vi_VN',
                    'packageUrl': 'https://packages.test/fixture/plugin.zip',
                  },
                ]),
                200,
              );
            }
            return http.Response('[]', 200);
          }
          return http.Response(
            jsonEncode([
              {
                'id': request.url.host == 'vbook.test' ? 'novel' : 'manga',
                'name': request.url.host == 'vbook.test'
                    ? 'Novel source'
                    : 'Manga source',
                'lang': 'vi',
                'kind': 'novel',
                'baseUrl': 'https://source.test',
              },
            ]),
            200,
          );
        }),
      );
      final router = await mountBrowse(tester, prefs, repo, indexes: indexes);
      expect(find.text('Novel source'), findsOneWidget);
      expect(find.text('Manga source'), findsOneWidget);
      expect(find.byTooltip('Cấu hình Novel source'), findsNothing);
      expect(find.byTooltip('Cấu hình Manga source'), findsOneWidget);
      await tester.tap(find.text('Tiện ích'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Thêm kho extension bằng link'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('vBook').last);
      await tester.pumpAndSettle();
      expect(find.text('Thêm extension vBook'), findsOneWidget);
      await tester.enterText(
        find.byType(TextField),
        'https://packages.test/registry.json',
      );
      await tester.tap(find.text('Thêm'));
      await waitForRepositorySave(tester, prefs);
      await tester.pumpAndSettle();
      expect(posts, isEmpty);
      expect(
        prefs.getString('extensionRepositoriesV1'),
        isNotNull,
        reason: find
            .byType(Text)
            .evaluate()
            .map((element) => (element.widget as Text).data)
            .join(' | '),
      );
      expect(find.text('Catalogue fixture'), findsOneWidget);
      expect(find.text('Cài'), findsOneWidget);
      expect(find.text('Đã cài'), findsNothing);
      expect(jsonDecode(prefs.getString('extensionRepositoriesV1')!), [
        {'url': 'https://packages.test/registry.json', 'engine': 'vbook'},
      ]);
      await tester.tap(find.text('Cài'));
      await tester.pumpAndSettle();
      expect(posts.length, 1);
      expect(
        posts.single.url.toString(),
        'http://vbook.test/v1/extensions/install',
      );
      expect(jsonDecode(posts.single.body), {
        'url': 'https://packages.test/fixture/plugin.zip',
      });
      expect(find.text('Đã cài'), findsWidgets);
      expect(find.text('Cài'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      repo.dispose();
      router.dispose();
    },
  );

  testWidgets(
    'repository list and presets work without an engine; install explains the missing engine',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      var engineRequests = 0;
      final repo = SourceRepository(
        tachimangaUrl: '',
        vbookUrl: '',
        client: MockClient((_) async {
          engineRequests++;
          return http.Response('{}', 200);
        }),
      );
      final indexes = ExtensionIndexRepository(
        MockClient(
          (_) async => http.Response(
            jsonEncode({
              'data': [
                {
                  'name': 'Fixture to install',
                  'path': 'fixture/plugin.zip',
                  'version': 1,
                },
              ],
            }),
            200,
          ),
        ),
      );
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(320, 568);
      addTearDown(tester.view.reset);
      final router = await mountBrowse(tester, prefs, repo, indexes: indexes);
      await tester.tap(find.text('Tiện ích'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Thêm kho extension bằng link'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('vBook').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Dùng kho vBook / Darkrai9x'));
      await tester.pump();
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'https://raw.githubusercontent.com/Darkrai9x/vbook-extensions/master/plugin.json',
      );
      await tester.enterText(
        find.byType(TextField),
        'https://fixture.test/plugin.json',
      );
      await tester.tap(find.text('Thêm'));
      await waitForRepositorySave(tester, prefs);
      await tester.pumpAndSettle();
      expect(find.text('Fixture to install'), findsOneWidget);
      // Let the successful "repository added" snackbar finish first.
      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cài'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Chưa có engine vBook'), findsWidgets);
      expect(find.text('Đã cài'), findsNothing);
      expect(engineRequests, 0);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      repo.dispose();
      router.dispose();
    },
  );

  testWidgets(
    'migration lists only online books and leaves their metadata and cache intact',
    (tester) async {
      final prefs = await SharedPreferences.getInstance();
      final library = MemoryLibraryRepository();
      await library.save(
        LibraryBook(
          id: 'online',
          title: 'Online book',
          engine: 'vbook',
          sourceId: 'old',
          progress: .5,
          bookmarks: ['0:0.5'],
        ),
      );
      await library.save(LibraryBook(id: 'local', title: 'Local book'));
      final content = ReaderContent(kind: 'novel', html: '<p>kept</p>');
      await library.saveChapter('online', 0, content);
      final repo = SourceRepository(
        tachimangaUrl: 'http://tachi.test',
        vbookUrl: 'http://vbook.test',
        client: MockClient((_) async => http.Response('[]', 200)),
      );
      final router = await mountBrowse(tester, prefs, repo, library: library);
      await tester.tap(find.byTooltip('Công cụ nguồn'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Chuyển nguồn'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('migration-origin-vbook:old')),
      );
      await tester.pumpAndSettle();
      // The source title already identifies this list. Its former instruction
      // header was removed to keep books reachable on short/large-text screens.
      expect(find.text('Chuyển nguồn hàng loạt'), findsOneWidget);
      expect(find.byTooltip('Chuyển nguồn các truyện'), findsOneWidget);
      expect(find.byKey(const ValueKey('migration-book-online')), findsOneWidget);
      expect(find.text('Local book'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('migration-book-online')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Tìm ở nguồn khác'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Chưa có nguồn thay thế phù hợp.'),
        findsOneWidget,
      );
      final kept = await library.find('online');
      expect(kept!.progress, .5);
      expect(kept.bookmarks, ['0:0.5']);
      expect((await library.readChapter('online', 0))!.html, '<p>kept</p>');
      expect((await library.list()).length, 2);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      repo.dispose();
      router.dispose();
    },
  );
}

// Repository loading includes streamed HTTP and platform preference writes.
// Wait for the observable write in the real async zone before settling frames.
Future<void> waitForRepositorySave(
  WidgetTester tester,
  SharedPreferences prefs,
) async {
  await tester.runAsync(() async {
    final deadline = DateTime.now().add(const Duration(seconds: 3));
    while (prefs.getString('extensionRepositoriesV1') == null) {
      if (DateTime.now().isAfter(deadline)) {
        throw StateError('Repository catalogue did not finish saving.');
      }
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
  });
}

Future<GoRouter> mountBrowse(
  WidgetTester tester,
  SharedPreferences prefs,
  SourceRepository repo, {
  MemoryLibraryRepository? library,
  ExtensionIndexRepository? indexes,
}) async {
  final router = GoRouter(
    routes: [
      GoRoute(path: '/', builder: (_, _) => const BrowseScreen()),
      GoRoute(
        path: '/source',
        builder: (_, state) => Scaffold(
          body: Text(
            'Source route: ${(state.extra! as CatalogueSource).identity}',
          ),
        ),
      ),
    ],
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        preferencesProvider.overrideWithValue(prefs),
        sourceRepositoryProvider.overrideWithValue(repo),
        if (indexes != null)
          extensionIndexRepositoryProvider.overrideWithValue(indexes),
        libraryRepositoryProvider.overrideWithValue(
          library ?? MemoryLibraryRepository(),
        ),
      ],
      child: MaterialApp.router(
        theme: appTheme(Brightness.dark),
        routerConfig: router,
      ),
    ),
  );
  await tester.pumpAndSettle();
  return router;
}
