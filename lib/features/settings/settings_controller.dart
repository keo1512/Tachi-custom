import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../library/data/coordinated_preferences.dart';

final preferencesProvider = Provider<SharedPreferences>(
  (ref) => throw StateError('Preferences not initialized'),
);
final settingsProvider = NotifierProvider<SettingsController, AppSettings>(
  SettingsController.new,
);

class AppSettings {
  const AppSettings({
    this.dark = true,
    this.appearance = 'dark',
    this.incognitoMode = false,
    this.libraryColumns = 5,
    this.downloadConcurrency = 2,
    this.pinnedSources = const [],
    this.recentSources = const [],
    this.fontSize = 20,
    this.lineHeight = 1.7,
    this.readerTheme = 'system',
    this.font = 'NotoSerif',
    this.mangaMode = 'vertical',
    this.tachimangaUrl = '',
    this.vbookUrl = '',
  });
  final bool dark, incognitoMode;
  final int libraryColumns, downloadConcurrency;
  final List<String> pinnedSources, recentSources;
  final double fontSize, lineHeight;
  final String readerTheme,
      font,
      mangaMode,
      tachimangaUrl,
      vbookUrl,
      appearance;
}

class SettingsController extends Notifier<AppSettings> {
  Future<void> _sourcePinWrites = Future<void>.value();
  Future<void> _sourceRecentWrites = Future<void>.value();
  int _privacyGeneration = 0;

  Future<void> _changeSourcePins(
    List<String> Function(List<String>) transform,
  ) {
    final p = ref.read(preferencesProvider);
    final generation = p is CoordinatedPreferences
        ? p.mutationGeneration
        : null;
    final operation = _sourcePinWrites.then((_) async {
      if (!ref.mounted ||
          (p is CoordinatedPreferences && p.mutationGeneration != generation)) {
        throw StateError('Thiết lập đã khôi phục. Hãy mở lại danh sách nguồn.');
      }
      final saved = await p.setStringList(
        'pinnedSources',
        transform([...?p.getStringList('pinnedSources')]),
      );
      if (!saved) throw StateError('Không lưu được thứ tự nguồn đã ghim.');
      if (ref.mounted) ref.invalidateSelf();
    });
    _sourcePinWrites = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return operation;
  }

  @override
  AppSettings build() {
    final p = ref.watch(preferencesProvider);
    return AppSettings(
      dark: p.getBool('dark') ?? true,
      appearance:
          const [
            'light',
            'dark',
            'system',
          ].contains(p.getString('appearanceV1'))
          ? p.getString('appearanceV1')!
          : (p.getBool('dark') ?? true)
          ? 'dark'
          : 'light',
      incognitoMode: p.getBool('incognitoMode') ?? false,
      libraryColumns: (p.getInt('libraryColumns') ?? 5).clamp(2, 8),
      downloadConcurrency: (p.getInt('downloadConcurrency') ?? 2).clamp(1, 4),
      pinnedSources: List.unmodifiable(p.getStringList('pinnedSources') ?? []),
      recentSources: List.unmodifiable(p.getStringList('recentSources') ?? []),
      fontSize: p.getDouble('fontSize') ?? 20,
      lineHeight: p.getDouble('lineHeight') ?? 1.7,
      readerTheme: p.getString('readerTheme') ?? 'system',
      font: p.getString('font') ?? 'NotoSerif',
      mangaMode: p.getString('mangaMode') ?? 'vertical',
      tachimangaUrl: p.getString('tachimangaUrl') ?? '',
      vbookUrl: p.getString('vbookUrl') ?? '',
    );
  }

  Future<void> update({
    bool? dark,
    String? appearance,
    bool? incognitoMode,
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
    if (appearance != null &&
        !const ['light', 'dark', 'system'].contains(appearance)) {
      throw const FormatException('Giao diện không hợp lệ.');
    }
    if (dark != null) {
      await p.setBool('dark', dark);
      await p.setString('appearanceV1', dark ? 'dark' : 'light');
    }
    if (appearance != null) {
      await p.setString('appearanceV1', appearance);
      if (appearance != 'system') await p.setBool('dark', appearance == 'dark');
    }
    if (incognitoMode != null) {
      _privacyGeneration++;
      final saved = await p.setBool('incognitoMode', incognitoMode);
      if (!saved) throw StateError('Không lưu được chế độ ẩn danh');
    }
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
    if (ref.mounted) ref.invalidateSelf();
  }

  Future<void> toggleSourcePin(String identity) => _changeSourcePins((pins) {
    if (!pins.remove(identity)) pins.add(identity);
    return pins;
  });

  Future<void> recordSourceUse(String identity) {
    final p = ref.read(preferencesProvider);
    if (p.getBool('incognitoMode') == true) return Future.value();
    final privacy = _privacyGeneration;
    final generation = p is CoordinatedPreferences
        ? p.mutationGeneration
        : null;
    final operation = _sourceRecentWrites.then((_) async {
      if (!ref.mounted ||
          privacy != _privacyGeneration ||
          p.getBool('incognitoMode') == true ||
          (p is CoordinatedPreferences && p.mutationGeneration != generation)) {
        return;
      }
      final recent = [...?p.getStringList('recentSources')]..remove(identity);
      recent.insert(0, identity);
      if (!await p.setStringList('recentSources', recent.take(8).toList())) {
        throw StateError('Không lưu được nguồn sử dụng gần nhất.');
      }
      if (ref.mounted) ref.invalidateSelf();
    });
    _sourceRecentWrites = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return operation;
  }

  Future<void> setPinnedSourceOrder(List<String> identities) =>
      _changeSourcePins((current) {
        final remaining = current.toSet();
        final ordered = <String>[];
        for (final id in identities) {
          if (remaining.remove(id)) ordered.add(id);
        }
        ordered.addAll(current.where(remaining.contains));
        return ordered;
      });
}
