import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'core/theme/app_theme.dart';
import 'features/library/presentation/library_screen.dart';
import 'features/library/presentation/book_detail_screen.dart';
import 'features/library/presentation/activity_screens.dart';
import 'features/reader/presentation/reader_screen.dart';
import 'features/settings/settings_controller.dart';
import 'features/settings/presentation/more_screen.dart';
import 'features/sources/domain/catalogue.dart';
import 'features/sources/presentation/browse_screen.dart';
import 'features/sources/presentation/source_search_screen.dart';

GoRouter createRouter() => GoRouter(
  routes: [
    ShellRoute(
      builder: (context, state, child) =>
          _Shell(path: state.uri.path, child: child),
      routes: [
        GoRoute(path: '/', builder: (_, _) => const LibraryScreen()),
        GoRoute(path: '/updates', builder: (_, _) => const UpdatesScreen()),
        GoRoute(path: '/browse', builder: (_, _) => const BrowseScreen()),
        GoRoute(path: '/history', builder: (_, _) => const HistoryScreen()),
        GoRoute(path: '/more', builder: (_, _) => const MoreScreen()),
      ],
    ),
    GoRoute(
      path: '/book/:id',
      builder: (_, s) => BookDetailScreen(id: s.pathParameters['id']!),
    ),
    GoRoute(
      path: '/read/:id',
      builder: (_, s) => ReaderScreen(
        id: s.pathParameters['id']!,
        chapter: int.tryParse(s.uri.queryParameters['chapter'] ?? '0') ?? 0,
      ),
    ),
    GoRoute(
      path: '/source',
      builder: (context, s) => s.extra is CatalogueSource
          ? SourceSearchScreen(source: s.extra! as CatalogueSource)
          : Scaffold(
              appBar: AppBar(),
              body: const Center(child: Text('Mở nguồn từ tab Duyệt')),
            ),
    ),
  ],
);

class TachiBooksApp extends ConsumerStatefulWidget {
  const TachiBooksApp({super.key});
  @override
  ConsumerState<TachiBooksApp> createState() => _AppState();
}

class _AppState extends ConsumerState<TachiBooksApp> {
  late final GoRouter router = createRouter();
  @override
  void dispose() {
    router.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final dark = ref.watch(settingsProvider).dark;
    return MaterialApp.router(
      title: 'TachiBooks',
      debugShowCheckedModeBanner: false,
      theme: appTheme(Brightness.light),
      darkTheme: appTheme(Brightness.dark),
      themeMode: dark ? ThemeMode.dark : ThemeMode.light,
      routerConfig: router,
    );
  }
}

class _Shell extends StatelessWidget {
  const _Shell({required this.path, required this.child});
  final String path;
  final Widget child;
  static const routes = ['/', '/updates', '/browse', '/history', '/more'];
  @override
  Widget build(BuildContext context) => Scaffold(
    body: child,
    bottomNavigationBar: NavigationBar(
      selectedIndex: routes.indexOf(path).clamp(0, 4),
      onDestinationSelected: (i) => context.go(routes[i]),
      destinations: const [
        NavigationDestination(
          icon: Icon(CupertinoIcons.book),
          selectedIcon: Icon(CupertinoIcons.book_fill),
          label: 'Thư viện',
        ),
        NavigationDestination(
          icon: Icon(CupertinoIcons.arrow_down_circle),
          selectedIcon: Icon(CupertinoIcons.arrow_down_circle_fill),
          label: 'Cập nhật',
        ),
        NavigationDestination(
          icon: Icon(CupertinoIcons.compass),
          selectedIcon: Icon(CupertinoIcons.compass_fill),
          label: 'Duyệt',
        ),
        NavigationDestination(
          icon: Icon(CupertinoIcons.clock),
          selectedIcon: Icon(CupertinoIcons.clock_fill),
          label: 'Lịch sử',
        ),
        NavigationDestination(
          icon: Icon(CupertinoIcons.ellipsis_circle),
          selectedIcon: Icon(CupertinoIcons.ellipsis_circle_fill),
          label: 'Thêm',
        ),
      ],
    ),
  );
}
