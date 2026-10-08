import 'dart:async';
import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:flutter_widget_from_html_core/flutter_widget_from_html_core.dart';
import 'package:html/parser.dart' as html;
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/widgets/feedback.dart';
import '../../library/data/library_repository.dart';
import '../../library/domain/library_book.dart';
import '../../library/presentation/library_view_model.dart';
import '../../settings/settings_controller.dart';
import 'reader_settings_sheet.dart';

class ReaderScreen extends ConsumerStatefulWidget {
  const ReaderScreen({super.key, required this.id, this.chapter = 0});
  final String id;
  final int chapter;
  @override
  ConsumerState<ReaderScreen> createState() => _ReaderState();
}

class _ReadingLocation {
  const _ReadingLocation(this.chapter, this.position);
  final int chapter;
  final double position;
  static _ReadingLocation? parse(String mark, int count) {
    final values = mark.split(':');
    if (values.length != 2) return null;
    final chapter = int.tryParse(values[0]);
    final position = double.tryParse(values[1]);
    if (chapter == null ||
        chapter < 0 ||
        chapter >= count ||
        position == null ||
        !position.isFinite) {
      return null;
    }
    return _ReadingLocation(chapter, position.clamp(0.0, 1.0));
  }
}

class _ReaderState extends ConsumerState<ReaderScreen>
    with WidgetsBindingObserver {
  final scroll = ScrollController();
  final pages = PageController();
  final viewport = GlobalKey();
  final tts = FlutterTts();
  late final LibraryRepository repository;
  late final LibraryViewModel vm;
  late final SharedPreferences preferences;
  LibraryBook? book;
  ReaderContent? content;
  List<GlobalKey> imageKeys = [];
  final readyImages = <int>{};
  int current = 0, page = 0, generation = 0, requestedChapter = 0;
  double? requestedPosition;
  double position = 0;
  bool loading = true, chrome = true, speaking = false, restoring = false;
  String? error;
  Timer? debounce;
  DateTime? started;
  Future<void> timeWrites = Future<void>.value();
  String mangaMode = 'vertical';
  AppLifecycleState lifecycle = AppLifecycleState.resumed;

  @override
  void initState() {
    super.initState();
    repository = ref.read(libraryRepositoryProvider);
    vm = ref.read(libraryProvider.notifier);
    preferences = ref.read(preferencesProvider);
    mangaMode = ref.read(settingsProvider).mangaMode;
    lifecycle =
        WidgetsBinding.instance.lifecycleState ?? AppLifecycleState.resumed;
    WidgetsBinding.instance.addObserver(this);
    scroll.addListener(() {
      if (restoring || loading || !scroll.hasClients) return;
      captureScroll();
      debounce?.cancel();
      debounce = Timer(
        const Duration(milliseconds: 500),
        () => unawaited(persist()),
      );
    });
    unawaited(load(widget.chapter, resume: true));
  }

  @override
  void didUpdateWidget(covariant ReaderScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.id != widget.id || oldWidget.chapter != widget.chapter) {
      unawaited(
        persist().then((_) {
          if (mounted) return load(widget.chapter, resume: true);
        }),
      );
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    lifecycle = state;
    if (state == AppLifecycleState.resumed) {
      startReadingTime();
    } else {
      stopReadingTime();
      unawaited(persist());
      unawaited(stopSpeech());
    }
  }

  void startReadingTime() {
    if (!loading &&
        error == null &&
        content != null &&
        lifecycle == AppLifecycleState.resumed) {
      started ??= DateTime.now();
    }
  }

  void stopReadingTime() {
    final start = started;
    started = null;
    if (start == null) return;
    final end = DateTime.now();
    timeWrites = timeWrites
        .then((_) async {
          var cursor = start;
          while (cursor.isBefore(end)) {
            final midnight = DateTime(
              cursor.year,
              cursor.month,
              cursor.day + 1,
            );
            final until = end.isBefore(midnight) ? end : midnight;
            final seconds = until.difference(cursor).inSeconds;
            if (seconds > 0) {
              final key =
                  'readSeconds:${cursor.year}-${cursor.month}-${cursor.day}';
              await preferences.setInt(
                key,
                (preferences.getInt(key) ?? 0) + seconds,
              );
            }
            cursor = until;
          }
        })
        .catchError((Object e) {
          debugPrint('Cannot save reading time: $e');
        });
  }

  Future<void> stopSpeech() async {
    if (!speaking) return;
    speaking = false;
    try {
      await tts.stop();
    } catch (e) {
      debugPrint('Cannot stop speech: $e');
    }
    if (mounted) setState(() {});
  }

  Future<void> load(int index, {bool resume = false, double? offset}) async {
    final request = ++generation;
    debounce?.cancel();
    stopReadingTime();
    await stopSpeech();
    if (!mounted || request != generation) return;
    setState(() {
      loading = true;
      error = null;
      restoring = true;
      requestedChapter = index;
      requestedPosition = offset;
    });
    try {
      final item = await repository.find(widget.id);
      if (item == null || item.chapters.isEmpty) {
        throw StateError('Sách chưa có chương để đọc');
      }
      index = index.clamp(0, item.chapters.length - 1);
      final chapterId = item.chapters[index].id;
      final fraction =
          offset ??
          (resume && item.currentChapter == index
              ? (item.progress * item.chapters.length - index).clamp(0.0, 1.0)
              : 0.0);
      final data = await vm.getContent(item, index);
      final latest = await repository.find(item.id);
      if (!mounted || request != generation) return;
      if (latest == null) throw StateError('Sách đã được xóa khỏi thư viện');
      final mapped = latest.chapters.indexWhere((c) => c.id == chapterId);
      if (mapped < 0) throw StateError('Chương không còn trong mục lục');
      setState(() {
        book = latest;
        content = data;
        current = mapped;
        position = fraction.clamp(0, 1);
        page = data.images.isEmpty
            ? 0
            : (position * data.images.length).floor().clamp(
                0,
                data.images.length - 1,
              );
        imageKeys = List.generate(data.images.length, (_) => GlobalKey());
        readyImages.clear();
        loading = false;
      });
      startReadingTime();
      restoreLocation(request);
      await persist();
    } catch (e) {
      if (mounted && request == generation) {
        setState(() {
          error = '$e';
          loading = false;
          restoring = false;
        });
      }
    }
  }

  void captureScroll() {
    if (!scroll.hasClients || content == null) return;
    if (content!.kind == 'manga' &&
        mangaMode == 'vertical' &&
        imageKeys.isNotEmpty) {
      final viewportBox = viewport.currentContext?.findRenderObject();
      if (viewportBox is! RenderBox) return;
      final top = viewportBox.localToGlobal(Offset.zero).dy;
      for (var i = 0; i < imageKeys.length; i++) {
        final box = imageKeys[i].currentContext?.findRenderObject();
        if (box is! RenderBox || box.size.height <= 0) continue;
        final relativeTop = box.localToGlobal(Offset.zero).dy - top;
        if (relativeTop + box.size.height > 0) {
          final within = (-relativeTop / box.size.height).clamp(0.0, 1.0);
          position = (i + within) / imageKeys.length;
          page = i;
          break;
        }
      }
      if (scroll.position.maxScrollExtent > 0 &&
          scroll.offset >= scroll.position.maxScrollExtent - 1) {
        position = 1;
      }
    } else if (scroll.position.maxScrollExtent > 0) {
      position = (scroll.offset / scroll.position.maxScrollExtent).clamp(
        0.0,
        1.0,
      );
    }
  }

  void restoreLocation(int request) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || request != generation || content == null) return;
      final manga = content!.kind == 'manga';
      if (manga && mangaMode != 'vertical') {
        if (pages.hasClients && content!.images.isNotEmpty) {
          pages.jumpToPage(page);
        }
      } else if (scroll.hasClients) {
        if (manga && imageKeys.isNotEmpty) {
          // Natural image heights arrive asynchronously. Keep the saved location until all images have laid out.
          if (readyImages.length < imageKeys.length) return;
          final raw = position * imageKeys.length;
          final index = raw.floor().clamp(0, imageKeys.length - 1);
          final box = imageKeys[index].currentContext?.findRenderObject();
          final viewportBox = viewport.currentContext?.findRenderObject();
          if (box is RenderBox && viewportBox is RenderBox) {
            final offset =
                scroll.offset +
                box.localToGlobal(Offset.zero).dy -
                viewportBox.localToGlobal(Offset.zero).dy +
                box.size.height * (raw - index).clamp(0.0, 1.0);
            scroll.jumpTo(offset.clamp(0.0, scroll.position.maxScrollExtent));
          }
        } else {
          scroll.jumpTo(
            (position * scroll.position.maxScrollExtent).clamp(
              0.0,
              scroll.position.maxScrollExtent,
            ),
          );
        }
      }
      restoring = false;
    });
  }

  Future<void> persist() async {
    if (book == null || content == null || loading || error != null) return;
    final id = book!.id;
    final chapterId = book!.chapters[current].id;
    final fraction = position;
    try {
      await vm.updateProgress(id, chapterId, fraction);
    } catch (e) {
      if (mounted) {
        message(context, 'Chưa lưu được tiến độ: $e');
      } else {
        debugPrint('Cannot save reading progress: $e');
      }
    }
  }

  Future<void> bookmark() async {
    if (book == null || loading) return;
    await perform(context, () async {
      final added = await vm.toggleBookmark(
        book!.id,
        book!.chapters[current].id,
        position,
      );
      if (mounted) {
        message(context, added ? 'Đã lưu dấu trang' : 'Đã xóa dấu trang');
      }
    });
  }

  Future<void> contents() async {
    final b = await repository.find(widget.id);
    if (b == null || !mounted) return;
    var tab = 'chapters';
    final marks = b.bookmarks
        .where(
          (mark) => _ReadingLocation.parse(mark, b.chapters.length) != null,
        )
        .toList();
    final location = await showModalBottomSheet<_ReadingLocation>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, updateSheet) {
          final separator = CupertinoDynamicColor.resolve(
            CupertinoColors.separator,
            ctx,
          );
          final secondary = CupertinoDynamicColor.resolve(
            CupertinoColors.secondaryLabel,
            ctx,
          );
          return SafeArea(
            child: SizedBox(
              height: MediaQuery.sizeOf(ctx).height * .7,
              child: Column(
                children: [
                  SizedBox(
                    height: 44,
                    child: Row(
                      children: [
                        const SizedBox(width: 16),
                        const Text(
                          'Mục lục',
                          style: TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const Spacer(),
                        CupertinoButton(
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          onPressed: () => Navigator.pop(ctx),
                          child: const Text(
                            'Xong',
                            style: TextStyle(fontSize: 17),
                          ),
                        ),
                      ],
                    ),
                  ),
                  Divider(height: .5, thickness: .5, color: separator),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                    child: SizedBox(
                      width: double.infinity,
                      child: CupertinoSlidingSegmentedControl<String>(
                        groupValue: tab,
                        children: const {
                          'chapters': Text('Chương'),
                          'bookmarks': Text('Dấu trang'),
                        },
                        onValueChanged: (value) {
                          if (value != null) updateSheet(() => tab = value);
                        },
                      ),
                    ),
                  ),
                  Expanded(
                    child: tab == 'chapters'
                        ? ListView.separated(
                            itemCount: b.chapters.length,
                            separatorBuilder: (_, _) => Divider(
                              height: .5,
                              thickness: .5,
                              indent: 16,
                              color: separator,
                            ),
                            itemBuilder: (_, i) => ListTile(
                              minTileHeight: 52,
                              contentPadding: const EdgeInsets.symmetric(
                                horizontal: 16,
                              ),
                              title: Text(
                                b.chapters[i].title,
                                style: const TextStyle(fontSize: 15),
                              ),
                              trailing:
                                  b.chapters[i].id == book?.chapters[current].id
                                  ? const Icon(
                                      CupertinoIcons.checkmark,
                                      size: 19,
                                      color: CupertinoColors.activeBlue,
                                    )
                                  : b.chapters[i].downloaded
                                  ? Icon(
                                      CupertinoIcons.checkmark_circle_fill,
                                      size: 19,
                                      color: secondary,
                                    )
                                  : null,
                              onTap: () =>
                                  Navigator.pop(ctx, _ReadingLocation(i, 0)),
                            ),
                          )
                        : marks.isEmpty
                        ? Center(
                            child: Text(
                              'Chưa có dấu trang',
                              style: TextStyle(color: secondary, fontSize: 15),
                            ),
                          )
                        : ListView.separated(
                            itemCount: marks.length,
                            separatorBuilder: (_, _) => Divider(
                              height: .5,
                              thickness: .5,
                              indent: 16,
                              color: separator,
                            ),
                            itemBuilder: (_, i) {
                              final mark = marks[i];
                              final markLocation = _ReadingLocation.parse(
                                mark,
                                b.chapters.length,
                              )!;
                              return ListTile(
                                minTileHeight: 54,
                                contentPadding: const EdgeInsets.only(
                                  left: 16,
                                  right: 4,
                                ),
                                title: Text(
                                  b.chapters[markLocation.chapter].title,
                                  style: const TextStyle(fontSize: 15),
                                ),
                                subtitle: Text(
                                  '${(markLocation.position * 100).round()}% trong chương',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: secondary,
                                  ),
                                ),
                                onTap: () => Navigator.pop(ctx, markLocation),
                                trailing: IconButton(
                                  tooltip: 'Xóa dấu trang',
                                  icon: const Icon(
                                    CupertinoIcons.clear,
                                    size: 19,
                                  ),
                                  onPressed: () async {
                                    await vm.removeBookmark(b.id, mark);
                                    if (ctx.mounted) {
                                      updateSheet(() => marks.remove(mark));
                                    }
                                  },
                                ),
                              );
                            },
                          ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
    if (location != null && mounted) {
      await persist();
      await load(location.chapter, offset: location.position);
    }
  }

  Future<void> speak() async {
    if (speaking) {
      await stopSpeech();
      return;
    }
    await perform(context, () async {
      if (content == null) return;
      await tts.setLanguage('vi-VN');
      await tts.setSpeechRate(.45);
      tts.setCompletionHandler(() {
        if (mounted) setState(() => speaking = false);
      });
      tts.setErrorHandler((error) {
        if (mounted) {
          setState(() => speaking = false);
          message(context, error);
        }
      });
      if (!mounted) return;
      setState(() => speaking = true);
      await tts.speak(html.parse(content!.html).body?.text ?? '');
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    debounce?.cancel();
    generation++;
    stopReadingTime();
    unawaited(persist());
    if (speaking) unawaited(tts.stop().catchError((Object e) => 0));
    scroll.dispose();
    pages.dispose();
    super.dispose();
  }

  void imageReady(int index, int request) {
    if (index < 0) return;
    if (request != generation || !readyImages.add(index)) return;
    if (restoring && readyImages.length == imageKeys.length) {
      restoreLocation(request);
    }
  }

  Widget image(String url, int index) {
    final request = generation;
    Widget failed(Object error) {
      imageReady(index, request);
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Text('Không tải được ảnh. $error'),
      );
    }

    Widget frame(
      BuildContext context,
      Widget child,
      int? frame,
      bool synchronouslyLoaded,
    ) {
      if (frame != null || synchronouslyLoaded) imageReady(index, request);
      return child;
    }

    if (url.startsWith('data:')) {
      try {
        return Image.memory(
          base64Decode(url.substring(url.indexOf(',') + 1)),
          fit: BoxFit.contain,
          frameBuilder: frame,
          errorBuilder: (_, error, _) => failed(error),
        );
      } catch (e) {
        return failed(e);
      }
    }
    return Image.network(
      url,
      headers: content?.headersFor(url),
      fit: BoxFit.contain,
      frameBuilder: frame,
      loadingBuilder: (_, child, progress) => progress == null
          ? child
          : const Padding(
              padding: EdgeInsets.all(40),
              child: Center(child: CircularProgressIndicator()),
            ),
      errorBuilder: (_, error, _) => failed(error),
    );
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
    ref.listen(settingsProvider, (previous, next) {
      if (content == null || loading) {
        mangaMode = next.mangaMode;
        return;
      }
      if (previous?.mangaMode != next.mangaMode ||
          previous?.font != next.font ||
          previous?.fontSize != next.fontSize ||
          previous?.lineHeight != next.lineHeight) {
        if (previous?.mangaMode != next.mangaMode) {
          readyImages.clear();
        }
        mangaMode = next.mangaMode;
        page = content!.images.isEmpty
            ? 0
            : (position * content!.images.length).floor().clamp(
                0,
                content!.images.length - 1,
              );
        restoring = true;
        restoreLocation(generation);
      }
    });
    final night = settings.readerTheme == 'night';
    final background = night
        ? const Color(0xFF161616)
        : settings.readerTheme == 'sepia'
        ? const Color(0xFFF5EBDC)
        : Colors.white;
    final foreground = night
        ? const Color(0xFFD8D8D8)
        : const Color(0xFF1C1C1E);
    final toolbar = night ? const Color(0xFF1C1C1E) : const Color(0xFFF9F9F9);
    final separator = night ? const Color(0xFF38383A) : const Color(0xFFC6C6C8);
    const blue = Color(0xFF007AFF);
    final manga = content?.kind == 'manga';
    return Theme(
      data: Theme.of(context).copyWith(
        brightness: night ? Brightness.dark : Brightness.light,
        appBarTheme: AppBarTheme(
          backgroundColor: toolbar,
          foregroundColor: foreground,
          toolbarHeight: 44,
          centerTitle: true,
          titleTextStyle: TextStyle(
            fontSize: 17,
            fontWeight: FontWeight.w600,
            color: foreground,
          ),
          iconTheme: const IconThemeData(color: blue, size: 22),
          actionsIconTheme: const IconThemeData(color: blue, size: 22),
          surfaceTintColor: Colors.transparent,
        ),
      ),
      child: Scaffold(
        backgroundColor: background,
        appBar: chrome
            ? AppBar(
                toolbarHeight: 44,
                centerTitle: true,
                leadingWidth: 44,
                leading: IconButton(
                  tooltip: 'Quay lại',
                  icon: const Icon(CupertinoIcons.back),
                  onPressed: () => Navigator.of(context).maybePop(),
                ),
                bottom: PreferredSize(
                  preferredSize: const Size.fromHeight(.5),
                  child: Divider(height: .5, thickness: .5, color: separator),
                ),
                title: Text(
                  book == null ? 'Đang mở' : book!.chapters[current].title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: foreground,
                    fontSize: 17,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                actions: [
                  if (!manga && content != null)
                    IconButton(
                      tooltip: 'Đọc thành tiếng',
                      onPressed: loading ? null : speak,
                      icon: Icon(
                        speaking
                            ? CupertinoIcons.stop_circle
                            : CupertinoIcons.speaker_2,
                      ),
                    ),
                  IconButton(
                    tooltip: 'Đánh dấu trang',
                    onPressed: content == null || loading ? null : bookmark,
                    icon: const Icon(CupertinoIcons.bookmark),
                  ),
                  IconButton(
                    tooltip: 'Giao diện đọc',
                    onPressed: () => showReaderSettings(context, manga: manga),
                    icon: const Icon(CupertinoIcons.textformat_size),
                  ),
                ],
              )
            : null,
        body: SafeArea(
          top: false,
          bottom: false,
          child: loading
              ? const Center(child: CupertinoActivityIndicator())
              : error != null
              ? EmptyPanel(
                  icon: Icons.wifi_off_rounded,
                  title: 'Chưa mở được chương',
                  description: error!,
                  action: CupertinoButton.filled(
                    onPressed: () => load(
                      requestedChapter,
                      resume: true,
                      offset: requestedPosition,
                    ),
                    child: const Text('Thử lại'),
                  ),
                )
              : GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onTap: () {
                    setState(() {
                      chrome = !chrome;
                      restoring = true;
                    });
                    restoreLocation(generation);
                  },
                  child: manga && settings.mangaMode != 'vertical'
                      ? PageView.builder(
                          key: ValueKey('$current:${settings.mangaMode}'),
                          reverse: settings.mangaMode == 'rtl',
                          controller: pages,
                          itemCount: content!.images.length,
                          onPageChanged: (p) {
                            if (restoring) return;
                            page = p;
                            position = p / content!.images.length;
                            unawaited(persist());
                          },
                          itemBuilder: (_, i) => InteractiveViewer(
                            minScale: 1,
                            maxScale: 4,
                            child: Center(child: image(content!.images[i], i)),
                          ),
                        )
                      : SingleChildScrollView(
                          key: viewport,
                          controller: scroll,
                          padding: manga
                              ? EdgeInsets.zero
                              : const EdgeInsets.fromLTRB(26, 24, 26, 80),
                          child: manga
                              ? Column(
                                  children: List.generate(
                                    content!.images.length,
                                    (i) => Padding(
                                      key: imageKeys[i],
                                      padding: EdgeInsets.zero,
                                      child: image(content!.images[i], i),
                                    ),
                                  ),
                                )
                              : Center(
                                  child: ConstrainedBox(
                                    constraints: const BoxConstraints(
                                      maxWidth: 720,
                                    ),
                                    child: SelectionArea(
                                      child: HtmlWidget(
                                        content!.html,
                                        customWidgetBuilder: (element) {
                                          if (element.localName == 'img') {
                                            final source =
                                                element.attributes['src'];
                                            if (source != null) {
                                              return image(source, -1);
                                            }
                                          }
                                          return null;
                                        },
                                        textStyle: TextStyle(
                                          fontFamily:
                                              settings.font == 'Arial' ||
                                                  settings.font == 'NotoSans'
                                              ? 'NotoSans'
                                              : 'NotoSerif',
                                          fontSize: settings.fontSize,
                                          height: settings.lineHeight,
                                          color: foreground,
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                        ),
                ),
        ),
        bottomNavigationBar: chrome && book != null
            ? SafeArea(
                child: Container(
                  decoration: BoxDecoration(
                    color: toolbar,
                    border: Border(
                      top: BorderSide(color: separator, width: .5),
                    ),
                  ),
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Row(
                    children: [
                      IconButton(
                        tooltip: 'Chương trước',
                        color: blue,
                        iconSize: 20,
                        onPressed: loading || current <= 0
                            ? null
                            : () async {
                                await persist();
                                if (mounted) await load(current - 1);
                              },
                        icon: const Icon(CupertinoIcons.chevron_left),
                      ),
                      Expanded(
                        child: TextButton(
                          onPressed: loading ? null : contents,
                          child: Text(
                            '${current + 1} / ${book!.chapters.length}  ·  Mục lục',
                            style: const TextStyle(fontSize: 15, color: blue),
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: 'Chương tiếp theo',
                        color: blue,
                        iconSize: 20,
                        onPressed:
                            loading || current >= book!.chapters.length - 1
                            ? null
                            : () async {
                                await persist();
                                if (mounted) await load(current + 1);
                              },
                        icon: const Icon(CupertinoIcons.chevron_right),
                      ),
                    ],
                  ),
                ),
              )
            : null,
      ),
    );
  }
}
