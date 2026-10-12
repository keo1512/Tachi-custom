import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:go_router/go_router.dart';

import 'core/theme/app_theme.dart';
import 'core/diagnostics/diagnostic_listener.dart';
import 'core/platform/native_tabs.dart';
import 'core/widgets/main_navigation_shell.dart';
import 'features/downloads/presentation/downloads_screen.dart';
import 'features/library/presentation/library_screen.dart';
import 'features/library/presentation/book_detail_screen.dart';
import 'features/library/presentation/activity_screens.dart';
import 'features/reader/presentation/reader_screen.dart';
import 'features/tasks/application/task_lifecycle.dart';
import 'features/settings/settings_controller.dart';
import 'features/settings/navigation_preferences.dart';
import 'features/settings/presentation/more_screen.dart';
import 'features/sources/domain/catalogue.dart';
import 'features/sources/presentation/browse_screen.dart';
import 'features/sources/presentation/extension_repository_screen.dart';
import 'features/sources/presentation/source_search_screen.dart';
import 'features/sources/presentation/source_migration_screen.dart';
import 'features/sources/presentation/source_bulk_migration_screen.dart';
import 'features/sync/application/sync_lifecycle.dart';
import 'features/library/application/library_update_scheduler.dart';
import 'features/library/application/automatic_backup_controller.dart';
import 'features/library/application/extension_recovery_controller.dart';
import 'features/privacy/application/app_lock_controller.dart';
import 'features/privacy/presentation/privacy_gate.dart';
import 'features/deep_links/presentation/deep_link_gate.dart';
import 'features/deep_links/application/deep_link_queue.dart';

GoRouter createRouter({
  required NativeTabs tabs,
  required VoidCallback onNavigation,
  String initialLocation = '/',
}) => GoRouter(
  initialLocation: initialLocation,
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
      name: 'repositories',
      path: '/repositories',
      builder: (_, _) => const ExtensionRepositoryScreen(),
    ),
    GoRoute(
      path: '/book/:id',
      builder: (_, s) => BookDetailScreen(
        id: s.uri.queryParameters['bookId'] ?? s.pathParameters['id']!,
        expectedRevision: s.extra is LibraryLinkHandoff
            ? (s.extra! as LibraryLinkHandoff).expectedRevision
            : null,
      ),
    ),
    GoRoute(
      path: '/read/:id',
      builder: (_, s) => ReaderScreen(
        id: s.uri.queryParameters['bookId'] ?? s.pathParameters['id']!,
        chapter: int.tryParse(s.uri.queryParameters['chapter'] ?? '0') ?? 0,
        chapterId: s.uri.queryParameters['chapterId'],
        expectedRevision: s.extra is LibraryLinkHandoff
            ? (s.extra! as LibraryLinkHandoff).expectedRevision
            : null,
      ),
    ),
    GoRoute(
      path: '/migrate',
      builder: (context, state) {
        final value = state.extra;
        if (value is Map &&
            value['bookId'] is String &&
            value['source'] is CatalogueSource) {
          return SourceMigrationScreen(
            bookId: value['bookId'] as String,
            source: value['source'] as CatalogueSource,
            alternatives: value['sources'] is List
                ? (value['sources'] as List)
                      .whereType<CatalogueSource>()
                      .toList()
                : const [],
            selectionOnly: value['selectionOnly'] == true,
          );
        }
        return Scaffold(
          appBar: AppBar(),
          body: const Center(
            child: Text('Chọn truyện và nguồn mới từ mục Di chuyển.'),
          ),
        );
      },
    ),
    GoRoute(
      path: '/migrate-batch',
      builder: (context, state) => state.extra is List<CatalogueSource>
          ? BulkSourceMigrationScreen(
              sources: state.extra! as List<CatalogueSource>,
            )
          : Scaffold(
              appBar: AppBar(),
              body: const Center(
                child: Text('Mở chuyển nguồn hàng loạt từ tab Duyệt.'),
              ),
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

class _AppState extends ConsumerState<TachiBooksApp>
    with WidgetsBindingObserver {
  late final NativeTabs tabs = NativeTabs(
    onSelect: (index) => router.go(mainTabRoutes[index]),
  );
  late final GoRouter router = createRouter(
    tabs: tabs,
    onNavigation: scheduleNavigation,
    initialLocation: ref
        .read(navigationPreferencesProvider.notifier)
        .startRoute,
  );
  bool navigationScheduled = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
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
          dark: effectiveDark(ref.read(settingsProvider)),
          blocked:
              ref.read(appLockProvider).locked ||
              ref.read(appLockProvider).obscured,
          order: ref.read(navigationPreferencesProvider).order,
          showLabels: ref.read(navigationPreferencesProvider).showLabels,
        );
        unawaited(
          ref
              .read(navigationPreferencesProvider.notifier)
              .recordSelection(router.routeInformationProvider.value.uri.path)
              .catchError(
                (Object error) =>
                    debugPrint('Không lưu được tab gần nhất: $error'),
              ),
        );
      }
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    router.routerDelegate.removeListener(scheduleNavigation);
    tabs.dispose();
    router.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
    ref.watch(navigationPreferencesProvider);
    ref.watch(
      appLockProvider.select((state) => (state.locked, state.obscured)),
    );
    scheduleNavigation();
    return MaterialApp.router(
      title: 'TachiBooks',
      debugShowCheckedModeBanner: false,
      locale: const Locale('vi', 'VN'),
      supportedLocales: const [Locale('vi', 'VN')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      theme: appTheme(Brightness.light),
      darkTheme: appTheme(Brightness.dark),
      themeMode: switch (settings.appearance) {
        'system' => ThemeMode.system,
        'light' => ThemeMode.light,
        _ => ThemeMode.dark,
      },
      routerConfig: router,
      builder: (context, child) => PrivacyGate(
        child: DeepLinkGate(
          router: router,
          child: ExtensionRecoveryLifecycle(
            child: AutomaticBackupLifecycle(
              child: LibraryUpdateLifecycle(
                child: TaskLifecycle(
                  child: DiagnosticListener(
                    child: SyncLifecycle(
                      child: child ?? const SizedBox.shrink(),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  bool effectiveDark(AppSettings settings) => settings.appearance == 'system'
      ? WidgetsBinding.instance.platformDispatcher.platformBrightness ==
            Brightness.dark
      : settings.appearance != 'light';
  @override
  void didChangePlatformBrightness() {
    scheduleNavigation();
  }
}
