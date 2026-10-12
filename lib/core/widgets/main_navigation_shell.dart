import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/settings/navigation_preferences.dart';
import '../../features/library/presentation/library_view_session.dart';

import '../platform/native_tabs.dart';
import '../theme/app_theme.dart';

class MainNavigationShell extends ConsumerWidget {
  const MainNavigationShell({
    super.key,
    required this.path,
    required this.tabs,
    required this.child,
  });
  final String path;
  final NativeTabs tabs;
  final Widget child;
  static const icons = [
    Icons.library_books,
    Icons.bolt,
    CupertinoIcons.compass,
    CupertinoIcons.arrow_down_circle,
    CupertinoIcons.clock_fill,
    Icons.settings,
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final preferences = ref.watch(navigationPreferencesProvider);
    return ListenableBuilder(
      listenable: tabs,
      builder: (context, _) {
        final selected = preferences.order
            .indexOf(mainTabRoutes.indexOf(path))
            .clamp(0, 5);
        return Scaffold(
        body: SafeArea(top: false, bottom: false,
          child: PageStorage(bucket: ref.watch(mainPageStorageProvider), child: child)),
          // Product iOS always uses the native UIKit bar. Test hosts have no UIKit.
          bottomNavigationBar: tabs.enabled
              ? (tabs.error == null ? null : SafeArea(child: Text(tabs.error!)))
              : CupertinoTabBar(
                  key: const ValueKey('host-test-navigation'),
                  currentIndex: selected,
                  onTap: (index) =>
                      context.go(mainTabRoutes[preferences.order[index]]),
                  activeColor: accent,
                  items: [
                    for (final i in preferences.order)
                      BottomNavigationBarItem(
                        icon: Icon(icons[i]),
                        label: preferences.showLabels ? mainTabLabels[i] : '',
                      ),
                  ],
                ),
        );
      },
    );
  }
}
