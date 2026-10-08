import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../domain/catalogue.dart';

String sourceLanguage(String code) => switch (code.toLowerCase()) {
  'vi' => 'Tiếng Việt',
  'en' => 'English',
  'ja' => '日本語',
  'ko' => '한국어',
  'zh' => '中文',
  'all' || '' => 'Đa ngôn ngữ',
  _ => code.toUpperCase(),
};

String sourceEngineName(SourceEngine engine) =>
    engine == SourceEngine.tachimanga ? 'Tachimanga' : 'vBook';

class BrowseHeading extends StatelessWidget {
  const BrowseHeading(this.title, {super.key});
  final String title;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 22, 16, 13),
    child: Text(title, style: const TextStyle(fontSize: 16)),
  );
}

class SourceBrowseRow extends StatelessWidget {
  const SourceBrowseRow({
    super.key,
    required this.source,
    required this.pinned,
    required this.onOpen,
    required this.onPin,
    required this.onInfo,
    this.onPreferences,
  });
  final CatalogueSource source;
  final bool pinned;
  final VoidCallback onOpen, onPin, onInfo;
  final VoidCallback? onPreferences;

  @override
  Widget build(BuildContext context) {
    final gray = Theme.of(context).brightness == Brightness.dark
        ? const Color(0xFFBFC1CB)
        : const Color(0xFF46464E);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onOpen,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 14, 8, 14),
          child: Row(
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: gray.withValues(alpha: .12),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Icon(
                  source.kind == ContentKind.manga
                      ? CupertinoIcons.photo
                      : CupertinoIcons.book,
                  color: gray,
                  size: 22,
                ),
              ),
              const SizedBox(width: 20),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      source.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 16, color: gray),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      sourceLanguage(source.lang),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 13, color: gray),
                    ),
                  ],
                ),
              ),
              if (onPreferences != null)
                _SourceButton(
                  tooltip: 'Cấu hình ${source.name}',
                  icon: CupertinoIcons.gear_solid,
                  onPressed: onPreferences!,
                  color: gray,
                ),
              _SourceButton(
                tooltip: '${pinned ? 'Bỏ ghim' : 'Ghim'} ${source.name}',
                icon: pinned ? CupertinoIcons.pin_fill : CupertinoIcons.pin,
                onPressed: onPin,
                color: gray,
              ),
              _SourceButton(
                tooltip: 'Thông tin ${source.name}',
                icon: CupertinoIcons.info_circle,
                onPressed: onInfo,
                color: gray,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SourceButton extends StatelessWidget {
  const _SourceButton({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
    required this.color,
  });
  final String tooltip;
  final IconData icon;
  final VoidCallback onPressed;
  final Color color;

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: tooltip,
    constraints: const BoxConstraints.tightFor(width: 36, height: 44),
    padding: EdgeInsets.zero,
    visualDensity: VisualDensity.compact,
    onPressed: onPressed,
    icon: Icon(icon, size: 22, color: color),
  );
}

class BrowseNote extends StatelessWidget {
  const BrowseNote(this.text, {super.key, this.onRetry});
  final String text;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
    child: Row(
      children: [
        Expanded(
          child: Text(
            text,
            style: const TextStyle(
              fontSize: 13,
              height: 1.4,
              color: Colors.grey,
            ),
          ),
        ),
        if (onRetry != null)
          IconButton(
            tooltip: 'Thử lại',
            onPressed: onRetry,
            icon: const Icon(CupertinoIcons.refresh, size: 20),
          ),
      ],
    ),
  );
}
