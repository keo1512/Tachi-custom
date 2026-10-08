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
  static const labels = ['Thư viện', 'Cập nhật', 'Duyệt', 'Lịch sử', 'Thêm'];
  static const icons = [
    CupertinoIcons.book,
    CupertinoIcons.arrow_down_circle,
    CupertinoIcons.compass,
    CupertinoIcons.clock,
    CupertinoIcons.ellipsis,
  ];
  static const selectedIcons = [
    CupertinoIcons.book_fill,
    CupertinoIcons.arrow_down_circle_fill,
    CupertinoIcons.compass_fill,
    CupertinoIcons.clock_fill,
    CupertinoIcons.ellipsis,
  ];
  @override
  Widget build(BuildContext context) {
    final selected = routes.indexOf(path).clamp(0, 4);
    final dark = Theme.of(context).brightness == Brightness.dark;
    final navigationColor = dark
        ? const Color(0xFF151517)
        : const Color(0xFFFAFAFC);
    if (MediaQuery.sizeOf(context).shortestSide >= 600) {
      return Scaffold(
        body: Row(
          children: [
            Semantics(
              label: 'Điều hướng chính',
              child: Container(
                key: const ValueKey('tablet-navigation'),
                width: 56,
                color: navigationColor,
                child: SafeArea(
                  right: false,
                  child: Column(
                    children: [
                      const SizedBox(height: 44),
                      for (var i = 0; i < routes.length; i++)
                        Semantics(
                          selected: selected == i,
                          button: true,
                          child: InkWell(
                            onTap: () => context.go(routes[i]),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(vertical: 9),
                              child: Column(
                                children: [
                                  Icon(
                                    selected == i ? selectedIcons[i] : icons[i],
                                    size: 21,
                                    color: selected == i ? accent : Colors.grey,
                                  ),
                                  const SizedBox(height: 3),
                                  Text(
                                    labels[i],
                                    maxLines: 1,
                                    style: TextStyle(
                                      fontSize: 9,
                                      color: selected == i
                                          ? accent
                                          : Colors.grey,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
            const VerticalDivider(width: .5, thickness: .5),
            Expanded(child: child),
          ],
        ),
      );
    }
    return Scaffold(
      body: SafeArea(top: false, bottom: false, child: child),
      bottomNavigationBar: SafeArea(
        top: false,
        bottom: false,
        child: CupertinoTabBar(
          currentIndex: selected,
          onTap: (i) => context.go(routes[i]),
          height: 49,
          iconSize: 23,
          activeColor: accent,
          inactiveColor: const Color(0xFF85858B),
          backgroundColor: navigationColor,
          border: Border(
            top: BorderSide(
              color: dark ? Colors.white12 : const Color(0xFFE5E5EA),
              width: .5,
            ),
          ),
          items: [
            for (var i = 0; i < routes.length; i++)
              BottomNavigationBarItem(
                icon: Icon(icons[i]),
                activeIcon: Icon(selectedIcons[i]),
                label: labels[i],
              ),
          ],
        ),
      ),
    );
  }
}
