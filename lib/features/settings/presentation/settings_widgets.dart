import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

Color settingsLabel(BuildContext context) =>
    Theme.of(context).brightness == Brightness.dark
    ? const Color(0xFFBFC1CB)
    : const Color(0xFF46464E);

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key, required this.title, required this.children});
  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      toolbarHeight: 56,
      title: Text(title),
      titleTextStyle: TextStyle(
        color: settingsLabel(context),
        fontFamily: Theme.of(context).textTheme.titleLarge?.fontFamily,
        fontSize: 20,
        fontWeight: FontWeight.w400,
      ),
    ),
    body: SafeArea(
      top: false,
      child: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: ListView(
            padding: const EdgeInsets.only(top: 8, bottom: 24),
            children: children,
          ),
        ),
      ),
    ),
  );
}

class SettingsRow extends StatelessWidget {
  const SettingsRow({
    super.key,
    required this.title,
    this.icon,
    this.leading,
    this.subtitle,
    this.trailing,
    this.onTap,
    this.height = 56,
    this.showChevron = true,
  });
  final String title;
  final IconData? icon;
  final Widget? leading;
  final String? subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;
  final double height;
  final bool showChevron;

  @override
  Widget build(BuildContext context) {
    final color = settingsLabel(context);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: height),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            child: Row(
              children: [
                if (icon != null || leading != null) ...[
                  SizedBox(
                    width: 24,
                    child: leading ?? Icon(icon, color: color, size: 24),
                  ),
                  const SizedBox(width: 17),
                ],
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title, style: TextStyle(fontSize: 16, color: color)),
                      if (subtitle != null) ...[
                        const SizedBox(height: 4),
                        Text(
                          subtitle!,
                          style: TextStyle(
                            fontSize: 12,
                            height: 1.4,
                            color: color.withValues(alpha: .65),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                if (trailing != null) ...[
                  const SizedBox(width: 10),
                  trailing!,
                ] else if (onTap != null && showChevron) ...[
                  const SizedBox(width: 10),
                  Icon(
                    CupertinoIcons.chevron_right,
                    size: 15,
                    color: color.withValues(alpha: .45),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class SettingsNote extends StatelessWidget {
  const SettingsNote(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 10, 16, 18),
    child: Text(
      text,
      style: TextStyle(
        fontSize: 13,
        height: 1.5,
        color: settingsLabel(context).withValues(alpha: .7),
      ),
    ),
  );
}

class SettingsHeading extends StatelessWidget {
  const SettingsHeading(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 22, 16, 6),
    child: Text(
      text,
      style: TextStyle(
        fontSize: 13,
        color: settingsLabel(context).withValues(alpha: .65),
      ),
    ),
  );
}

Future<void> openSettingsPage(BuildContext context, Widget page) =>
    Navigator.of(context)
        .push<void>(CupertinoPageRoute<void>(builder: (_) => page));

class PremiumCrown extends StatelessWidget {
  const PremiumCrown({super.key});

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 24,
    height: 24,
    child: CustomPaint(painter: _CrownPainter(settingsLabel(context))),
  );
}

class _CrownPainter extends CustomPainter {
  const _CrownPainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(size.width / 24, size.height / 24);
    final paint = Paint()..color = color;
    final crown = Path()
      ..moveTo(2.5, 6.5)
      ..lineTo(7.3, 11)
      ..lineTo(12, 4.5)
      ..lineTo(16.7, 11)
      ..lineTo(21.5, 6.5)
      ..lineTo(19.5, 20)
      ..lineTo(4.5, 20)
      ..close();
    canvas.drawPath(crown, paint);
    for (final center in const [
      Offset(2.5, 6),
      Offset(12, 4),
      Offset(21.5, 6),
    ]) {
      canvas.drawCircle(center, 1.5, paint);
    }
  }

  @override
  bool shouldRepaint(_CrownPainter oldDelegate) => color != oldDelegate.color;
}
