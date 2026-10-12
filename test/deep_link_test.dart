import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tachi_books/features/deep_links/application/deep_link_queue.dart';
import 'package:tachi_books/features/deep_links/data/deep_link_platform.dart';
import 'package:tachi_books/features/deep_links/domain/app_deep_link.dart';
import 'package:tachi_books/features/deep_links/presentation/deep_link_gate.dart';
import 'package:tachi_books/features/library/data/library_repository.dart';
import 'package:tachi_books/features/library/data/coordinated_preferences.dart';
import 'package:tachi_books/features/library/domain/library_book.dart';
import 'package:tachi_books/features/library/presentation/library_view_model.dart';
import 'package:tachi_books/features/library/presentation/book_detail_screen.dart';
import 'package:tachi_books/features/privacy/application/app_lock_controller.dart';
import 'package:tachi_books/features/settings/settings_controller.dart';
import 'package:tachi_books/features/sources/data/extension_index.dart';
import 'package:tachi_books/features/sources/domain/catalogue.dart';
import 'package:tachi_books/features/sources/presentation/extension_catalogue_controller.dart';

class _Links implements DeepLinkPlatform {
  final events = StreamController<String>.broadcast(sync: true);
  List<String> initial = [];
  @override
  Stream<String> get links => events.stream;
  @override
  Future<List<String>> ready() async => initial;
  @override
  void dispose() {
    events.close();
  }
}

class _Lock extends AppLockController {
  @override
  AppLockState build() => const AppLockState(initialized: false, locked: true);
  void open() => state = const AppLockState(initialized: true);
  void close() => state = const AppLockState(initialized: true, locked: true);
}

