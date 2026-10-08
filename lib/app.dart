import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'core/theme/app_theme.dart';
import 'core/platform/native_tabs.dart';
import 'core/widgets/main_navigation_shell.dart';
import 'features/downloads/presentation/downloads_screen.dart';
import 'features/library/presentation/library_screen.dart';
import 'features/library/presentation/book_detail_screen.dart';
import 'features/library/presentation/activity_screens.dart';
import 'features/reader/presentation/reader_screen.dart';
import 'features/settings/settings_controller.dart';
import 'features/settings/presentation/more_screen.dart';
import 'features/sources/domain/catalogue.dart';
import 'features/sources/presentation/browse_screen.dart';
import 'features/sources/presentation/source_search_screen.dart';

GoRouter createRouter({
  required NativeTabs tabs,
  required VoidCallback onNavigation,
}) => GoRouter(
  observers: [
    NativeTabsRouteObserver(
      onRouteChanged: (name) {
        tabs.rootRoute = name;
        onNavigation();
      },
    ),
  ],
  routes: [
    ShellRoute(
      notifyRootObserver: false,
      observers: [
        NativeTabsRouteObserver(
          onRouteChanged: (name) {
            tabs.shellRoute = name;
            onNavigation();
          },
        ),
      ],
      pageBuilder: (context, state, child) => NoTransitionPage(
        key: state.pageKey,
        name: 'main-shell',
        child: MainNavigationShell(
          path: state.uri.path,
          tabs: tabs,
          child: child,
        ),
      ),
      routes: [
        GoRoute(
          name: 'library',
          path: '/',
          builder: (_, _) => const LibraryScreen(),
        ),
        GoRoute(
          name: 'updates',
          path: '/updates',
          builder: (_, _) => const UpdatesScreen(),
        ),
        GoRoute(
          name: 'browse',
          path: '/browse',
          builder: (_, _) => const BrowseScreen(),
        ),
        GoRoute(
          name: 'downloads',
          path: '/downloads',
          builder: (_, _) => const DownloadsScreen(),
        ),
        GoRoute(
          name: 'history',
          path: '/history',
          builder: (_, _) => const HistoryScreen(),
        ),
        GoRoute(
          name: 'more',
          path: '/more',
          builder: (_, _) => const MoreScreen(),
        ),
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
  late final NativeTabs tabs = NativeTabs(
    onSelect: (index) => router.go(mainTabRoutes[index]),
  );
  late final GoRouter router = createRouter(
    tabs: tabs,
    onNavigation: scheduleNavigation,
  );
  bool navigationScheduled = false;

  @override
  void initState() {
    super.initState();
    tabs.initialize();
    router.routerDelegate.addListener(scheduleNavigation);
    scheduleNavigation();
  }

  void scheduleNavigation() {
    if (navigationScheduled || !mounted) return;
    navigationScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      navigationScheduled = false;
      if (mounted) {
        tabs.update(
          path: router.routeInformationProvider.value.uri.path,
          dark: ref.read(settingsProvider).dark,
        );
      }
    });
  }

  @override
  void dispose() {
    router.routerDelegate.removeListener(scheduleNavigation);
    tabs.dispose();
    router.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final dark = ref.watch(settingsProvider).dark;
    scheduleNavigation();
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
