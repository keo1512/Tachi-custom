import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../core/diagnostics/diagnostic_log.dart';
import '../../library/domain/library_book.dart';
import '../../library/domain/library_reading.dart';
import '../../sources/domain/catalogue.dart';
import '../domain/reader_options.dart';
import 'manga_page_layout.dart';
import 'native_manga_image_window.dart';
import 'zoomable_manga_page.dart';

class ContinuousMangaLocation {
  const ContinuousMangaLocation({
    required this.chapter,
    required this.content,
    required this.page,
    required this.fraction,
    required this.completed,
    required this.failedPages,
  });
  final int chapter, page;
  final ReaderContent content;
  final double fraction;
  final bool completed;
  final Set<int> failedPages;
}

/// One scroll surface across chapter boundaries. Metadata is prefetched before
/// the end; only three chapters and nearby image bytes are retained. Pruning or
/// inserting a chapter preserves the visible page as the layout anchor.
class ContinuousMangaReader extends StatefulWidget {
  const ContinuousMangaReader({
    super.key,
    required this.book,
    required this.initialChapter,
    required this.initialContent,
    required this.initialFraction,
    required this.options,
    required this.margins,
    required this.scroll,
    required this.viewportKey,
    required this.loadChapter,
    required this.fetchImage,
    required this.isCurrent,
    required this.onLocation,
    required this.onProgress,
    required this.onPageActions,
    this.onStale,
    this.onVisibleImageReady,
  });
  final LibraryBook book;
  final int initialChapter;
  final ReaderContent initialContent;
  final double initialFraction;
  final ReaderOptions options;
  final EdgeInsets margins;
  final ScrollController scroll;
  final GlobalKey viewportKey;
  final Future<ReaderContent> Function(int chapter) loadChapter;
  final Future<SourceImageData> Function(
    int chapter,
    ReaderContent data,
    int page,
  )
  fetchImage;
  final bool Function() isCurrent;
  final ValueChanged<ContinuousMangaLocation> onLocation;
  final ValueChanged<ContinuousMangaLocation> onProgress;
  final void Function(int chapter, int page) onPageActions;
  final VoidCallback? onStale;
  final void Function(int chapter, int page)? onVisibleImageReady;

  @override
  State<ContinuousMangaReader> createState() => ContinuousMangaReaderState();
}

class _Chapter {
  _Chapter(this.index, this.data)
    : keys = List.generate(data.images.length, (_) => GlobalKey());
  final int index;
  final ReaderContent data;
  final List<GlobalKey> keys;
  final decoded = <int>{}, failed = <int>{};
  late final NativeMangaImageWindow images;
  bool completed = false;
}

class ContinuousMangaReaderState extends State<ContinuousMangaReader> {
  final _chapters = <_Chapter>[];
  final _pending = <int, int>{};
  final _errors = <int, Object>{};
  ContinuousMangaLocation? location;
  bool _layoutPending = false, _restoring = true, _closed = false;
  bool _hasLaidOut = false;
  ContinuousMangaLocation? _seekAfterLayout;
  int _epoch = 0;

  bool get _valid => mounted && !_closed && widget.isCurrent();

  @visibleForTesting
  int get retainedChapters => _chapters.length;

  @visibleForTesting
  int get retainedImages =>
      _chapters.fold(0, (n, c) => n + c.images.retainedImages);

  bool get visibleImageReady {
    final active = location;
    return active != null &&
        _chapters.any(
          (c) => c.index == active.chapter && c.decoded.contains(active.page),
        );
  }

  @override
  void initState() {
    super.initState();
    final first = _create(widget.initialChapter, widget.initialContent);
    _chapters.add(first);
    final page = (widget.initialFraction * first.data.images.length)
        .floor()
        .clamp(0, first.data.images.length - 1);
    location = _location(first, page, widget.initialFraction);
    widget.scroll.addListener(_scrolled);
    first.images.focus(page);
    _layout(location);
  }

  _Chapter _create(int index, ReaderContent data) {
    if (data.kind != 'manga' || data.images.isEmpty) {
      throw const FormatException('Chương chưa có danh sách ảnh hợp lệ.');
    }
    final chapter = _Chapter(index, data);
    chapter.images = NativeMangaImageWindow(
      count: data.images.length,
      fetch: (page) async {
        if (!_valid) {
          throw StateError('Phiên đọc đã thay đổi. Hãy mở lại truyện.');
        }
        final image = await widget.fetchImage(index, data, page);
        if (!_valid) {
          throw StateError('Phiên đọc đã thay đổi. Hãy mở lại truyện.');
        }
        return image;
      },
    );
    chapter.images.addListener(() {
      if (!_valid) return;
      // The render tree still contains the old dimensions at this point.
      // Preserve its page/fraction when a placeholder gets its natural height.
      _layout(location);
    });
    return chapter;
  }

