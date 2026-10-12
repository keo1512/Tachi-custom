import 'package:flutter/material.dart';

/// Additive reader preferences. Missing keys preserve the continuous reader.
class ReaderOptions {
  const ReaderOptions({
    this.margin = 0,
    this.gap = 0,
    this.brightness = 1,
    this.grayscale = false,
    this.inverted = false,
    this.showPageNumber = true,
    this.keepAwake = false,
    this.orientation = 'free',
    this.skipRead = false,
    this.skipDuplicates = false,
    this.tint = 0xffffffff,
    this.tintOpacity = 0,
    this.blend = 'multiply',
    this.zoom = true,
    this.autoScroll = false,
    this.autoScrollSpeed = 40,
    this.autoScrollMode = 'continuous',
    this.autoPageSeconds = 8,
    this.holdScroll = false,
    this.imageScale = 'width',
    this.tapZones = 'off',
    this.invertTapZones = false,
    this.orientationMargins = false,
    this.portraitLeft,
    this.portraitRight,
    this.landscapeLeft,
    this.landscapeRight,
    this.backgroundMode = 'system',
    this.backgroundColor = 0xff000000,
    this.fullScreen = false,
    this.hideStatusBar = false,
    this.disableBackSwipe = false,
  });
  final double margin,
      gap,
      brightness,
      tintOpacity,
      autoScrollSpeed,
      autoPageSeconds;
  final bool grayscale,
      inverted,
      showPageNumber,
      keepAwake,
      skipRead,
      skipDuplicates,
      zoom,
      autoScroll,
      holdScroll,
      invertTapZones,
      orientationMargins,
      fullScreen,
      hideStatusBar,
      disableBackSwipe;
  final double? portraitLeft, portraitRight, landscapeLeft, landscapeRight;
  final int tint, backgroundColor;
  final String orientation,
      blend,
      autoScrollMode,
      imageScale,
      tapZones,
      backgroundMode;

