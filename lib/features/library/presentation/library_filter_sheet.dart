import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../domain/library_book.dart';
import '../domain/library_authors.dart';
import '../domain/library_reading.dart';
import 'library_filter_picker.dart';

enum LibraryOrder {
  recent,
  title,
  unread,
  total,
  read,
  added,
  updated,
  latest,
  random,
}

enum LibraryTriState { any, include, exclude }

enum LibraryDisplay { grid, list, coverOnly }

class LibraryFilter {
  const LibraryFilter({
    this.kind = 'all',
    this.category = 'Tất cả',
    this.order = LibraryOrder.recent,
    this.reverse = false,
    this.compact = false,
    this.unread = LibraryTriState.any,
    this.downloaded = LibraryTriState.any,
    this.bookmarked = LibraryTriState.any,
    this.favorite = LibraryTriState.any,
    this.completed = LibraryTriState.any,
    this.source = 'all',
    this.sources = const {},
    this.excludeSource = false,
    this.author = '',
    this.scanlator = '',
    this.display = LibraryDisplay.grid,
    this.showCategoryTabs = true,
    this.showUnreadBadge = true,
    this.showDownloadedBadge = false,
    this.showLocalBadge = false,
    this.showSource = false,
    this.showReadingStatus = false,
    this.showReadCount = false,
    this.showFavoriteBadge = false,
    this.showLastUpdated = false,
    this.showPublicationStatus = false,
    this.showResumeButton = false,
    this.randomSeed = 0,
  });
  final String kind, category;
  final LibraryOrder order;
  final bool reverse, compact;
  final LibraryTriState unread, downloaded, bookmarked, favorite, completed;
  final String source;
  final Set<String> sources;
  final bool excludeSource;
  final String author;
  Set<String> get selectedSources => Set.unmodifiable(
    sources.isNotEmpty ? sources : {if (source != 'all') source},
  );
  // Retained for reading old preferences; this filter is no longer applied.
  final String scanlator;
  final LibraryDisplay display;
  final bool showCategoryTabs,
      showUnreadBadge,
      showDownloadedBadge,
      showLocalBadge,
      showSource,
      showReadingStatus,
      showReadCount,
      showFavoriteBadge,
      showLastUpdated,
      showPublicationStatus,
      showResumeButton;
  final int randomSeed;
  bool get active =>
      kind != 'all' ||
      category != 'Tất cả' ||
      selectedSources.isNotEmpty ||
      author.isNotEmpty ||
      [
        unread,
        downloaded,
        bookmarked,
        favorite,
        completed,
      ].any((state) => state != LibraryTriState.any);

  Map<String, dynamic> toJson() => {
    'kind': kind,
    'category': category,
    'order': order.name,
    'reverse': reverse,
    'compact': compact,
    'unread': unread.name,
    'downloaded': downloaded.name,
    'bookmarked': bookmarked.name,
    'favorite': favorite.name,
    'completed': completed.name,
    // Keep the legacy single-source field readable by earlier versions.
    'source': selectedSources.length == 1 ? selectedSources.single : 'all',
    'sources': selectedSources.toList()..sort(),
    'excludeSource': excludeSource,
    'author': author,
    'scanlator': '',
    'display': display.name,
    'showCategoryTabs': showCategoryTabs,
    'showUnreadBadge': showUnreadBadge,
    'showDownloadedBadge': showDownloadedBadge,
    'showLocalBadge': showLocalBadge,
    'showSource': showSource,
    'showReadingStatus': showReadingStatus,
    'showReadCount': showReadCount,
    'showFavoriteBadge': showFavoriteBadge,
    'showLastUpdated': showLastUpdated,
    'showPublicationStatus': showPublicationStatus,
    'showResumeButton': showResumeButton,
    'randomSeed': randomSeed,
  };