http.Response catalogue() => http.Response(
  jsonEncode({
    'data': [
      {'name': 'Fixture', 'path': 'plugin.zip', 'version': 1},
    ],
  }),
  200,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'parser restricts actions and preserves large IDs and stable chapter URLs',
    () {
      final link = AppDeepLink.parse(
        'tachibooks://read/9223372036854775807?chapterId=%2Fchap%2F28',
      ) as LibraryDeepLink;
      expect(link.bookId, '9223372036854775807');
      expect(link.chapterId, '/chap/28');
      final repo = AppDeepLink.parse(
        Uri(
          scheme: 'tachibooks',
          host: 'repository',
          queryParameters: {
            'engine': 'tachimanga',
            'url': 'https://github.com/keiyoushi/extensions',
          },
        ).toString(),
      ) as RepositoryDeepLink;
      expect(
        repo.url,
        'https://raw.githubusercontent.com/keiyoushi/extensions/repo/index.pb',
      );
      expect(
        AppDeepLink.parse('com.googleusercontent.apps.client:/oauth'),
        isNull,
      );
      expect(AppDeepLink.parse('https://truyen.test/chapter'), isNull);
      for (final value in [
        'tachibooks://tasks/read',
        'tachibooks://tasks/downloads?url=https://private.test',
        'tachibooks://tasks/downloads?',
        'tachibooks://tasks/downloads/extra',
        'tachibooks://tasks/private/../downloads',
        'tachibooks://tasks/%64ownloads',
        'tachibooks://install/https://repo.test/a.apk',
        'tachibooks://book/a/b',
        'tachibooks://book/',
        'tachibooks://book/a%GG',
        'tachibooks://book/a%2',
        'tachibooks://read/id?chapter=1',
        'tachibooks://read/id?chapterId=a&chapterId=b',
        'tachibooks://book/id#read',
        'tachibooks://read/id?chapterId=',
        'tachibooks://repository?engine=tachimanga&url=file%3A%2F%2F%2Fprivate',
        'tachibooks://repository?engine=vbook&url=https%3A%2F%2Fuser%3Apass%40example.com',
        'tachibooks://repository?engine=invalid&url=https%3A%2F%2Frepo.test',
      ]) {
        expect(
          () => AppDeepLink.parse(value),
          throwsFormatException,
          reason: value,
        );
      }
    },
  );
  test('opaque library IDs roundtrip as one canonical encoded segment', () {
    for (final id in [
      'Tiếng Việt 📚',
      ' leading and trailing ',
      'truyện/nguồn/123',
      '/bad',
      '.',
      '..',
      'literal%2Fid?#value',
      List.filled(1000, 'a').join(),
    ]) {
      for (final reader in [false, true]) {
        final generated = LibraryDeepLink(
          id,
          reader: reader,
          chapterId: reader ? '/chương 28/📖' : null,
        ).identity;
        final parsed = AppDeepLink.parse(generated)! as LibraryDeepLink;
        expect(parsed.bookId, id, reason: generated);
        expect(parsed.reader, reader);
        expect(parsed.chapterId, reader ? '/chương 28/📖' : null);
        expect(parsed.identity, generated);
        expect(generated, isNot(contains(' ')));
      }
    }
  });
  test('URL bounds match the native inbox and reject unusable generated links', () {
    const prefix = 'tachibooks://book/';
    final exactId = List.filled(
      AppDeepLink.maxUrlBytes - prefix.length,
      'a',
    ).join();
    final exact = LibraryDeepLink(exactId).identity;
    expect(utf8.encode(exact).length, AppDeepLink.maxUrlBytes);
    expect((AppDeepLink.parse(exact)! as LibraryDeepLink).bookId, exactId);
    expect(
      () => LibraryDeepLink('${exactId}a').identity,
      throwsFormatException,
    );
    expect(() => AppDeepLink.parse('${exact}a'), throwsFormatException);
    final unicode = List.filled(1000, 'ệ').join();
    // Raw input fits in 8 KiB, but the canonical URL delivered by iOS does not.
    expect(() => LibraryDeepLink(unicode).identity, throwsFormatException);
    expect(() => AppDeepLink.parse('$prefix$unicode'), throwsFormatException);
    expect(() => const LibraryDeepLink('').identity, throwsFormatException);
    expect(
      () => const LibraryDeepLink('id', chapterId: 'chapter').identity,
      throwsFormatException,
    );
    expect(
      () => const LibraryDeepLink('id', reader: true, chapterId: '').identity,
      throwsFormatException,
    );
  });
  test('queue deduplicates initial/warm callbacks, stays bounded and resolves current TOC identities', () async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    final repo = MemoryLibraryRepository();
    await repo.save(
      LibraryBook(
        id: 'large',
        title: 'Fixture',
        currentChapter: 1,
        chapters: const [
          BookChapter(id: '/c/2', title: 'Second', index: 0),
          BookChapter(id: '/c/1', title: 'First', index: 1),
        ],
      ),
    );
    var time = DateTime(2026, 10, 11);
    final queue = DeepLinkQueue(now: () => time);
    final request = PendingDeepLink(
      const LibraryDeepLink('large', reader: true, chapterId: '/c/1'),
      repo,
      preferences,
    );
    expect(queue.add(request), isTrue);
    expect(queue.add(request), isFalse);
    final first = queue.take()!;
    expect(await first.libraryRoute(), '/read/large?chapterId=%2Fc%2F1');
    time = time.add(const Duration(seconds: 3));
    expect(queue.add(request), isFalse); // Still being handled.
    queue.finish(first);
    expect(queue.add(request), isTrue);
    for (var i = 0; i < 30; i++) {
      queue.add(PendingDeepLink(LibraryDeepLink('book$i'), repo, preferences));
    }
    expect(queue.length, 16);
    await repo.clear();
    expect(first.current, isFalse);
    await expectLater(first.libraryRoute(), throwsFormatException);
    final missing = PendingDeepLink(
      const LibraryDeepLink('absent'),
      repo,
      preferences,
    );
    await expectLater(missing.libraryRoute(), throwsFormatException);
    expect(await repo.list(), isEmpty);
  });
  test('reviewed repository write queued behind another operation refuses a library-only restore', () async {
    SharedPreferences.setMockInitialValues({});
    final raw = await SharedPreferences.getInstance();
    final repo = MemoryLibraryRepository();
    final preferences = await CoordinatedPreferences.open(raw, repo);
    final entered = Completer<void>(), release = Completer<void>();
    final holding = preferences.exclusive(() async {
      entered.complete();
      await release.future;
    });
    await entered.future;
    final container = ProviderContainer(
      overrides: [
        preferencesProvider.overrideWithValue(preferences),
        extensionIndexRepositoryProvider.overrideWithValue(
          ExtensionIndexRepository(MockClient((_) async => catalogue())),
        ),
      ],
    );
    addTearDown(container.dispose);
    await container.read(extensionCatalogueProvider.future);
    final request = PendingDeepLink(
      const RepositoryDeepLink(
        SourceEngine.vbook,
        'https://repo.test/plugin.json',
      ),
      repo,
      preferences,
    );
    final result = container
        .read(extensionCatalogueProvider.notifier)
        .add(
          SourceEngine.vbook,
          'https://repo.test/plugin.json',
          isCurrent: () => request.current,
        );
    final rejected = expectLater(result, throwsA(isA<StateError>()));
    await Future<void>.delayed(Duration.zero);
    await repo.clear();
    release.complete();
    await holding;
    await rejected;
    expect(
      preferences.getString(ExtensionCatalogueController.preferenceKey),
      isNull,
    );
    expect(await container.read(extensionCatalogueProvider.future), isEmpty);
  });

  Future<
    ({
      ProviderContainer container,
      GoRouter router,
      _Links links,
      MemoryLibraryRepository repo,
    })
  >
  mount(
    WidgetTester tester, {
    List<String> initial = const [],
    http.Client? client,
    bool unlock = true,
    String bookId = 'known',
    bool showBookDetail = false,
  }) async {
    SharedPreferences.setMockInitialValues({});
    final raw = await SharedPreferences.getInstance();
    final links = _Links()..initial = initial;
    final repo = MemoryLibraryRepository();
    final preferences = await CoordinatedPreferences.open(raw, repo);
    await repo.save(
      LibraryBook(
        id: bookId,
        title: 'Fixture',
        chapters: const [BookChapter(id: '/c/28', title: 'Chapter', index: 0)],
      ),
    );
    final container = ProviderContainer(
      overrides: [
        preferencesProvider.overrideWithValue(preferences),
        libraryRepositoryProvider.overrideWithValue(repo),
        deepLinkPlatformProvider.overrideWithValue(links),
        appLockProvider.overrideWith(_Lock.new),
        if (client != null)
          extensionIndexRepositoryProvider.overrideWithValue(
            ExtensionIndexRepository(client),
          ),
      ],
    );
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (_, _) => const Scaffold(body: Text('Home')),
        ),
        GoRoute(
          path: '/book/:id',
          builder: (_, s) => showBookDetail
              ? BookDetailScreen(id: s.pathParameters['id']!)
              : Scaffold(body: Text('Book ${s.pathParameters['id']}')),
        ),
        GoRoute(
          path: '/read/:id',
          builder: (_, s) => Scaffold(body: Text('Reader ${s.uri}')),
        ),
        GoRoute(
          path: '/repositories',
          builder: (_, _) => const Scaffold(body: Text('Repositories')),
        ),
        GoRoute(
          path: '/downloads',
          builder: (_, _) => const Scaffold(body: Text('Downloads')),
        ),
        GoRoute(
          path: '/updates',
          builder: (_, _) => const Scaffold(body: Text('Updates')),
        ),
      ],
    );
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(
          routerConfig: router,
          builder: (_, child) => DeepLinkGate(router: router, child: child!),
        ),
      ),
    );
    if (unlock) (container.read(appLockProvider.notifier) as _Lock).open();
    await tester.pumpAndSettle();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      router.dispose();
      container.dispose();
      links.dispose();
      client?.close();
    });
    return (container: container, router: router, links: links, repo: repo);
  }

  for (final tab in ['downloads', 'updates']) {
    testWidgets(
      'numeric task notification $tab waits for app unlock and only opens its allowed tab',
      (tester) async {
        var requests = 0;
        final identity = TaskDeepLink(tab).identity;
        expect(AppDeepLink.parse(identity), isA<TaskDeepLink>());
        final h = await mount(
          tester,
          unlock: false,
          initial: [identity],
          client: MockClient((_) async {
            requests++;
            return catalogue();
          }),
        );
        expect(find.text('Home'), findsOneWidget);
        h.links.events.add(identity);
        await tester.pumpAndSettle();
        expect(h.router.state.uri.path, '/');
        (h.container.read(appLockProvider.notifier) as _Lock).open();
        await tester.pumpAndSettle();
        expect(h.router.state.uri.path, '/$tab');
        expect(h.router.canPop(), false);
        expect(requests, 0);
        expect((await h.repo.list()).single.title, 'Fixture');
      },
    );
  }

  test('programmatic task links reject arbitrary routes too', () {
    expect(
      () => const TaskDeepLink('../book/private').identity,
      throwsFormatException,
    );
    expect(() => const TaskDeepLink('/downloads').route, throwsFormatException);
  });

  String repositoryLink() => RepositoryDeepLink(
    SourceEngine.vbook,
    'https://repo.test/plugin.json',
  ).identity;

  for (final reading in [false, true]) {
    testWidgets(
      'copy button clipboard roundtrip preserves Unicode space slash ID reading=$reading',
      (tester) async {
        String? copied;
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          (call) async {
            if (call.method == 'Clipboard.setData') {
              copied = (call.arguments as Map)['text'] as String;
            }
            if (call.method == 'Clipboard.getData') return {'text': copied};
            return null;
          },
        );
        addTearDown(
          () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            SystemChannels.platform,
            null,
          ),
        );
        const id = 'Truyện chữ / tác giả 📚';
        final h = await mount(tester, bookId: id, showBookDetail: true);
        h.router.push('/book/${Uri.encodeComponent(id)}');
        await tester.pumpAndSettle();
        final snapshot = (await h.repo.snapshot()).fingerprint;
        await tester.tap(find.byTooltip('Tùy chọn'));
        await tester.pumpAndSettle();
        final action = find.text(
          reading
              ? 'Sao chép liên kết chương đang đọc'
              : 'Sao chép liên kết TachiBooks',
        );
        await tester.ensureVisible(action);
        await tester.pumpAndSettle();
        await tester.tap(action);
        await tester.pumpAndSettle();
        final clipboard = await Clipboard.getData(Clipboard.kTextPlain);
        final link = AppDeepLink.parse(clipboard!.text!)! as LibraryDeepLink;
        expect(link.bookId, id);
        expect(link.reader, reading);
        expect(link.chapterId, reading ? '/c/28' : null);
        expect((await h.repo.snapshot()).fingerprint, snapshot);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'cold link waits for initialized unlock and duplicate callbacks do not stack routes',
    (tester) async {
      final h = await mount(
        tester,
        initial: ['tachibooks://book/known'],
        unlock: false,
      );
      expect(find.text('Home'), findsOneWidget);
      h.links.events.add('tachibooks://book/known');
      await tester.pumpAndSettle();
      expect(find.text('Book known'), findsNothing);
      (h.container.read(appLockProvider.notifier) as _Lock).open();
      await tester.pumpAndSettle();
      expect(find.text('Book known'), findsOneWidget);
      expect(h.router.canPop(), isTrue);
      h.router.pop();
      await tester.pumpAndSettle();
      expect(find.text('Home'), findsOneWidget);
      expect(h.router.canPop(), isFalse);
    },
  );
  testWidgets(
    'repository link only fetches after explicit preview confirmation, never installs package',
    (tester) async {
      var requests = 0;
      final h = await mount(
        tester,
        client: MockClient((_) async {
          requests++;
          return catalogue();
        }),
      );
      h.links.events.add(repositoryLink());
      h.links.events.add(repositoryLink());
      await tester.pumpAndSettle();
      expect(find.text('Thêm kho'), findsOneWidget);
      expect(requests, 0);
      await tester.tap(find.text('Hủy'));
      await tester.pumpAndSettle();
      expect(requests, 0);
      // Different canonical URL is a new action, without waiting for duplicate TTL.
      h.links.events.add(
        RepositoryDeepLink(
          SourceEngine.vbook,
          'https://repo.test/other.json',
        ).identity,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Thêm kho'));
      await tester.pumpAndSettle();
      expect(requests, 1);
      // The downloaded stream and SharedPreferences platform write finish
      // outside the widget test's fake clock.
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pumpAndSettle();
      expect(find.text('Repositories'), findsOneWidget);
      final saved = await h.container.read(extensionCatalogueProvider.future);
      expect(saved.single.entries.single.installed, isFalse);
    },
  );
  testWidgets(
    'restore or a lock cycle invalidates an open repository preview',
    (tester) async {
      var requests = 0;
      final h = await mount(
        tester,
        client: MockClient((_) async {
          requests++;
          return catalogue();
        }),
      );
      h.links.events.add(repositoryLink());
      await tester.pumpAndSettle();
      await h.repo.clear();
      await tester.tap(find.text('Thêm kho'));
      await tester.pumpAndSettle();
      expect(requests, 0);
      expect(
        h.container
            .read(preferencesProvider)
            .getString(ExtensionCatalogueController.preferenceKey),
        isNull,
      );
      h.links.events.add(
        RepositoryDeepLink(
          SourceEngine.vbook,
          'https://repo.test/locked.json',
        ).identity,
      );
      await tester.pumpAndSettle();
      final lock = h.container.read(appLockProvider.notifier) as _Lock;
      lock.close();
      await tester.pump();
      lock.open();
      await tester.pump();
      await tester.tap(find.text('Thêm kho'));
      await tester.pumpAndSettle();
      expect(requests, 0);
    },
  );
  testWidgets(
    'restore during repository download does not persist fetched catalogue',
    (tester) async {
      final response = Completer<http.Response>();
      final h = await mount(tester, client: MockClient((_) => response.future));
      h.links.events.add(repositoryLink());
      await tester.pumpAndSettle();
      await tester.tap(find.text('Thêm kho'));
      await tester.pump();
      await h.repo.clear();
      response.complete(catalogue());
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pumpAndSettle();
      expect(
        h.container
            .read(preferencesProvider)
            .getString(ExtensionCatalogueController.preferenceKey),
        isNull,
      );
      expect(h.router.routeInformationProvider.value.uri.path, '/');
    },
  );
}
