import 'package:flutter/material.dart';

/// Keeps the complete page in the continuous vertical document. Wide pages in
/// height/100% modes have their own horizontal scroll area, never cropped data.
/// This wrapper does not resolve an ImageProvider or retain decoded images.
class MangaPageLayout extends StatelessWidget {
  const MangaPageLayout({
    super.key,
    required this.mode,
    required this.viewportHeight,
    required this.image,
  });
  final String mode;
  final double viewportHeight;
  final Widget Function(double? width, double? height) image;

  @override
  Widget build(BuildContext context) {
    if (mode == 'original' || mode == 'height') {
      return Align(
        alignment: Alignment.topCenter,
        child: SingleChildScrollView(
          key: const ValueKey('manga-horizontal-page'),
          primary: false,
          scrollDirection: Axis.horizontal,
          child: image(null, mode == 'height' ? viewportHeight : null),
        ),
      );
    }
    if (mode == 'screen') {
      return ConstrainedBox(
        constraints: BoxConstraints(maxHeight: viewportHeight),
        child: image(double.infinity, null),
      );
    }
    return image(double.infinity, null);
  }
}