  factory LibraryFilter.fromJson(Map<String, dynamic> json) {
    T value<T extends Enum>(String key, List<T> values, T fallback) {
      if (!json.containsKey(key)) return fallback;
      for (final option in values) {
        if (option.name == json[key]) return option;
      }
      throw FormatException('Thiết lập $key không hợp lệ.');
    }

    bool flag(String key, bool fallback) {
      final result = json[key] ?? fallback;
      if (result is! bool) {
        throw FormatException('Thiết lập $key không hợp lệ.');
      }
      return result;
    }

    String text(String key, String fallback) {
      final result = json[key] ?? fallback;
      if (result is! String) {
        throw FormatException('Thiết lập $key không hợp lệ.');
      }
      return result;
    }

    final seed = json['randomSeed'] ?? 0;
    if (seed is! int) {
      throw const FormatException('Thứ tự ngẫu nhiên không hợp lệ.');
    }
    final rawSources = json['sources'];
    if (rawSources != null &&
        (rawSources is! List ||
            rawSources.length > 10000 ||
            rawSources.any(
              (value) =>
                  value is! String ||
                  value.isEmpty ||
                  value == 'all' ||
                  value.length > 4096,
            ))) {
      throw const FormatException('Danh sách nguồn lọc không hợp lệ.');
    }
    final author = text('author', '');
    final legacySource = text('source', 'all');
    text(
      'scanlator',
      '',
    ); // Validate old backups without applying this condition.
    if (author.length > 4096) {
      throw const FormatException('Tác giả lọc không hợp lệ.');
    }
    return LibraryFilter(
      kind: text('kind', 'all'),
      category: text('category', 'Tất cả'),
      order: value('order', LibraryOrder.values, LibraryOrder.recent),
      reverse: flag('reverse', false),
      compact: flag('compact', false),
      unread: value('unread', LibraryTriState.values, LibraryTriState.any),
      downloaded: value(
        'downloaded',
        LibraryTriState.values,
        LibraryTriState.any,
      ),
      bookmarked: value(
        'bookmarked',
        LibraryTriState.values,
        LibraryTriState.any,
      ),
      favorite: value('favorite', LibraryTriState.values, LibraryTriState.any),
      completed: value(
        'completed',
        LibraryTriState.values,
        LibraryTriState.any,
      ),
      source: rawSources == null
          ? legacySource
          : (rawSources as List).length == 1
          ? rawSources.single as String
          : 'all',
      sources: rawSources == null
          ? const {}
          : Set.unmodifiable((rawSources as List).cast<String>()),
      excludeSource: flag('excludeSource', false),
      author: libraryAuthorKey(author),
      display: value('display', LibraryDisplay.values, LibraryDisplay.grid),
      showCategoryTabs: flag('showCategoryTabs', true),
      showUnreadBadge: flag('showUnreadBadge', true),
      showDownloadedBadge: flag('showDownloadedBadge', false),
      showLocalBadge: flag('showLocalBadge', false),
      showSource: flag('showSource', false),
      showReadingStatus: flag('showReadingStatus', false),
      showReadCount: flag('showReadCount', false),
      showFavoriteBadge: flag('showFavoriteBadge', false),
      showLastUpdated: flag('showLastUpdated', false),
      showPublicationStatus: flag('showPublicationStatus', false),
      showResumeButton: flag('showResumeButton', false),
      randomSeed: seed,
    );
  }

  bool matches(LibraryBook book) =>
      (kind == 'all' || book.kind == kind) &&
      _matchesSource(book) &&
      (author.isEmpty ||
          libraryAuthorNames(book.author)
              .containsKey(libraryAuthorKey(author))) &&
      _tri(unread, book.chapters.length > readChapterCount(book)) &&
      _tri(downloaded, book.chapters.any((chapter) => chapter.downloaded)) &&
      _tri(bookmarked, book.bookmarks.isNotEmpty) &&
      _tri(favorite, book.favorite) &&
      _tri(completed, book.completed) &&
      switch (category) {
        'Đang đọc' => book.lastRead != null && !book.completed,
        'Yêu thích' => book.favorite,
        'Hoàn thành' => book.completed,
        'Tất cả' => true,
        _ => book.categories.contains(category),
      };

