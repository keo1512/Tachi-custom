import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

final preferencesProvider = Provider<SharedPreferences>(
  (ref) => throw StateError('Preferences not initialized'),
);
final settingsProvider = NotifierProvider<SettingsController, AppSettings>(
  SettingsController.new,
);

class AppSettings {
  const AppSettings({
    this.dark = true,
    this.libraryColumns = 5,
    this.downloadConcurrency = 2,
    this.pinnedSources = const [],
    this.recentSources = const [],
    this.fontSize = 20,
    this.lineHeight = 1.7,
    this.readerTheme = 'paper',
    this.font = 'NotoSerif',
    this.mangaMode = 'vertical',
    this.tachimangaUrl = '',
    this.vbookUrl = '',
  });
  final bool dark;
  final int libraryColumns, downloadConcurrency;
  final List<String> pinnedSources, recentSources;
  final double fontSize, lineHeight;
  final String readerTheme, font, mangaMode, tachimangaUrl, vbookUrl;
}

class SettingsController extends Notifier<AppSettings> {
  @override
  AppSettings build() {
    final p = ref.watch(preferencesProvider);
    return AppSettings(
      dark: p.getBool('dark') ?? true,
      libraryColumns: (p.getInt('libraryColumns') ?? 5).clamp(2, 8),
      downloadConcurrency: (p.getInt('downloadConcurrency') ?? 2).clamp(1, 4),
      pinnedSources: List.unmodifiable(p.getStringList('pinnedSources') ?? []),
      recentSources: List.unmodifiable(p.getStringList('recentSources') ?? []),
      fontSize: p.getDouble('fontSize') ?? 20,
      lineHeight: p.getDouble('lineHeight') ?? 1.7,
      readerTheme: p.getString('readerTheme') ?? 'paper',
      font: p.getString('font') ?? 'NotoSerif',
      mangaMode: p.getString('mangaMode') ?? 'vertical',
      tachimangaUrl: p.getString('tachimangaUrl') ?? '',
      vbookUrl: p.getString('vbookUrl') ?? '',
    );
  }

  Future<void> update({
    bool? dark,
    int? libraryColumns,
    int? downloadConcurrency,
    double? fontSize,
    double? lineHeight,
    String? readerTheme,
    String? font,
    String? mangaMode,
    String? tachimangaUrl,
    String? vbookUrl,
  }) async {
    final p = ref.read(preferencesProvider);
    if (dark != null) await p.setBool('dark', dark);
    if (libraryColumns != null) {
      await p.setInt('libraryColumns', libraryColumns.clamp(2, 8));
    }
    if (downloadConcurrency != null) {
      await p.setInt('downloadConcurrency', downloadConcurrency.clamp(1, 4));
    }
    if (fontSize != null) await p.setDouble('fontSize', fontSize);
    if (lineHeight != null) await p.setDouble('lineHeight', lineHeight);
    if (readerTheme != null) await p.setString('readerTheme', readerTheme);
    if (font != null) await p.setString('font', font);
    if (mangaMode != null) await p.setString('mangaMode', mangaMode);
    if (tachimangaUrl != null) {
      await p.setString('tachimangaUrl', tachimangaUrl);
    }
    if (vbookUrl != null) await p.setString('vbookUrl', vbookUrl);
    ref.invalidateSelf();
  }

  Future<void> toggleSourcePin(String identity) async {
    final p = ref.read(preferencesProvider);
    final pins = [...?p.getStringList('pinnedSources')];
    if (!pins.remove(identity)) pins.add(identity);
    await p.setStringList('pinnedSources', pins);
    ref.invalidateSelf();
  }

  Future<void> recordSourceUse(String identity) async {
    final p = ref.read(preferencesProvider);
    final recent = [...?p.getStringList('recentSources')]..remove(identity);
    recent.insert(0, identity);
    await p.setStringList('recentSources', recent.take(8).toList());
    ref.invalidateSelf();
  }
}
