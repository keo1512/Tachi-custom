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
import 'package:tachi_books/features/sources/domain/catalogue.dart';
import 'package:tachi_books/features/sources/presentation/browse_screen.dart';
import 'package:tachi_books/features/sources/presentation/browse_widgets.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({
      'tachimangaUrl': 'http://tachi.test',
      'vbookUrl': 'http://vbook.test',
    });
  });

  for (final size in const [Size(320, 568), Size(430, 932)]) {
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
    'both engines merge by language and repository action uses chosen engine',
    (tester) async {
      final prefs = await SharedPreferences.getInstance();
      final posts = <http.Request>[];
      final repo = SourceRepository(
        tachimangaUrl: 'http://tachi.test',
        vbookUrl: 'http://vbook.test',
        client: MockClient((request) async {
          if (request.method == 'POST') {
            posts.add(request);
            return http.Response('{}', 200);
          }
          if (request.url.path.contains('extension')) {
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
      final router = await mountBrowse(tester, prefs, repo);
      expect(find.text('Novel source'), findsOneWidget);
      expect(find.text('Manga source'), findsOneWidget);
      expect(find.byTooltip('Cấu hình Novel source'), findsNothing);
      expect(find.byTooltip('Cấu hình Manga source'), findsOneWidget);
      await tester.tap(find.text('Phần mở rộng'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Thêm repository hoặc extension'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('vBook').last);
      await tester.pumpAndSettle();
      expect(find.text('Thêm extension vBook'), findsOneWidget);
      await tester.enterText(
        find.byType(TextField),
        'https://packages.test/registry.json',
      );
      await tester.tap(find.text('Thêm'));
      await tester.pumpAndSettle();
      expect(posts.length, 1);
      expect(posts.single.url.toString(), 'http://vbook.test/v1/repositories');
      expect(jsonDecode(posts.single.body), {
        'url': 'https://packages.test/registry.json',
      });
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
      await tester.tap(find.text('Di chuyển'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Chuyển nguồn tự động chưa được hỗ trợ.'),
        findsOneWidget,
      );
      expect(find.text('Online book'), findsOneWidget);
      expect(find.text('Local book'), findsNothing);
      await tester.tap(find.text('Online book'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Tìm ở nguồn khác'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Chưa có nguồn khác phù hợp.'),
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

Future<GoRouter> mountBrowse(
  WidgetTester tester,
  SharedPreferences prefs,
  SourceRepository repo, {
  MemoryLibraryRepository? library,
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
