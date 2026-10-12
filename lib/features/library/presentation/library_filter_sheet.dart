import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../domain/library_book.dart';
import '../domain/library_reading.dart';

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
    this.excludeSource = false,
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
  final bool excludeSource;
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
      source != 'all' ||
      scanlator.isNotEmpty ||
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
    'source': source,
    'excludeSource': excludeSource,
    'scanlator': scanlator,
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
      source: text('source', 'all'),
      excludeSource: flag('excludeSource', false),
      scanlator: text('scanlator', ''),
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
      (source == 'all' ||
          (('${book.engine}:${book.sourceId}' == source) != excludeSource)) &&
      (scanlator.isEmpty ||
          book.chapters.any(
            (chapter) => chapter.scanlator.toLowerCase().contains(
              scanlator.toLowerCase(),
            ),
          )) &&
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
    bool? excludeSource,
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
    source: source ?? this.source,
    excludeSource: excludeSource ?? this.excludeSource,
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
    this.presetsBuilder,
  });
  final LibraryFilter value;
  final List<String> collections;
  final ValueChanged<LibraryFilter> onChanged;
  final Map<String, String> sources;
  final Widget Function(LibraryFilter, ValueChanged<LibraryFilter>)?
  presetsBuilder;
  @override
  State<LibraryFilterSheet> createState() => _LibraryFilterSheetState();
}

class _LibraryFilterSheetState extends State<LibraryFilterSheet> {
  late LibraryFilter filter = widget.value;
  late final scanlatorController = TextEditingController(
    text: widget.value.scanlator,
  );

  @override
  void dispose() {
    scanlatorController.dispose();
    super.dispose();
  }

  void change(LibraryFilter value) {
    setState(() => filter = value);
    widget.onChanged(value);
  }

  Widget choice(String label, bool selected, VoidCallback onTap) => ListTile(
    title: Text(label),
    trailing: selected
        ? Icon(CupertinoIcons.check_mark, color: Theme.of(context).primaryColor)
        : null,
    onTap: onTap,
    selected: selected,
  );