  ContinuousMangaLocation _location(_Chapter c, int page, double fraction) =>
      ContinuousMangaLocation(
        chapter: c.index,
        content: c.data,
        page: page,
        fraction: fraction.clamp(0, 1),
        completed: c.completed,
        failedPages: Set.unmodifiable(c.failed),
      );

  RenderBox? _box(GlobalKey key) {
    if (!_hasLaidOut) return null;
    final box = key.currentContext?.findRenderObject();
    return box is RenderBox && box.hasSize ? box : null;
  }

  void _layout(ContinuousMangaLocation? anchor, {bool seek = false}) {
    if (!_valid) return;
    if (seek) _seekAfterLayout = anchor;
    if (_layoutPending) return;
    final chapter = _chapters
        .where((c) => c.index == anchor?.chapter)
        .firstOrNull;
    final box = chapter == null || anchor == null
        ? null
        : _box(chapter.keys[anchor.page]);
    final view = _box(widget.viewportKey);
    final relativeTop = box == null || view == null
        ? null
        : box.localToGlobal(Offset.zero).dy -
              view.localToGlobal(Offset.zero).dy;
    final oldHeight = box?.size.height;
    _layoutPending = true;
    _restoring = true;
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _layoutPending = false;
      if (!_valid) return;
      _hasLaidOut = true;
      final requested = _seekAfterLayout;
      _seekAfterLayout = null;
      if (requested != null) {
        _restore(requested);
      } else if (anchor != null) {
        final newBox = chapter == null ? null : _box(chapter.keys[anchor.page]);
        // Preserve the fraction inside an image when its actual dimensions
        // replace a placeholder. Insert/prune operations retain pixel offset.
        final changedHeight =
            oldHeight != null &&
            newBox != null &&
            (newBox.size.height - oldHeight).abs() > .5;
        _restore(anchor, relativeTop: changedHeight ? null : relativeTop);
      }
      _restoring = false;
      _scrolled();
    });
  }

  void _restore(ContinuousMangaLocation anchor, {double? relativeTop}) {
    final chapter = _chapters
        .where((c) => c.index == anchor.chapter)
        .firstOrNull;
    final view = _box(widget.viewportKey);
    if (chapter == null || view == null || !widget.scroll.hasClients) return;
    final page = anchor.page.clamp(0, chapter.keys.length - 1);
    final box = _box(chapter.keys[page]);
    if (box == null) return;
    final within = (anchor.fraction * chapter.keys.length - page).clamp(
      0.0,
      1.0,
    );
    final offset =
        widget.scroll.offset +
        box.localToGlobal(Offset.zero).dy -
        view.localToGlobal(Offset.zero).dy +
        (relativeTop == null
            ? anchor.fraction >= 1
                  ? box.size.height - view.size.height
                  : box.size.height * within
            : -relativeTop);
    widget.scroll.jumpTo(
      offset.clamp(0.0, widget.scroll.position.maxScrollExtent),
    );
  }

  /// Reader controls and bookmarks are relative to the currently visible
  /// chapter, even when other chapters share this scroll surface.
  void seek({required double fraction, int? page}) {
    if (!_valid || location == null) return;
    final c = _chapters.firstWhere((c) => c.index == location!.chapter);
    final p = (page ?? (fraction * c.keys.length).floor()).clamp(
      0,
      c.keys.length - 1,
    );
    location = _location(c, p, page == null ? fraction : p / c.keys.length);
    _focus(c, p);
    _layout(location, seek: true);
  }

  bool jumpToChapter(int index) {
    final chapter = _chapters.where((c) => c.index == index).firstOrNull;
    if (!_valid || chapter == null) return false;
    location = _location(chapter, 0, 0);
    widget.onLocation(location!);
    _focus(chapter, 0);
    _layout(location, seek: true);
    return true;
  }

  void nextPage() {
    final here = location;
    if (here == null) return;
    if (here.page + 1 < here.content.images.length) {
      seek(fraction: 0, page: here.page + 1);
    } else {
      final next = _neighbour(here.chapter, 1);
      if (next != null) jumpToChapter(next);
    }
  }

  int? _neighbour(int from, int direction) {
    var index = from + direction;
    final seen = {widget.book.chapters[from].title.trim().toLowerCase()};
    while (index >= 0 && index < widget.book.chapters.length) {
      final chapter = widget.book.chapters[index];
      if (!(widget.options.skipRead && chapterIsRead(widget.book, index)) &&
          !(widget.options.skipDuplicates &&
              !seen.add(chapter.title.trim().toLowerCase()))) {
        return index;
      }
      index += direction;
    }
    return null;
  }

  void _scrolled() {
    if (!_valid || _restoring || !widget.scroll.hasClients) return;
    final view = _box(widget.viewportKey);
    if (view == null) return;
    final top = view.localToGlobal(Offset.zero).dy;
    final bottom = top + view.size.height;
    _Chapter? visible;
    int page = 0;
    double fraction = 0;
    for (final c in _chapters) {
      final last = _box(c.keys.last);
      if (!c.completed &&
          last != null &&
          c.failed.isEmpty &&
          c.decoded.contains(c.keys.length - 1)) {
        final y = last.localToGlobal(Offset.zero).dy;
        if (y + last.size.height > top &&
            y < bottom &&
            y + last.size.height <= bottom + 1) {
          c.completed = true;
          widget.onProgress(_location(c, c.keys.length - 1, 1));
        }
      }
      if (visible != null) continue;
      for (var i = 0; i < c.keys.length; i++) {
        final box = _box(c.keys[i]);
        if (box == null || box.size.height <= 0) continue;
        final y = box.localToGlobal(Offset.zero).dy;
        if (y + box.size.height > top + 1 && y < bottom) {
          visible = c;
          page = i;
          fraction =
              (i + ((top - y) / box.size.height).clamp(0, 1)) / c.keys.length;
          if (i == c.keys.length - 1 && y + box.size.height <= bottom + 1) {
            fraction = 1;
          }
          break;
        }
      }
    }
    if (visible != null) {
      final next = _location(visible, page, fraction);
      final previous = location;
      location = next;
      if (previous == null ||
          previous.chapter != next.chapter ||
          previous.page != next.page ||
          previous.fraction != next.fraction ||
          previous.completed != next.completed ||
          !setEquals(previous.failedPages, next.failedPages)) {
        widget.onLocation(next);
      }
      _focus(visible, page);
      if (visible.decoded.contains(page)) {
        widget.onVisibleImageReady?.call(visible.index, page);
      }
      // Opening at page zero used to enqueue the previous chapter (and the
      // next one for short chapters) before the visible image had arrived.
      // Those extension calls share page state with image requests. Start
      // adjacent metadata only after this visible page renders successfully.
      // A blank failed page must not start more background source requests.
      if (visible.decoded.contains(page)) {
        if (page >= visible.keys.length - 4) _prefetch(visible.index, 1);
        if (page <= 1) _prefetch(visible.index, -1);
      }
    }
  }

  void _focus(_Chapter active, int page) {
    for (final c in _chapters) {
      if (c == active) {
        c.images.focus(page);
      } else if (c.index == _neighbour(active.index, 1) &&
          page >= active.keys.length - 3) {
        c.images.focus(0);
      } else if (c.index == _neighbour(active.index, -1) && page <= 1) {
        c.images.focus(c.keys.length - 1);
      } else {
        c.images.suspend();
      }
    }
  }

  void _prefetch(int from, int direction, {bool retry = false}) {
    final index = _neighbour(from, direction);
    if (!_valid ||
        index == null ||
        _pending.containsKey(index) ||
        _chapters.any((c) => c.index == index) ||
        (!retry && _errors.containsKey(index))) {
      return;
    }
    final epoch = _epoch;
    _pending[index] = epoch;
    _errors.remove(index);
    setState(() {});
    unawaited(() async {
      try {
        final data = await widget.loadChapter(index);
        if (!_valid ||
            epoch != _epoch ||
            _neighbour(from, direction) != index) {
          return;
        }
        final anchor = location;
        final chapter = _create(index, data);
        _chapters.add(chapter);
        _chapters.sort((a, b) => a.index.compareTo(b.index));
        while (_chapters.length > 3) {
          final active = anchor?.chapter ?? from;
          final firstDistance = (_chapters.first.index - active).abs();
          final lastDistance = (_chapters.last.index - active).abs();
          final removed = firstDistance > lastDistance
              ? _chapters.removeAt(0)
              : _chapters.removeLast();
          removed.images.dispose();
        }
        if (_chapters.contains(chapter)) {
          final active = _chapters
              .where((c) => c.index == location?.chapter)
              .firstOrNull;
          if (active != null) _focus(active, location!.page);
        }
        _layout(anchor);
      } catch (error) {
        if (_valid && epoch == _epoch) {
          _errors[index] = error;
          DiagnosticLogs.error('source', error, operation: 'chapter');
        }
      } finally {
        if (_pending[index] == epoch) _pending.remove(index);
        if (_valid && epoch == _epoch) setState(() {});
      }
    }());
  }

  void _ready(_Chapter chapter, int page, bool success) {
    if (!_valid || !_chapters.contains(chapter)) return;
    final changed = success
        ? chapter.decoded.add(page) | chapter.failed.remove(page)
        : chapter.failed.add(page) | chapter.decoded.remove(page);
    if (changed) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrolled());
    }
  }

  @override
  void didUpdateWidget(covariant ContinuousMangaReader oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.options.skipRead != widget.options.skipRead ||
        oldWidget.options.skipDuplicates != widget.options.skipDuplicates) {
      _epoch++;
      _pending.clear();
      _errors.clear();
      final active = location?.chapter;
      if (active != null) {
        final retained = {
          active,
          _neighbour(active, -1),
          _neighbour(active, 1),
        };
        for (final c in _chapters.toList()) {
          if (!retained.contains(c.index)) {
            _chapters.remove(c);
            c.images.dispose();
          }
        }
        _layout(location);
      }
    }
    if (oldWidget.margins != widget.margins ||
        oldWidget.options.gap != widget.options.gap ||
        oldWidget.options.imageScale != widget.options.imageScale) {
      _layout(location);
    }
  }

  @override
  void dispose() {
    _closed = true;
    _epoch++;
    widget.scroll.removeListener(_scrolled);
    for (final c in _chapters) {
      c.images.dispose();
    }
    super.dispose();
  }

  Widget _edge(_Chapter c, int direction) {
    final index = _neighbour(c.index, direction);
    if (index == null) {
      return direction < 0
          ? const SizedBox.shrink()
          : const Padding(
              padding: EdgeInsets.fromLTRB(20, 28, 20, 160),
              child: Text(
                'Đã đến cuối danh sách chương.',
                textAlign: TextAlign.center,
              ),
            );
    }
    final error = _errors[index];
    if (error == null && !_pending.containsKey(index)) {
      return const SizedBox(height: 24);
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 144),
      child: error == null
          ? Column(
              children: [
                Text(
                  'Đang tải ${widget.book.chapters[index].title}',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 16),
                const CircularProgressIndicator(),
              ],
            )
          : ReaderPageError(
              error: error,
              retryLabel: 'Thử lại chương',
              title: 'Không tải được chương tiếp nối',
              scrollable: false,
              onRetry: () => _prefetch(c.index, direction, retry: true),
            ),
    );
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, bounds) => SingleChildScrollView(
      key: widget.viewportKey,
      controller: widget.scroll,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_errors.containsKey(_neighbour(_chapters.first.index, -1)))
            _edge(_chapters.first, -1),
          for (final chapter in _chapters) ...[
            if (_chapters.indexOf(chapter) > 0)
              Padding(
                key: ValueKey('reader-transition-${chapter.index}'),
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 28,
                ),
                child: Column(
                  children: [
                    Text(
                      '${_chapters[_chapters.indexOf(chapter) - 1].completed ? 'Hoàn thành' : 'Chương trước'}:\n${widget.book.chapters[_chapters[_chapters.indexOf(chapter) - 1].index].title}',
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 40),
                    Text(
                      'Hiện tại:\n${widget.book.chapters[chapter.index].title}',
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                  ],
                ),
              ),
            for (var p = 0; p < chapter.keys.length; p++)
              Padding(
                key: chapter.keys[p],
                padding: EdgeInsets.fromLTRB(
                  widget.margins.left,
                  0,
                  widget.margins.right,
                  p + 1 == chapter.keys.length ? 0 : widget.options.gap,
                ),
                child: GestureDetector(
                  onLongPress: widget.options.holdScroll
                      ? null
                      : () => widget.onPageActions(chapter.index, p),
                  child: MangaPageLayout(
                    mode: widget.options.imageScale,
                    viewportHeight: bounds.maxHeight,
                    image: (width, height) => ZoomableMangaPage(
                      enabled: widget.options.zoom,
                      child: ColorFiltered(
                        colorFilter: widget.options.imageFilter,
                        child: ColorFiltered(
                          colorFilter: ColorFilter.mode(
                            Color(widget.options.tint)
                                .withValues(alpha: widget.options.tintOpacity),
                            widget.options.blendMode,
                          ),
                          child: SizedBox(
                            width:
                                width ??
                                (height == null
                                    ? chapter.images.pixelSizeAt(p)?.width ??
                                          MediaQuery.sizeOf(context).width
                                    : chapter.images.aspectRatioAt(p) * height),
                            height: height,
                            child: NativeMangaPage(
                              key: ValueKey(
                                'continuous-image:${chapter.index}:$p',
                              ),
                              image: chapter.images.imageAt(p),
                              aspectRatio: chapter.images.aspectRatioAt(p),
                              error: chapter.images.errorAt(p),
                              loading: chapter.images.wants(p),
                              onReady: (success) => _ready(chapter, p, success),
                              onRetry: () {
                                if (!_valid) {
                                  widget.onStale?.call();
                                  return;
                                }
                                chapter.images.retry(p);
                              },
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
          _edge(_chapters.last, 1),
        ],
      ),
    ),
  );
}
