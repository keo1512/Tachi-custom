import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

const accent = Color(0xFF007AFF);

ThemeData appTheme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  return ThemeData(
    platform: TargetPlatform.iOS,
    useMaterial3: true,
    brightness: brightness,
    colorScheme: ColorScheme.fromSeed(
      seedColor: accent,
      brightness: brightness,
    ).copyWith(primary: accent, onPrimary: Colors.white),
    scaffoldBackgroundColor: dark
        ? const Color(0xFF000000)
        : const Color(0xFFFBFBFD),
    appBarTheme: AppBarTheme(
      backgroundColor: dark ? const Color(0xFF000000) : const Color(0xFFFBFBFD),
      surfaceTintColor: Colors.transparent,
      centerTitle: true,
      toolbarHeight: 44,
      scrolledUnderElevation: 0,
      elevation: 0,
      iconTheme: IconThemeData(
        size: 21,
        color: dark ? Colors.white : const Color(0xFF343438),
      ),
      titleTextStyle: TextStyle(
        fontSize: 17,
        fontWeight: FontWeight.w600,
        color: dark ? Colors.white : const Color(0xFF171719),
      ),
    ),
    tabBarTheme: const TabBarThemeData(
      labelColor: accent,
      unselectedLabelColor: Colors.grey,
      indicatorColor: accent,
      indicatorSize: TabBarIndicatorSize.tab,
      dividerHeight: .5,
      labelStyle: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
    ),
    listTileTheme: const ListTileThemeData(
      minLeadingWidth: 24,
      horizontalTitleGap: 12,
      minVerticalPadding: 8,
      titleTextStyle: TextStyle(fontSize: 16),
    ),
    dividerTheme: DividerThemeData(
      color: dark ? Colors.white12 : const Color(0xFFE5E5EA),
      thickness: .5,
    ),
    navigationBarTheme: NavigationBarThemeData(
      height: 70,
      indicatorColor: Colors.transparent,
      backgroundColor: dark ? const Color(0xFF151517) : const Color(0xFFF9F9FB),
      labelTextStyle: WidgetStateProperty.resolveWith(
        (s) => TextStyle(
          fontSize: 10,
          color: s.contains(WidgetState.selected) ? accent : Colors.grey,
        ),
      ),
      iconTheme: WidgetStateProperty.resolveWith(
        (s) => IconThemeData(
          size: 24,
          color: s.contains(WidgetState.selected) ? accent : Colors.grey,
        ),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: dark ? const Color(0xFF1C1C1E) : const Color(0xFFF2F2F7),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(11),
        borderSide: BorderSide.none,
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
    ),
    cupertinoOverrideTheme: CupertinoThemeData(
      brightness: brightness,
      primaryColor: accent,
    ),
  );
}