  Widget section(String title) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 18, 16, 4),
    child: Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
  );

  Widget triChoice(
    String label,
    LibraryTriState value,
    ValueChanged<LibraryTriState> onChanged,
  ) => ListTile(
    title: Text(label),
    subtitle: Text(switch (value) {
      LibraryTriState.any => 'Không áp dụng',
      LibraryTriState.include => 'Chỉ hiện truyện có',
      LibraryTriState.exclude => 'Loại trừ truyện có',
    }),
    trailing: Icon(
      switch (value) {
        LibraryTriState.any => CupertinoIcons.square,
        LibraryTriState.include => CupertinoIcons.checkmark_square_fill,
        LibraryTriState.exclude => CupertinoIcons.minus_square_fill,
      },
      color: value == LibraryTriState.any
          ? null
          : Theme.of(context).primaryColor,
    ),
    onTap: () => onChanged(LibraryTriState.values[(value.index + 1) % 3]),
  );

  @override
  Widget build(BuildContext context) => SizedBox(
    height: MediaQuery.sizeOf(context).height * .65,
    child: DefaultTabController(
      length: 3,
      child: Column(
        children: [
          if (widget.presetsBuilder != null)
            widget.presetsBuilder!(filter, (value) {
              scanlatorController.text = value.scanlator;
              change(value);
            }),
          Row(
            children: [
              const Expanded(
                child: TabBar(
                  tabs: [
                    Tab(text: 'Lọc'),
                    Tab(text: 'Sắp xếp'),
                    Tab(text: 'Hiển thị'),
                  ],
                ),
              ),
              IconButton(
                tooltip: 'Đóng bộ lọc',
                onPressed: () => Navigator.pop(context),
                icon: const Icon(CupertinoIcons.xmark, size: 18),
              ),
            ],
          ),
          Expanded(
            child: TabBarView(
              children: [
                ListView(
                  children: [
                    ListTile(
                      leading: const Icon(CupertinoIcons.clear_circled),
                      title: const Text('Đặt lại bộ lọc'),
                      onTap: () {
                        scanlatorController.clear();
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
                            scanlator: '',
                          ),
                        );
                      },
                    ),
                    section('Nội dung'),
                    for (final item in const {
                      'all': 'Tất cả nội dung',
                      'manga': 'Truyện tranh',
                      'novel': 'Truyện chữ & ebook',
                    }.entries)
                      choice(
                        item.value,
                        filter.kind == item.key,
                        () => change(filter.copyWith(kind: item.key)),
                      ),
                    const Divider(height: 1),
                    section('Bao gồm / loại trừ'),
                    triChoice(
                      'Có chương chưa đọc',
                      filter.unread,
                      (value) => change(filter.copyWith(unread: value)),
                    ),
                    triChoice(
                      'Có chương đã tải',
                      filter.downloaded,
                      (value) => change(filter.copyWith(downloaded: value)),
                    ),
                    triChoice(
                      'Có dấu trang',
                      filter.bookmarked,
                      (value) => change(filter.copyWith(bookmarked: value)),
                    ),
                    triChoice(
                      'Yêu thích',
                      filter.favorite,
                      (value) => change(filter.copyWith(favorite: value)),
                    ),
                    triChoice(
                      'Đã hoàn thành',
                      filter.completed,
                      (value) => change(filter.copyWith(completed: value)),
                    ),
                    if (widget.sources.isNotEmpty) ...[
                      section('Nguồn'),
                      SwitchListTile.adaptive(
                        title: const Text('Loại trừ nguồn đã chọn'),
                        value: filter.excludeSource,
                        onChanged: (value) =>
                            change(filter.copyWith(excludeSource: value)),
                      ),
                      choice(
                        'Tất cả nguồn',
                        filter.source == 'all',
                        () => change(filter.copyWith(source: 'all')),
                      ),
                      for (final source in widget.sources.entries)
                        choice(
                          source.value,
                          filter.source == source.key,
                          () => change(filter.copyWith(source: source.key)),
                        ),
                    ],
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 8,
                      ),
                      child: TextFormField(
                        controller: scanlatorController,
                        key: const ValueKey('library-scanlator'),
                        decoration: const InputDecoration(
                          labelText: 'Nhóm dịch',
                          helperText: 'Chỉ áp dụng khi nguồn cung cấp nhóm dịch cho chương.',
                        ),
                        onChanged: (value) =>
                            change(filter.copyWith(scanlator: value.trim())),
                      ),
                    ),
                    section('Thư viện'),
                    for (final category in [
                      'Tất cả',
                      'Đang đọc',
                      'Yêu thích',
                      'Hoàn thành',
                      ...widget.collections,
                    ])
                      choice(
                        category,
                        filter.category == category,
                        () => change(filter.copyWith(category: category)),
                      ),
                  ],
                ),
                ListView(
                  children: [
                    for (final item in const {
                      LibraryOrder.recent: 'Đọc gần đây',
                      LibraryOrder.title: 'Tên',
                      LibraryOrder.unread: 'Số chương chưa đọc',
                      LibraryOrder.total: 'Tổng số chương',
                      LibraryOrder.read: 'Số chương đã đọc',
                      LibraryOrder.added: 'Ngày thêm vào thư viện',
                      LibraryOrder.updated: 'Lần cập nhật gần nhất',
                      LibraryOrder.latest: 'Ngày chương mới nhất',
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
                    const Divider(height: 1),
                    SwitchListTile.adaptive(
                      title: const Text('Đảo chiều'),
                      value: filter.reverse,
                      onChanged: (value) =>
                          change(filter.copyWith(reverse: value)),
                    ),
                  ],
                ),
                ListView(
                  children: [
                    for (final item in const {
                      LibraryDisplay.grid: 'Lưới có tên',
                      LibraryDisplay.list: 'Danh sách',
                      LibraryDisplay.coverOnly: 'Lưới chỉ bìa',
                    }.entries)
                      choice(
                        item.value,
                        filter.display == item.key,
                        () => change(filter.copyWith(display: item.key)),
                      ),
                    SwitchListTile.adaptive(
                      title: const Text('Lưới nhỏ'),
                      subtitle: const Text('Hiển thị thêm bìa trên mỗi hàng'),
                      value: filter.compact,
                      onChanged: (value) =>
                          change(filter.copyWith(compact: value)),
                    ),
                    SwitchListTile.adaptive(
                      title: const Text('Hiện tab danh mục'),
                      value: filter.showCategoryTabs,
                      onChanged: (value) =>
                          change(filter.copyWith(showCategoryTabs: value)),
                    ),
                    SwitchListTile.adaptive(
                      title: const Text('Badge chương chưa đọc'),
                      value: filter.showUnreadBadge,
                      onChanged: (value) =>
                          change(filter.copyWith(showUnreadBadge: value)),
                    ),
                    SwitchListTile.adaptive(
                      title: const Text('Badge chương đã tải'),
                      value: filter.showDownloadedBadge,
                      onChanged: (value) =>
                          change(filter.copyWith(showDownloadedBadge: value)),
                    ),
                    SwitchListTile.adaptive(
                      title: const Text('Badge truyện local'),
                      value: filter.showLocalBadge,
                      onChanged: (value) =>
                          change(filter.copyWith(showLocalBadge: value)),
                    ),
                    for (final option in <(String, bool, LibraryFilter)>[
                      (
                        'Tên nguồn',
                        filter.showSource,
                        filter.copyWith(showSource: !filter.showSource),
                      ),
                      (
                        'Trạng thái đọc',
                        filter.showReadingStatus,
                        filter.copyWith(
                          showReadingStatus: !filter.showReadingStatus,
                        ),
                      ),
                      (
                        'Số chương đã đọc',
                        filter.showReadCount,
                        filter.copyWith(showReadCount: !filter.showReadCount),
                      ),
                      (
                        'Trạng thái yêu thích',
                        filter.showFavoriteBadge,
                        filter.copyWith(
                          showFavoriteBadge: !filter.showFavoriteBadge,
                        ),
                      ),
                      (
                        'Lần cập nhật gần nhất',
                        filter.showLastUpdated,
                        filter.copyWith(
                          showLastUpdated: !filter.showLastUpdated,
                        ),
                      ),
                      (
                        'Trạng thái phát hành',
                        filter.showPublicationStatus,
                        filter.copyWith(
                          showPublicationStatus: !filter.showPublicationStatus,
                        ),
                      ),
                      (
                        'Nút tiếp tục đọc',
                        filter.showResumeButton,
                        filter.copyWith(
                          showResumeButton: !filter.showResumeButton,
                        ),
                      ),
                    ])
                      SwitchListTile.adaptive(
                        title: Text(option.$1),
                        value: option.$2,
                        onChanged: (_) => change(option.$3),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}