  bool _matchesSource(LibraryBook book) {
    final identity = '${book.engine}:${book.sourceId}';
    return sources.isNotEmpty
        ? sources.contains(identity) != excludeSource
        : source == 'all' || (source == identity) != excludeSource;
  }

  int compare(LibraryBook a, LibraryBook b) {
    final result = switch (order) {
      LibraryOrder.recent => _date(b.lastRead).compareTo(_date(a.lastRead)),
      LibraryOrder.title => a.title.toLowerCase().compareTo(
        b.title.toLowerCase(),
      ),
      LibraryOrder.unread =>
        (b.chapters.length - readChapterCount(b)).compareTo(
          a.chapters.length - readChapterCount(a),
        ),
      LibraryOrder.total => b.chapters.length.compareTo(a.chapters.length),
      LibraryOrder.read => readChapterCount(b).compareTo(readChapterCount(a)),
      LibraryOrder.added => _date(b.createdAt).compareTo(_date(a.createdAt)),
      LibraryOrder.updated => _date(
        b.lastUpdated,
      ).compareTo(_date(a.lastUpdated)),
      LibraryOrder.latest => _latest(b).compareTo(_latest(a)),
      LibraryOrder.random => _shuffleKey(
        a.id,
        randomSeed,
      ).compareTo(_shuffleKey(b.id, randomSeed)),
    };
    final stable = result == 0 ? a.id.compareTo(b.id) : result;
    return reverse ? -stable : stable;
  }

  LibraryFilter copyWith({
    String? kind,
    String? category,
    LibraryOrder? order,
    bool? reverse,
    bool? compact,
    LibraryTriState? unread,
    LibraryTriState? downloaded,
    LibraryTriState? bookmarked,
    LibraryTriState? favorite,
    LibraryTriState? completed,
    String? source,
    Set<String>? sources,
    bool? excludeSource,
    String? author,
    String? scanlator,
    LibraryDisplay? display,
    bool? showCategoryTabs,
    bool? showUnreadBadge,
    bool? showDownloadedBadge,
    bool? showLocalBadge,
    bool? showSource,
    bool? showReadingStatus,
    bool? showReadCount,
    bool? showFavoriteBadge,
    bool? showLastUpdated,
    bool? showPublicationStatus,
    bool? showResumeButton,
    int? randomSeed,
  }) => LibraryFilter(
    kind: kind ?? this.kind,
    category: category ?? this.category,
    order: order ?? this.order,
    reverse: reverse ?? this.reverse,
    compact: compact ?? this.compact,
    unread: unread ?? this.unread,
    downloaded: downloaded ?? this.downloaded,
    bookmarked: bookmarked ?? this.bookmarked,
    favorite: favorite ?? this.favorite,
    completed: completed ?? this.completed,
    source: sources != null
        ? (sources.length == 1 ? sources.single : 'all')
        : source ?? this.source,
    sources: sources != null
        ? Set.unmodifiable(sources)
        : source != null
        ? const {}
        : this.sources,
    excludeSource: excludeSource ?? this.excludeSource,
    author: author ?? this.author,
    scanlator: scanlator ?? this.scanlator,
    display: display ?? this.display,
    showCategoryTabs: showCategoryTabs ?? this.showCategoryTabs,
    showUnreadBadge: showUnreadBadge ?? this.showUnreadBadge,
    showDownloadedBadge: showDownloadedBadge ?? this.showDownloadedBadge,
    showLocalBadge: showLocalBadge ?? this.showLocalBadge,
    showSource: showSource ?? this.showSource,
    showReadingStatus: showReadingStatus ?? this.showReadingStatus,
    showReadCount: showReadCount ?? this.showReadCount,
    showFavoriteBadge: showFavoriteBadge ?? this.showFavoriteBadge,
    showLastUpdated: showLastUpdated ?? this.showLastUpdated,
    showPublicationStatus: showPublicationStatus ?? this.showPublicationStatus,
    showResumeButton: showResumeButton ?? this.showResumeButton,
    randomSeed: randomSeed ?? this.randomSeed,
  );
}