  factory ReaderOptions.fromJson(Map<String, dynamic> data) {
    double number(String key, double fallback, double min, double max) {
      final value = data[key];
      return value is num && value.isFinite
          ? value.toDouble().clamp(min, max)
          : fallback;
    }

    bool flag(String key, bool fallback) =>
        data[key] is bool ? data[key] as bool : fallback;
    String choice(String key, String fallback, List<String> choices) =>
        choices.contains(data[key]) ? data[key] as String : fallback;
    double? optionalMargin(String key) =>
        data[key] == null ? null : number(key, 0, 0, 64);
    return ReaderOptions(
      margin: number('margin', 0, 0, 64),
      gap: number('gap', 0, 0, 32),
      brightness: number('brightness', 1, .1, 1),
      grayscale: flag('grayscale', false),
      inverted: flag('inverted', false),
      showPageNumber: flag('showPageNumber', true),
      keepAwake: flag('keepAwake', false),
      zoom: flag('zoom', true),
      autoScroll: flag('autoScroll', false),
      autoScrollSpeed: number('autoScrollSpeed', 40, 10, 200),
      autoScrollMode: choice('autoScrollMode', 'continuous', [
        'continuous',
        'page',
      ]),
      autoPageSeconds: number('autoPageSeconds', 8, 2, 120),
      holdScroll: flag('holdScroll', false),
      imageScale: choice('imageScale', 'width', [
        'width',
        'height',
        'screen',
        'original',
      ]),
      tapZones: choice('tapZones', 'off', ['off', 'horizontal', 'vertical']),
      invertTapZones: flag('invertTapZones', false),
      orientationMargins: flag('orientationMargins', false),
      portraitLeft: optionalMargin('portraitLeft'),
      portraitRight: optionalMargin('portraitRight'),
      landscapeLeft: optionalMargin('landscapeLeft'),
      landscapeRight: optionalMargin('landscapeRight'),
      backgroundMode: choice('backgroundMode', 'system', [
        'system',
        'light',
        'dark',
        'custom',
      ]),
      backgroundColor: data['backgroundColor'] is int
          ? 0xff000000 |
                ((data['backgroundColor'] as int).clamp(0, 0xffffffff) &
                    0xffffff)
          : 0xff000000,
      fullScreen: flag('fullScreen', false),
      hideStatusBar: flag('hideStatusBar', false),
      disableBackSwipe: flag('disableBackSwipe', false),
      orientation: choice('orientation', 'free', [
        'free',
        'portrait',
        'landscape',
        'reversePortrait',
      ]),
      skipRead: flag('skipRead', false),
      skipDuplicates: flag('skipDuplicates', false),
      tint: data['tint'] is int
          ? (data['tint'] as int).clamp(0, 0xffffffff)
          : 0xffffffff,
      tintOpacity: number('tintOpacity', 0, 0, .8),
      blend: choice('blend', 'multiply', [
        'multiply',
        'screen',
        'overlay',
        'darken',
        'lighten',
      ]),
    );
  }
  Map<String, dynamic> toJson() => {
    'margin': margin,
    'gap': gap,
    'brightness': brightness,
    'grayscale': grayscale,
    'inverted': inverted,
    'showPageNumber': showPageNumber,
    'keepAwake': keepAwake,
    'orientation': orientation,
    'skipRead': skipRead,
    'skipDuplicates': skipDuplicates,
    'tint': tint,
    'tintOpacity': tintOpacity,
    'blend': blend,
    'zoom': zoom,
    'autoScroll': autoScroll,
    'autoScrollSpeed': autoScrollSpeed,
    'autoScrollMode': autoScrollMode,
    'autoPageSeconds': autoPageSeconds,
    'holdScroll': holdScroll,
    'imageScale': imageScale,
    'tapZones': tapZones,
    'invertTapZones': invertTapZones,
    'orientationMargins': orientationMargins,
    'portraitLeft': portraitLeft,
    'portraitRight': portraitRight,
    'landscapeLeft': landscapeLeft,
    'landscapeRight': landscapeRight,
    'backgroundMode': backgroundMode,
    'backgroundColor': backgroundColor,
    'fullScreen': fullScreen,
    'hideStatusBar': hideStatusBar,
    'disableBackSwipe': disableBackSwipe,
  };
  ReaderOptions patch(Map<String, dynamic> values) =>
      ReaderOptions.fromJson({...toJson(), ...values});

  EdgeInsets pageMargins(Orientation currentOrientation) {
    if (!orientationMargins) return EdgeInsets.symmetric(horizontal: margin);
    return currentOrientation == Orientation.portrait
        ? EdgeInsets.only(
            left: portraitLeft ?? margin,
            right: portraitRight ?? margin,
          )
        : EdgeInsets.only(
            left: landscapeLeft ?? margin,
            right: landscapeRight ?? margin,
          );
  }

  Color pageBackground(Color inherited) => switch (backgroundMode) {
    'light' => Colors.white,
    'dark' => Colors.black,
    'custom' => Color(backgroundColor),
    _ => inherited,
  };
  BlendMode get blendMode => switch (blend) {
    'screen' => BlendMode.screen,
    'overlay' => BlendMode.overlay,
    'darken' => BlendMode.darken,
    'lighten' => BlendMode.lighten,
    _ => BlendMode.multiply,
  };
  ColorFilter get imageFilter {
    final b = brightness, g = grayscale;
    final weights = g ? [.2126, .7152, .0722] : [0.0, 0.0, 0.0];
    final sign = inverted ? -1.0 : 1.0;
    final bias = inverted ? 255 * b : 0.0;
    final rows = <double>[];
    for (var i = 0; i < 3; i++) {
      rows.addAll([
        for (var j = 0; j < 3; j++)
          sign *
              b *
              (g
                  ? weights[j]
                  : i == j
                  ? 1.0
                  : 0.0),
        0,
        bias,
      ]);
    }
    rows.addAll([0, 0, 0, 1, 0]);
    return ColorFilter.matrix(rows);
  }
}
