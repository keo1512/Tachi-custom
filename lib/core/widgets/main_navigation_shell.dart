import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../platform/native_tabs.dart';
import '../theme/app_theme.dart';

class MainNavigationShell extends StatelessWidget {
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
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: tabs,
    builder: (context, _) {
      final selected = mainTabRoutes.indexOf(path).clamp(0, 5);
      return Scaffold(
        body: SafeArea(top: false, bottom: false, child: child),
        // Product iOS always uses the native UIKit bar. Test hosts have no UIKit.
        bottomNavigationBar: tabs.enabled
            ? (tabs.error == null ? null : SafeArea(child: Text(tabs.error!)))
            : CupertinoTabBar(
                key: const ValueKey('host-test-navigation'),
                currentIndex: selected,
                onTap: (index) => context.go(mainTabRoutes[index]),
                activeColor: accent,
                items: [
                  for (var i = 0; i < mainTabLabels.length; i++)
                    BottomNavigationBarItem(
                      icon: Icon(icons[i]),
                      label: mainTabLabels[i],
                    ),
                ],
              ),
      );
    },
  );
}