bool _tri(LibraryTriState state, bool value) => switch (state) {
  LibraryTriState.any => true,
  LibraryTriState.include => value,
  LibraryTriState.exclude => !value,
};
int _date(DateTime? date) => date?.millisecondsSinceEpoch ?? 0;
int _latest(LibraryBook book) => book.chapters.fold<int>(
  0,
  (value, chapter) =>
      _date(chapter.uploadedAt) > value ? _date(chapter.uploadedAt) : value,
);
int _shuffleKey(String id, int seed) {
  var hash = (2166136261 ^ seed) & 0xffffffff;
  for (final unit in id.codeUnits) {
    hash = ((hash ^ unit) * 16777619) & 0xffffffff;
  }
  return hash;
}

class LibraryFilterSheet extends StatefulWidget {
  const LibraryFilterSheet({
    super.key,
    required this.value,
    required this.collections,
    required this.onChanged,
    this.sources = const {},
    this.authors = const {},
    this.presetsBuilder,
    this.libraryColumns,
    this.onColumnsChanged,
  });
  final LibraryFilter value;
  final List<String> collections;
  final ValueChanged<LibraryFilter> onChanged;
  final Map<String, String> sources;
  final Map<String, String> authors;
  final Widget Function(LibraryFilter, ValueChanged<LibraryFilter>)?
  presetsBuilder;
  final int? libraryColumns;
  final ValueChanged<int>? onColumnsChanged;
  @override
  State<LibraryFilterSheet> createState() => _LibraryFilterSheetState();
}

class _LibraryFilterSheetState extends State<LibraryFilterSheet> {
  late LibraryFilter filter = widget.value;
  late int columns = widget.libraryColumns ?? 5;
  void change(LibraryFilter value) {
    setState(() => filter = value);
    widget.onChanged(value);
  }

  void reset() {
    change(
      filter.copyWith(
        kind: 'all',
        category: 'Tất cả',
        unread: LibraryTriState.any,
        downloaded: LibraryTriState.any,
        bookmarked: LibraryTriState.any,
        favorite: LibraryTriState.any,
        completed: LibraryTriState.any,
        source: 'all',
        excludeSource: false,
        author: '',
        scanlator: '',
      ),
    );
  }

  Widget section(String title) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
    child: Text(
      title,
      style: Theme.of(context).textTheme.labelLarge
          ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
    ),
  );

  Widget choice(String label, bool selected, VoidCallback onTap) => ListTile(
    dense: true,
    title: Text(label),
    selected: selected,
    trailing: selected
        ? Icon(
            CupertinoIcons.check_mark,
            color: Theme.of(context).colorScheme.primary,
          )
        : null,
    onTap: onTap,
  );

  Widget toggle(String label, bool value, ValueChanged<bool> onChanged) =>
      SwitchListTile.adaptive(
        dense: true,
        visualDensity: VisualDensity.compact,
        title: Text(label),
        value: value,
        onChanged: onChanged,
      );

  String triLabel(LibraryTriState value) => switch (value) {
    LibraryTriState.any => 'Tất cả',
    LibraryTriState.include => 'Chỉ có',
    LibraryTriState.exclude => 'Loại trừ',
  };

  Widget triChoice(
    String label,
    LibraryTriState value,
    ValueChanged<LibraryTriState> onChanged,
  ) => ListTile(
    dense: true,
    visualDensity: VisualDensity.compact,
    minTileHeight: 40,
    title: Text(label),
    onTap: () => onChanged(LibraryTriState.values[(value.index + 1) % 3]),
    trailing: PopupMenuButton<LibraryTriState>(
      tooltip: 'Lọc $label',
      initialValue: value,
      onSelected: onChanged,
      itemBuilder: (_) => [
        for (final option in LibraryTriState.values)
          PopupMenuItem(value: option, child: Text(triLabel(option))),
      ],
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              triLabel(value),
              style: TextStyle(
                color: value == LibraryTriState.any
                    ? Theme.of(context).colorScheme.onSurfaceVariant
                    : Theme.of(context).colorScheme.primary,
              ),
            ),
            const SizedBox(width: 4),
            const Icon(CupertinoIcons.chevron_down, size: 12),
          ],
        ),
      ),
    ),
  );

  Widget picker(
    String title,
    String selected,
    Map<String, String> options,
    ValueChanged<String> onSelected,
  ) => ListTile(
    dense: true,
    visualDensity: VisualDensity.compact,
    minTileHeight: 48,
    title: Text(title),
    subtitle: Text(
      options[selected] ?? 'Lựa chọn đã lưu',
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    ),
    trailing: const Icon(CupertinoIcons.chevron_right, size: 16),
    onTap: () async {
      final value = await showLibraryFilterPicker(
        context,
        title: title,
        options: options,
        selected: selected,
      );
      if (value != null && mounted) onSelected(value);
    },
  );

  Widget group(String title, List<Widget> children, int enabled) =>
      ExpansionTile(
        title: Text(title),
        subtitle: Text('$enabled mục đang bật'),
        tilePadding: const EdgeInsets.symmetric(horizontal: 16),
        children: children,
      );

  Widget filters() {
    final sources = widget.sources.entries.toList()
      ..sort((a, b) => a.value.toLowerCase().compareTo(b.value.toLowerCase()));
    final authors = widget.authors.entries.toList()
      ..sort((a, b) => a.value.toLowerCase().compareTo(b.value.toLowerCase()));
    final selectedSources = filter.selectedSources;
    final activeCount = [
      filter.kind != 'all',
      filter.category != 'Tất cả',
      selectedSources.isNotEmpty,
      filter.author.isNotEmpty,
      filter.unread != LibraryTriState.any,
      filter.downloaded != LibraryTriState.any,
      filter.bookmarked != LibraryTriState.any,
      filter.favorite != LibraryTriState.any,
      filter.completed != LibraryTriState.any,
    ].where((active) => active).length;
    return ListView(
      key: const ValueKey('library-filter-options'),
      padding: const EdgeInsets.only(bottom: 8),
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 16, right: 8),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  activeCount == 0
                      ? 'Tất cả truyện'
                      : '$activeCount điều kiện đang dùng',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
              Flexible(
                child: TextButton(
                  onPressed: filter.active ? reset : null,
                  child: const Text(
                    'Đặt lại bộ lọc',
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              for (final item in const {
                'all': 'Tất cả',
                'manga': 'Truyện tranh',
                'novel': 'Truyện chữ & ebook',
              }.entries)
                ChoiceChip(
                  label: Text(item.value),
                  selected: filter.kind == item.key,
                  onSelected: (_) => change(filter.copyWith(kind: item.key)),
                ),
            ],
          ),
        ),
        picker('Danh mục', filter.category, {
          for (final category in {
            'Tất cả',
            'Đang đọc',
            'Yêu thích',
            'Hoàn thành',
            ...widget.collections,
          })
            category: category,
        }, (value) => change(filter.copyWith(category: value))),
        if (sources.isNotEmpty || selectedSources.isNotEmpty)
          ListTile(
            key: const ValueKey('library-sources-filter'),
            dense: true,
            visualDensity: VisualDensity.compact,
            minTileHeight: 48,
            title: const Text('Nguồn truyện'),
            subtitle: Text(
              selectedSources.isEmpty
                  ? 'Tất cả nguồn'
                  : selectedSources.length == 1
                  ? widget.sources[selectedSources.single] ??
                        selectedSources.single
                  : '${selectedSources.length} nguồn đã chọn',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: const Icon(CupertinoIcons.chevron_right, size: 16),
            onTap: () async {
              final values = await showLibraryFilterMultiPicker(
                context,
                title: 'Nguồn truyện',
                options: {
                  for (final source in sources) source.key: source.value,
                  for (final key in selectedSources)
                    if (!widget.sources.containsKey(key))
                      key: 'Nguồn đã lưu · $key',
                },
                selected: selectedSources,
              );
              if (values != null && mounted) {
                change(filter.copyWith(sources: values));
              }
            },
          ),
        if (selectedSources.isNotEmpty || filter.excludeSource)
          toggle(
            'Loại trừ nguồn đã chọn',
            filter.excludeSource,
            (value) => change(filter.copyWith(excludeSource: value)),
          ),
        if (authors.isNotEmpty || filter.author.isNotEmpty)
          picker('Tác giả', libraryAuthorKey(filter.author), {
            '': 'Tất cả tác giả',
            for (final author in authors) author.key: author.value,
            if (filter.author.isNotEmpty &&
                !widget.authors.containsKey(libraryAuthorKey(filter.author)))
              libraryAuthorKey(filter.author): filter.author,
          }, (value) => change(filter.copyWith(author: value))),
        const Divider(height: 16),
        section('Trạng thái'),
        triChoice(
          'Chương chưa đọc',
          filter.unread,
          (value) => change(filter.copyWith(unread: value)),
        ),
        triChoice(
          'Chương đã tải',
          filter.downloaded,
          (value) => change(filter.copyWith(downloaded: value)),
        ),
        triChoice(
          'Dấu trang',
          filter.bookmarked,
          (value) => change(filter.copyWith(bookmarked: value)),
        ),
        triChoice(
          'Yêu thích',
          filter.favorite,
          (value) => change(filter.copyWith(favorite: value)),
        ),
        triChoice(
          'Hoàn thành',
          filter.completed,
          (value) => change(filter.copyWith(completed: value)),
        ),
      ],
    );
  }

  Widget sorting() => ListView(
    padding: const EdgeInsets.only(bottom: 16),
    children: [
      toggle(
        'Đảo chiều',
        filter.reverse,
        (value) => change(filter.copyWith(reverse: value)),
      ),
      const Divider(height: 1),
      for (final item in const {
        LibraryOrder.recent: 'Đọc gần đây',
        LibraryOrder.title: 'Tên',
        LibraryOrder.added: 'Ngày thêm vào thư viện',
        LibraryOrder.updated: 'Lần cập nhật gần nhất',
        LibraryOrder.latest: 'Ngày chương mới nhất',
        LibraryOrder.unread: 'Số chương chưa đọc',
        LibraryOrder.total: 'Tổng số chương',
        LibraryOrder.read: 'Số chương đã đọc',
        LibraryOrder.random: 'Ngẫu nhiên',
      }.entries)
        choice(
          item.value,
          filter.order == item.key,
          () => change(
            filter.copyWith(
              order: item.key,
              randomSeed: item.key == LibraryOrder.random
                  ? DateTime.now().millisecondsSinceEpoch
                  : null,
            ),
          ),
        ),
    ],
  );

  Widget display() {
    final information = <(String, bool, LibraryFilter)>[
      (
        'Tên nguồn',
        filter.showSource,
        filter.copyWith(showSource: !filter.showSource),
      ),
      (
        'Trạng thái đọc',
        filter.showReadingStatus,
        filter.copyWith(showReadingStatus: !filter.showReadingStatus),
      ),
      (
        'Số chương đã đọc',
        filter.showReadCount,
        filter.copyWith(showReadCount: !filter.showReadCount),
      ),
      (
        'Trạng thái yêu thích',
        filter.showFavoriteBadge,
        filter.copyWith(showFavoriteBadge: !filter.showFavoriteBadge),
      ),
      (
        'Lần cập nhật gần nhất',
        filter.showLastUpdated,
        filter.copyWith(showLastUpdated: !filter.showLastUpdated),
      ),
      (
        'Trạng thái phát hành',
        filter.showPublicationStatus,
        filter.copyWith(showPublicationStatus: !filter.showPublicationStatus),
      ),
      (
        'Nút tiếp tục đọc',
        filter.showResumeButton,
        filter.copyWith(showResumeButton: !filter.showResumeButton),
      ),
    ];
    return ListView(
      padding: const EdgeInsets.only(bottom: 16),
      children: [
        section('Bố cục'),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              for (final item in const {
                LibraryDisplay.grid: 'Lưới có tên',
                LibraryDisplay.list: 'Danh sách',
                LibraryDisplay.coverOnly: 'Lưới chỉ bìa',
              }.entries)
                ChoiceChip(
                  label: Text(item.value),
                  selected: filter.display == item.key,
                  onSelected: (_) => change(filter.copyWith(display: item.key)),
                ),
            ],
          ),
        ),
        if (filter.display != LibraryDisplay.list) ...[
          if (widget.onColumnsChanged != null) ...[
            ListTile(
              dense: true,
              title: const Text('Số cột lưới'),
              trailing: Text('$columns'),
            ),
            Slider(
              key: const ValueKey('library-columns-slider'),
              value: columns.toDouble(),
              min: 2,
              max: 8,
              divisions: 6,
              label: '$columns cột',
              onChanged: (value) => setState(() => columns = value.round()),
              onChangeEnd: (value) => widget.onColumnsChanged!(value.round()),
            ),
          ],
          toggle(
            'Lưới nhỏ',
            filter.compact,
            (value) => change(filter.copyWith(compact: value)),
          ),
        ],
        toggle(
          'Hiện tab danh mục',
          filter.showCategoryTabs,
          (value) => change(filter.copyWith(showCategoryTabs: value)),
        ),
        const Divider(height: 16),
        group(
          'Dấu hiệu trên bìa',
          [
            toggle(
              'Chương chưa đọc',
              filter.showUnreadBadge,
              (value) => change(filter.copyWith(showUnreadBadge: value)),
            ),
            toggle(
              'Chương đã tải',
              filter.showDownloadedBadge,
              (value) => change(filter.copyWith(showDownloadedBadge: value)),
            ),
            toggle(
              'Truyện trong máy',
              filter.showLocalBadge,
              (value) => change(filter.copyWith(showLocalBadge: value)),
            ),
          ],
          [
            filter.showUnreadBadge,
            filter.showDownloadedBadge,
            filter.showLocalBadge,
          ].where((value) => value).length,
        ),
        group('Thông tin và nút đọc', [
          for (final option in information)
            toggle(option.$1, option.$2, (_) => change(option.$3)),
        ], information.where((option) => option.$2).length),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final close = IconButton(
      tooltip: 'Đóng bộ lọc',
      visualDensity: VisualDensity.compact,
      onPressed: () => Navigator.pop(context),
      icon: const Icon(CupertinoIcons.xmark, size: 18),
    );
    return Padding(
      padding: EdgeInsets.only(bottom: media.viewInsets.bottom),
      child: SizedBox(
        height:
            (media.size.height - media.padding.top - media.viewInsets.bottom) *
            .94,
        child: DefaultTabController(
          length: 3,
          child: Column(
            children: [
              SizedBox(
                height: 12,
                child: Center(
                  child: Container(
                    width: 28,
                    height: 3,
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
              ),
              if (widget.presetsBuilder != null)
                Row(
                  children: [
                    Expanded(child: widget.presetsBuilder!(filter, change)),
                    close,
                  ],
                ),
              Row(
                children: [
                  const Expanded(
                    child: TabBar(
                      tabs: [
                        Tab(text: 'Lọc', height: 40),
                        Tab(text: 'Sắp xếp', height: 40),
                        Tab(text: 'Hiển thị', height: 40),
                      ],
                    ),
                  ),
                  if (widget.presetsBuilder == null) close,
                ],
              ),
              Expanded(
                child: TabBarView(children: [filters(), sorting(), display()]),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
