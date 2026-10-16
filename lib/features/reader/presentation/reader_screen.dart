import 'dart:async';
import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:flutter_widget_from_html_core/flutter_widget_from_html_core.dart';
import 'package:html/parser.dart' as html;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:file_picker/file_picker.dart';

import '../../../core/widgets/feedback.dart';
import '../../../core/diagnostics/diagnostic_log.dart';
import '../../../core/platform/reader_platform.dart';
import '../../downloads/presentation/download_queue_controller.dart';
import '../../downloads/presentation/download_deletion_controller.dart';
import '../../library/application/library_update_scheduler.dart';
import '../../library/data/library_repository.dart';
import '../../library/data/library_mutation.dart';
import '../../library/domain/library_book.dart';
import '../../library/domain/library_reading.dart';
import '../../library/presentation/library_view_model.dart';
import '../../settings/settings_controller.dart';
import '../../settings/presentation/log_diagnostics_screen.dart';
import '../../sources/domain/catalogue.dart';
import 'reader_settings_sheet.dart';
import 'reader_controls.dart';
import 'native_manga_image_window.dart';
import '../domain/reader_options.dart';
import 'reader_options_controller.dart';
import 'reader_system_ui.dart';
import 'zoomable_manga_page.dart';
import 'reader_auto_scroll.dart';
import 'reader_keyboard_controls.dart';
import 'reader_hold_scroll.dart';
import 'manga_page_layout.dart';
import 'reader_tap_zones.dart';
import 'reader_pinch_scroll_guard.dart';

class ReaderScreen extends ConsumerStatefulWidget {
  const ReaderScreen({
    super.key,
    required this.id,
    this.chapter = 0,
    this.chapterId,
    this.expectedRevision,
  });
  final String id;
  final int chapter;
  final String? chapterId;
  final int? expectedRevision;
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
  final systemUi = ReaderSystemUiLease();
  bool allowBack = false;
  Orientation? layoutOrientation;
  late final ReaderAutoScroll autoScroll;
  final viewport = GlobalKey();
  final tts = FlutterTts();
  late final LibraryRepository repository;
  late final LibraryViewModel vm;
  late final SharedPreferences preferences;
  late final DownloadDeletionController downloadDeletion;
  late final bool incognitoSession;
  LibraryBook? book;
  ReaderContent? content;
  int? loadedRevision;
  List<GlobalKey> imageKeys = [];
  final readyImages = <int>{};
  final decodedImages = <int>{};
  final failedImages = <int>{};
  final memoryImageBytes = <String, Uint8List>{};
  NativeMangaImageWindow? nativeImages;
  int current = 0, page = 0, generation = 0, requestedChapter = 0;
  double? requestedPosition;
  int? pendingPageSeek;
  String? requestedChapterId;
  double position = 0;
  bool loading = true, chrome = true, speaking = false, restoring = false;
  bool autoScrollPaused = false;
  String? error;
  Timer? debounce;
  DateTime? started;
  Future<void> timeWrites = Future<void>.value();
  bool downloading = false, orientationChanged = false;
  AppLifecycleState lifecycle = AppLifecycleState.resumed;
  ReaderOptions options = const ReaderOptions();
  String appliedOrientation = 'free';
  bool awake = false;
  bool holdingScroll = false;
  bool closing = false;
  int modalDepth = 0;
  double heldSpeed = 40;

  @override
  void initState() {
    super.initState();
    autoScroll = ReaderAutoScroll(
      scroll,
      canScroll: () =>
          mounted &&
          !loading &&
          !restoring &&
          modalDepth == 0 &&
          error == null &&
          (ModalRoute.of(context)?.isCurrent ?? true) &&
          lifecycle == AppLifecycleState.resumed,
      onNextPage: () {
        final data = content;
        if (data?.kind == 'manga') {
          if (page + 1 < data!.images.length) seek((page + 1).toDouble());
        } else if (scroll.hasClients) {
          scroll.jumpTo(
            (scroll.offset + scroll.position.viewportDimension * .9).clamp(
              0.0,
              scroll.position.maxScrollExtent,
            ),
          );
        }
      },
    );
    repository = ref.read(libraryRepositoryProvider);
    vm = ref.read(libraryProvider.notifier);
    preferences = ref.read(preferencesProvider);
    downloadDeletion = ref.read(downloadDeletionProvider.notifier);
    // Privacy is fixed for this reader session, including delayed writes and
    // disposal. Changing the setting takes effect when opening a new reader.
    incognitoSession = ref.read(settingsProvider).incognitoMode;
    lifecycle =
        WidgetsBinding.instance.lifecycleState ?? AppLifecycleState.resumed;
    WidgetsBinding.instance.addObserver(this);
    scroll.addListener(() {
      if (restoring || loading || !scroll.hasClients) return;
      final previousPage = page;
      final previousPercent = (position * 100).round();
      captureScroll();
      if (mounted &&
          (page != previousPage ||
              (position * 100).round() != previousPercent)) {
        setState(() {});
      }
      nativeImages?.focus(page);
      debounce?.cancel();
      debounce = Timer(
        const Duration(milliseconds: 500),
        () => unawaited(persist()),
      );
    });
    unawaited(load(widget.chapter, resume: true, chapterId: widget.chapterId));
  }

  @override
  void didUpdateWidget(covariant ReaderScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.id != widget.id ||
        oldWidget.chapter != widget.chapter ||
        oldWidget.chapterId != widget.chapterId ||
        oldWidget.expectedRevision != widget.expectedRevision) {
      unawaited(
        persist().then((_) {
          if (mounted) {
            return load(
              widget.chapter,
              resume: true,
              chapterId: widget.chapterId,
            );
          }
        }),
      );
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    lifecycle = state;
    if (state == AppLifecycleState.resumed) {
      startReadingTime();
      applyOptions(options);
    } else {
      autoScroll.pause();
      awake = false;
      unawaited(ReaderPlatform.keepAwake(false));
      stopReadingTime();
      unawaited(persist());
      unawaited(stopSpeech());
    }
  }

  void startReadingTime() {
    if (!incognitoSession &&
        !loading &&
        error == null &&
        content != null &&
        lifecycle == AppLifecycleState.resumed) {
      started ??= DateTime.now();
    }
  }

  void stopReadingTime() {
    final start = started;
    started = null;
    if (incognitoSession || start == null) return;
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

  Future<void> load(
    int index, {
    bool resume = false,
    double? offset,
    String? chapterId,
  }) async {
    final request = ++generation;
    nativeImages?.dispose();
    nativeImages = null;
    final revision = widget.expectedRevision ?? repository.replacementRevision;
    debounce?.cancel();
    stopReadingTime();
    await stopSpeech();
    if (!mounted || request != generation) return;
    setState(() {
      loading = true;
      error = null;
      restoring = true;
      requestedChapter = index;
      requestedChapterId = chapterId;
      requestedPosition = offset;
    });
    try {
      checkLibraryRevision(repository.replacementRevision, revision);
      final item = await repository.find(widget.id);
      checkLibraryRevision(repository.replacementRevision, revision);
      if (item == null || item.chapters.isEmpty) {
        throw StateError('Sách chưa có chương để đọc');
      }
      if (chapterId != null) {
        index = item.chapters.indexWhere((chapter) => chapter.id == chapterId);
        if (index < 0) throw StateError('Chương không còn trong mục lục.');
      } else {
        index = index.clamp(0, item.chapters.length - 1);
      }
      final openingChapterId = item.chapters[index].id;
      final fraction =
          offset ??
          (resume && item.currentChapter == index
              ? (item.progress * item.chapters.length - index).clamp(0.0, 1.0)
              : 0.0);
      final data = await vm.getContent(item, index, expectedRevision: revision);
      final latest = await repository.find(item.id);
      if (!mounted || request != generation) return;
      if (repository.replacementRevision != revision) {
        throw StateError(
          'Thư viện đã thay đổi. Hãy mở lại chương từ thư viện.',
        );
      }
      if (latest == null) throw StateError('Sách đã được xóa khỏi thư viện');
      final mapped = latest.chapters.indexWhere(
        (c) => c.id == openingChapterId,
      );
      if (mapped < 0) throw StateError('Chương không còn trong mục lục');
      setState(() {
        book = latest;
        content = data;
        loadedRevision = revision;
        current = mapped;
        position = fraction.clamp(0, 1);
        page = data.images.isEmpty
            ? 0
            : (position * data.images.length).floor().clamp(
                0,
                data.images.length - 1,
              );
        imageKeys = List.generate(data.images.length, (_) => GlobalKey());
        pendingPageSeek = null;
        readyImages.clear();
        decodedImages.clear();
        failedImages.clear();
        memoryImageBytes.clear();
        loading = false;
      });
      final source = ref.read(sourceRepositoryProvider);
      if (data.kind == 'manga' &&
          data.images.isNotEmpty &&
          (data.images.every((url) => url.startsWith('data:')) ||
              source.usesNativeImageLoader(vm.catalogue(latest)))) {
        final chapter = latest.chapters[mapped];
        final window = NativeMangaImageWindow(
          count: data.images.length,
          fetch: (i) async {
            checkLibraryRevision(repository.replacementRevision, revision);
            final url = data.images[i];
            if (url.startsWith('data:')) {
              return SourceImageData(
                bytes: base64Decode(url.substring(url.indexOf(',') + 1)),
                mimeType: 'image/*',
              );
            }
            final image = await source.fetchImage(
              vm.catalogue(latest),
              CatalogueChapter(
                ref: chapter.id,
                title: chapter.title,
                index: chapter.index,
              ),
              i,
              url,
            );
            checkLibraryRevision(repository.replacementRevision, revision);
            return image;
          },
        );
        nativeImages = window;
        window.addListener(() {
          if (!mounted || request != generation) return;
          // Keep the logical page and its within-page fraction while natural
          // heights replace placeholders, including pages above the viewport.
          setState(() => restoring = true);
          restoreLocation(request);
        });
        window.focus(page);
      }
      startReadingTime();
      restoreLocation(request);
      await persist();
      if (mounted && request == generation) {
        unawaited(
          ref
              .read(libraryUpdateSchedulerProvider)
              .downloadAhead(
                latest,
                openingChapterId,
                expectedRevision: revision,
              )
              .catchError((Object error) {
                debugPrint('Download ahead: $error');
                return 0;
              }),
        );
      }
    } catch (e) {
      if (mounted && request == generation) {
        DiagnosticLogs.error('source', e);
        setState(() {
          error = userFacingError(e);
          loading = false;
          restoring = false;
        });
      }
    }
  }

  void captureScroll() {
    if (!scroll.hasClients || content == null) return;
    if (content!.kind == 'manga' && imageKeys.isNotEmpty) {
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
        page = imageKeys.length - 1;
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
      if (scroll.hasClients) {
        if (manga && imageKeys.isNotEmpty) {
          // Native pages have stable estimated/cached heights outside a bounded
          // image window. Seek immediately; a slow unrelated page cannot block
          // the saved location or slider while its bytes arrive.
          if (nativeImages == null && readyImages.length < imageKeys.length) {
            return;
          }
          final raw = position * imageKeys.length;
          final index = (pendingPageSeek ?? raw.floor()).clamp(
            0,
            imageKeys.length - 1,
          );
          final box = imageKeys[index].currentContext?.findRenderObject();
          final viewportBox = viewport.currentContext?.findRenderObject();
          if (box is RenderBox && viewportBox is RenderBox) {
            final offset =
                scroll.offset +
                box.localToGlobal(Offset.zero).dy -
                viewportBox.localToGlobal(Offset.zero).dy +
                box.size.height *
                    (pendingPageSeek == null
                        ? (raw - index).clamp(0.0, 1.0)
                        : 0);
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
      pendingPageSeek = null;
      if (mangaChapterCompleted) unawaited(persist());
    });
  }

  Future<void> persist() async {
    if (incognitoSession) return;
    if (book == null || content == null || loading || error != null) return;
    final id = book!.id;
    final chapterId = book!.chapters[current].id;
    final fraction = position;
    try {
      await vm.updateProgress(
        id,
        chapterId,
        fraction,
        chapterCompleted: mangaChapterCompleted,
        inferCompletionFromFraction: content!.kind != 'manga',
        expectedRevision: loadedRevision,
      );
    } catch (e) {
      if (mounted) {
        message(context, 'Chưa lưu được tiến độ: $e');
      } else {
        debugPrint('Cannot save reading progress: $e');
      }
    }
  }

  bool get mangaChapterCompleted =>
      !restoring &&
      content?.kind == 'manga' &&
      content!.images.isNotEmpty &&
      scroll.hasClients &&
      (scroll.position.maxScrollExtent > 1
          ? scroll.offset >= scroll.position.maxScrollExtent - 1
          : decodedImages.length == content!.images.length) &&
      decodedImages.contains(content!.images.length - 1) &&
      failedImages.isEmpty;

  Future<void> bookmark() async {
    if (book == null || loading) return;
    await perform(context, () async {
      final added = await vm.toggleBookmark(
        book!.id,
        book!.chapters[current].id,
        position,
        expectedRevision: loadedRevision,
      );
      if (mounted) {
        message(context, added ? 'Đã lưu dấu trang' : 'Đã xóa dấu trang');
      }
    });
  }

  // Keep the timer paused across nested settings, image actions and native
  // pickers. A dismissed child sheet must not resume behind its parent.
  Future<T> readerModal<T>(Future<T> Function() action) async {
    modalDepth++;
    autoScroll.pause();
    try {
      return await action();
    } finally {
      modalDepth--;
      if (mounted && !closing) applyOptions(options);
    }
  }

  Future<void> contents() => readerModal(_contents);

  Future<void> _contents() async {
    final revision = loadedRevision;
    final b = await perform(context, () async {
      checkLibraryRevision(repository.replacementRevision, revision);
      final item = await repository.find(widget.id);
      checkLibraryRevision(repository.replacementRevision, revision);
      return item;
    });
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
                                    final removed = await perform(
                                      ctx,
                                      () async {
                                        await vm.removeBookmark(
                                          b.id,
                                          mark,
                                          expectedRevision: revision,
                                        );
                                        return true;
                                      },
                                    );
                                    if (removed == true && ctx.mounted) {
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
      await perform(context, () async {
        checkLibraryRevision(repository.replacementRevision, revision);
        final latest = await repository.find(b.id);
        checkLibraryRevision(repository.replacementRevision, revision);
        if (latest == null ||
            bookSourceIdentity(latest) != bookSourceIdentity(b)) {
          throw StateError('Sách hoặc nguồn đã thay đổi. Hãy mở lại sách.');
        }
        final chapterId = b.chapters[location.chapter].id;
        final index = latest.chapters.indexWhere((c) => c.id == chapterId);
        if (index < 0) throw StateError('Chương không còn trong mục lục.');
        await persist();
        checkLibraryRevision(repository.replacementRevision, revision);
        if (mounted) {
          await load(index, offset: location.position, chapterId: chapterId);
        }
      });
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

  void seek(double value) {
    if (loading || content == null) return;
    final manga = content!.kind == 'manga';
    if (manga && content!.images.isEmpty) return;
    setState(() {
      if (manga) {
        page = value.round().clamp(0, content!.images.length - 1);
        pendingPageSeek = page;
        position = page / content!.images.length;
      } else {
        position = value.clamp(0, 1);
      }
      restoring = true;
    });
    nativeImages?.focus(page);
    restoreLocation(generation);
    unawaited(persist());
  }

  Future<void> changeChapter(int offset) async {
    var target = current + offset;
    final item = book;
    final seen = <String>{
      if (item != null) item.chapters[current].title.trim().toLowerCase(),
    };
    while (item != null && target >= 0 && target < item.chapters.length) {
      final chapter = item.chapters[target];
      if (!(options.skipRead && chapterIsRead(item, target)) &&
          !(options.skipDuplicates &&
              !seen.add(chapter.title.trim().toLowerCase()))) {
        break;
      }
      target += offset;
    }
    if (item == null || target < 0 || target >= item.chapters.length) return;
    final chapterId = item.chapters[target].id;
    await persist();
    if (mounted) await load(target, chapterId: chapterId);
  }

  Future<void> pageActions(int index) => readerModal(() => _pageActions(index));

  Future<void> _pageActions(int index) async {
    final item = book, data = content, revision = loadedRevision;
    if (item == null ||
        data == null ||
        index < 0 ||
        index >= data.images.length) {
      return;
    }
    final chapterId = item.chapters[current].id;
    final request = generation;
    final action = await showCupertinoModalPopup<String>(
      context: context,
      builder: (ctx) => CupertinoActionSheet(
        title: Text('Trang ${index + 1}'),
        actions: [
          for (final pair in const {
            'cover': 'Đặt làm ảnh bìa',
            'save': 'Lưu ảnh vào Tệp',
            'photos': 'Lưu vào Ảnh',
            'copy': 'Sao chép ảnh',
            'share': 'Chia sẻ ảnh',
            'ocr': 'Nhận dạng chữ trong ảnh',
          }.entries)
            CupertinoActionSheetAction(
              onPressed: () => Navigator.pop(ctx, pair.key),
              child: Text(pair.value),
            ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('Hủy'),
        ),
      ),
    );
    if (action == null || !mounted || request != generation) return;
    await perform(context, () async {
      checkLibraryRevision(repository.replacementRevision, revision);
      final cached = nativeImages?.imageAt(index)?.data;
      final url = data.images[index];
      final SourceImageData imageData;
      if (cached != null) {
        imageData = cached;
      } else if (url.startsWith('data:')) {
        imageData = SourceImageData(
          bytes: base64Decode(url.substring(url.indexOf(',') + 1)),
          mimeType: url.substring(5, url.indexOf(';')),
        );
      } else {
        imageData = await ref
            .read(sourceRepositoryProvider)
            .fetchImage(
              vm.catalogue(item),
              CatalogueChapter(
                ref: chapterId,
                title: item.chapters[current].title,
                index: current,
              ),
              index,
              url,
            );
      }
      if (!mounted || request != generation) return;
      checkLibraryRevision(repository.replacementRevision, revision);
      if (imageData.bytes.isEmpty ||
          imageData.bytes.length > LibraryRepository.maxImageBytes) {
        throw StateError('Ảnh vượt giới hạn 8 MB.');
      }
      if (action == 'cover') {
        // Inline bytes participate in full snapshot backup. Avoid an orphaned
        // attachment file if the library is replaced while the menu is open.
        await vm.updateMetadata(
          item.id,
          cover:
              'data:${imageData.mimeType};base64,${base64Encode(imageData.bytes)}',
          expectedRevision: revision,
        );
        if (mounted) message(context, 'Đã đổi ảnh bìa.');
      } else if (action == 'save') {
        final suffix = switch (imageData.mimeType) {
          'image/jpeg' => 'jpg',
          'image/webp' => 'webp',
          _ => 'png',
        };
        await FilePicker.saveFile(
          fileName: 'page-${index + 1}.$suffix',
          bytes: imageData.bytes,
        );
      } else if (action == 'copy') {
        await ReaderPlatform.copyImage(imageData.bytes);
      } else if (action == 'photos') {
        await ReaderPlatform.saveImageToPhotos(imageData.bytes);
        if (mounted) message(context, 'Đã lưu vào Ảnh.');
      } else if (action == 'ocr') {
        final text = await ReaderPlatform.recognizeText(imageData.bytes);
        if (!mounted || request != generation) return;
        if (text.trim().isEmpty) {
          message(context, 'Không nhận dạng được chữ trong trang này.');
          return;
        }
        var selectedText = '';
        await showModalBottomSheet<void>(
          context: context,
          isScrollControlled: true,
          builder: (ctx) => SafeArea(
            child: SizedBox(
              height: MediaQuery.sizeOf(ctx).height * .75,
              child: Column(
                children: [
                  ListTile(
                    title: const Text('Chữ trong trang truyện'),
                    trailing: IconButton(
                      tooltip: 'Sao chép văn bản',
                      icon: const Icon(CupertinoIcons.doc_on_doc),
                      onPressed: () async {
                        await Clipboard.setData(ClipboardData(text: text));
                        if (ctx.mounted) message(ctx, 'Đã sao chép văn bản.');
                      },
                    ),
                  ),
                  TextButton.icon(
                    icon: const Icon(CupertinoIcons.globe),
                    label: const Text('Dịch bằng iOS'),
                    onPressed: () => perform(
                      ctx,
                      () => ReaderPlatform.translateText(
                        selectedText.trim().isEmpty ? text : selectedText,
                      ),
                    ),
                  ),
                  Expanded(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.all(16),
                      child: SelectableText(
                        text,
                        onSelectionChanged: (selection, _) {
                          selectedText =
                              selection.isValid && !selection.isCollapsed
                              ? text.substring(selection.start, selection.end)
                              : '';
                        },
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      } else {
        await ReaderPlatform.shareImage(imageData.bytes);
      }
    });
  }

  void applyOptions(ReaderOptions next) {
    if (((next.autoScroll && !autoScrollPaused) || holdingScroll) &&
        modalDepth == 0 &&
        lifecycle == AppLifecycleState.resumed &&
        !loading &&
        error == null) {
      if (holdingScroll) {
        autoScroll.start(heldSpeed);
      } else if (next.autoScrollMode == 'page') {
        autoScroll.startTimed(next.autoPageSeconds);
      } else {
        autoScroll.start(next.autoScrollSpeed);
      }
    } else {
      autoScroll.pause();
    }
    final keep = next.keepAwake && lifecycle == AppLifecycleState.resumed;
    if (awake != keep) {
      awake = keep;
      unawaited(
        ReaderPlatform.keepAwake(keep)
            .catchError((Object e) => debugPrint('$e')),
      );
    }
    if (appliedOrientation != next.orientation) {
      appliedOrientation = next.orientation;
      orientationChanged = true;
      unawaited(
        SystemChrome.setPreferredOrientations(switch (next.orientation) {
          'portrait' => [DeviceOrientation.portraitUp],
          'reversePortrait' => [DeviceOrientation.portraitDown],
          'landscape' => [
            DeviceOrientation.landscapeLeft,
            DeviceOrientation.landscapeRight,
          ],
          _ => [],
        }).catchError((Object e) => debugPrint('$e')),
      );
    }
  }

  Future<void> download() async {
    final opened = book;
    if (opened == null || content == null || downloading || loading) return;
    final chapterId = opened.chapters[current].id;
    final revision = loadedRevision;
    setState(() => downloading = true);
    await perform(context, () async {
      checkLibraryRevision(repository.replacementRevision, revision);
      final latest = await repository.find(opened.id);
      checkLibraryRevision(repository.replacementRevision, revision);
      if (latest == null ||
          bookSourceIdentity(latest) != bookSourceIdentity(opened)) {
        throw StateError('Sách hoặc nguồn đã thay đổi. Hãy mở lại chương.');
      }
      final chapter = latest.chapters
          .where((item) => item.id == chapterId)
          .firstOrNull;
      if (chapter == null) throw StateError('Chương không còn trong mục lục.');
      if (chapter.downloaded) {
        if (mounted) message(context, 'Chương này đã có trên máy.');
        return;
      }
      if (!mounted) return;
      final queue = ref.read(downloadQueueProvider.notifier);
      await queue.enqueue(opened.id, [chapterId], expectedRevision: revision);
      await queue.start();
      if (mounted) message(context, 'Đã thêm chương vào hàng đợi tải.');
    });
    if (mounted) setState(() => downloading = false);
  }

  Future<void> orientation() => readerModal(_orientation);

  Future<void> _orientation() async {
    final choice = await showCupertinoModalPopup<List<DeviceOrientation>>(
      context: context,
      builder: (ctx) => CupertinoActionSheet(
        title: const Text('Hướng màn hình'),
        actions: [
          CupertinoActionSheetAction(
            onPressed: () => Navigator.pop(ctx, <DeviceOrientation>[]),
            child: const Text('Tự động xoay'),
          ),
          CupertinoActionSheetAction(
            onPressed: () => Navigator.pop(ctx, [DeviceOrientation.portraitUp]),
            child: const Text('Dọc'),
          ),
          CupertinoActionSheetAction(
            onPressed: () => Navigator.pop(ctx, [
              DeviceOrientation.landscapeLeft,
              DeviceOrientation.landscapeRight,
            ]),
            child: const Text('Ngang'),
          ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('Hủy'),
        ),
      ),
    );
    if (choice == null || !mounted) return;
    await perform(context, () async {
      orientationChanged = true;
      await SystemChrome.setPreferredOrientations(choice);
    });
  }

  @override
  void deactivate() {
    // A pending single tap can be released when a child double-tap recognizer
    // is removed. Refuse callbacks before its render objects become inactive.
    closing = true;
    autoScroll.pause();
    super.deactivate();
  }

  @override
  void activate() {
    super.activate();
    closing = false;
    applyOptions(options);
  }

  @override
  void dispose() {
    closing = true;
    unawaited(systemUi.release().catchError((Object _) {}));
    autoScroll.dispose();
    WidgetsBinding.instance.removeObserver(this);
    debounce?.cancel();
    generation++;
    unawaited(ReaderPlatform.keepAwake(false));
    nativeImages?.dispose();
    stopReadingTime();
    final opened = book;
    final revision = loadedRevision;
    unawaited(
      persist()
          .then((_) async {
            if (!incognitoSession && opened != null && revision != null) {
              await downloadDeletion.deleteReadChapters(
                opened,
                opened.chapters.map((chapter) => chapter.id),
                event: DownloadDeletionEvent.readerLeft,
                expectedRevision: revision,
              );
            }
          })
          .catchError(
            (Object error) => debugPrint('Delete read downloads: $error'),
          ),
    );
    if (speaking) unawaited(tts.stop().catchError((Object e) => 0));
    if (orientationChanged) {
      unawaited(SystemChrome.setPreferredOrientations([]));
    }
    scroll.dispose();
    super.dispose();
  }

  void imageReady(int index, int request, {bool success = true}) {
    if (index < 0) return;
    if (request != generation) return;
    final firstLayout = readyImages.add(index);
    final firstDecode = success && decodedImages.add(index);
    if (success) {
      failedImages.remove(index);
    } else {
      failedImages.add(index);
      decodedImages.remove(index);
    }
    if (firstLayout &&
        restoring &&
        (nativeImages != null || readyImages.length == imageKeys.length)) {
      restoreLocation(request);
    }
    if (firstDecode) {
      // A single-page chapter has no page-change callback. Completion is only
      // recorded after successful decoding/layout, with the same resume fraction.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && request == generation && mangaChapterCompleted) {
          unawaited(persist());
        }
      });
    }
  }

  void tapContent(Offset globalPosition) {
    if (!mounted || closing || modalDepth > 0) return;
    final viewportBox = viewport.currentContext?.findRenderObject();
    final action = content?.kind == 'manga' && viewportBox is RenderBox
        ? readerTapAction(
            layout: options.tapZones,
            point: viewportBox.globalToLocal(globalPosition),
            viewport: viewportBox.size,
            inverted: options.invertTapZones,
          )
        : ReaderTapAction.menu;
    if (action == ReaderTapAction.menu) {
      setState(() {
        chrome = !chrome;
        restoring = true;
      });
      restoreLocation(generation);
    } else if (scroll.hasClients && !restoring && !loading) {
      final direction = action == ReaderTapAction.next ? 1 : -1;
      unawaited(
        scroll.animateTo(
          (scroll.offset + direction * scroll.position.viewportDimension * .9)
              .clamp(0.0, scroll.position.maxScrollExtent),
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOut,
        ),
      );
    }
  }

  Widget image(String url, int index, {double? width, double? height}) {
    final request = generation;
    final window = nativeImages;
    if (window != null && index >= 0) {
      final page = NativeMangaPage(
        key: ValueKey('native-page:$request:$index'),
        image: window.imageAt(index),
        aspectRatio: window.aspectRatioAt(index),
        error: window.errorAt(index),
        loading: window.wants(index),
        onReady: (success) => imageReady(index, request, success: success),
        onRetry: () => window.retry(index),
      );
      // Retained dimensions survive byte eviction from the five-page window,
      // so 100% pages keep their geometry when scrolled away and back.
      final originalWidth =
          window.pixelSizeAt(index)?.width ?? MediaQuery.sizeOf(context).width;
      return SizedBox(
        width: width ?? (height == null ? originalWidth : null),
        height: height,
        child: page,
      );
    }
    Widget failed(Object error) {
      imageReady(index, request, success: false);
      final revision = loadedRevision;
      final chapterId = book == null || book!.chapters.isEmpty
          ? null
          : book!.chapters[current].id;
      return ReaderPageError(
        error: error,
        onRetry: revision == null || chapterId == null
            ? null
            : () => perform(context, () async {
                if (!mounted || request != generation) return;
                checkLibraryRevision(repository.replacementRevision, revision);
                await load(
                  current,
                  resume: true,
                  offset: position,
                  chapterId: chapterId,
                );
              }),
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
          memoryImageBytes.putIfAbsent(
            url,
            () => base64Decode(url.substring(url.indexOf(',') + 1)),
          ),
          width: width,
          height: height,
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
      width: width,
      height: height,
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
    final screenOrientation = MediaQuery.orientationOf(context);
    final settings = ref.watch(settingsProvider);
    final globalOptions = ref.watch(readerOptionsProvider);
    final latest = ref
        .watch(libraryProvider)
        .value
        ?.where((item) => item.id == widget.id)
        .firstOrNull;
    final overrides =
        latest?.readerPreferences ??
        book?.readerPreferences ??
        const <String, dynamic>{};
    final nextOptions = ReaderOptions.fromJson({
      ...globalOptions.toJson(),
      ...overrides,
    });
    if (content != null &&
        !loading &&
        (options.pageMargins(screenOrientation) !=
                nextOptions.pageMargins(screenOrientation) ||
            (layoutOrientation != null &&
                layoutOrientation != screenOrientation) ||
            options.gap != nextOptions.gap ||
            options.imageScale != nextOptions.imageScale)) {
      restoring = true;
      restoreLocation(generation);
    }
    options = nextOptions;
    layoutOrientation = screenOrientation;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        applyOptions(options);
        unawaited(
          systemUi
              .apply(
                fullScreen: options.fullScreen,
                hideStatusBar: options.hideStatusBar,
              )
              .catchError((Object _) {}),
        );
      }
    });
    ref.listen(settingsProvider, (previous, next) {
      if (content == null || loading) return;
      if (previous?.font != next.font ||
          previous?.fontSize != next.fontSize ||
          previous?.lineHeight != next.lineHeight) {
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
    final theme = Theme.of(context);
    final manga = (content?.kind ?? book?.kind) == 'manga';
    // Manga and reader chrome follow the app. Paper/sepia/night are deliberate
    // text-page choices, never an implicit light theme for loading or manga.
    final explicitTextPage = !manga && !loading && error == null;
    final inheritedBackground = explicitTextPage
        ? switch (settings.readerTheme) {
            'paper' => Colors.white,
            'sepia' => const Color(0xFFF5EBDC),
            'night' => const Color(0xFF161616),
            _ => theme.scaffoldBackgroundColor,
          }
        : theme.scaffoldBackgroundColor;
    final background = options.pageBackground(inheritedBackground);
    final foreground = options.backgroundMode != 'system'
        ? (ThemeData.estimateBrightnessForColor(background) == Brightness.dark
              ? const Color(0xffdddddd)
              : const Color(0xff1c1c1e))
        : explicitTextPage
        ? switch (settings.readerTheme) {
            'paper' || 'sepia' => const Color(0xFF1C1C1E),
            'night' => const Color(0xFFD8D8D8),
            _ => theme.colorScheme.onSurface,
          }
        : theme.colorScheme.onSurface;
    final pageMargins = options.pageMargins(screenOrientation);
    final displayBook = book ?? latest;
    final displayChapter = displayBook == null || displayBook.chapters.isEmpty
        ? null
        : book != null
        ? displayBook.chapters[current.clamp(
            0,
            displayBook.chapters.length - 1,
          )]
        : requestedChapterId != null
        ? displayBook.chapters
              .where((chapter) => chapter.id == requestedChapterId)
              .firstOrNull
        : displayBook.chapters[requestedChapter.clamp(
            0,
            displayBook.chapters.length - 1,
          )];
    return PopScope(
      canPop: !options.disableBackSwipe || allowBack,
      child: ReaderKeyboardControls(
        scroll: scroll,
        canScroll: () =>
            mounted &&
            !loading &&
            !restoring &&
            modalDepth == 0 &&
            error == null &&
            lifecycle == AppLifecycleState.resumed,
        onChapter: (direction) => changeChapter(direction),
        child: Scaffold(
          key: const ValueKey('reader-scaffold'),
          backgroundColor: background,
          appBar: chrome
              ? AppBar(
                  toolbarHeight: 56,
                  centerTitle: false,
                  leadingWidth: 44,
                  leading: IconButton(
                    tooltip: 'Quay lại',
                    icon: const Icon(CupertinoIcons.back),
                    onPressed: () async {
                      if (options.disableBackSwipe) {
                        setState(() => allowBack = true);
                        await WidgetsBinding.instance.endOfFrame;
                      }
                      if (!context.mounted) return;
                      await Navigator.of(context).maybePop();
                      if (mounted) setState(() => allowBack = false);
                    },
                  ),
                  title: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        displayBook?.title ?? 'Đang mở',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 16),
                      ),
                      if (displayChapter != null)
                        Text(
                          displayChapter.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 13,
                            color: theme.colorScheme.onSurface.withValues(
                              alpha: .7,
                            ),
                          ),
                        ),
                    ],
                  ),
                  actions: [
                    if (manga && content != null)
                      IconButton(
                        tooltip: 'Thao tác trang ảnh',
                        onPressed: loading ? null : () => pageActions(page),
                        icon: const Icon(CupertinoIcons.photo),
                      ),
                    if (book != null &&
                        book!.engine != 'local' &&
                        ref
                            .read(sourceRepositoryProvider)
                            .canOpenNativeWebsite(vm.catalogue(book!)))
                      IconButton(
                        tooltip: 'Xem trang web',
                        onPressed: () => perform(context, () async {
                          final currentBook = book!;
                          await ref
                              .read(sourceRepositoryProvider)
                              .openWebsite(vm.catalogue(currentBook));
                          if (mounted &&
                              (error != null || failedImages.isNotEmpty)) {
                            await load(current);
                          }
                        }),
                        icon: const Icon(CupertinoIcons.globe),
                      ),
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
                      tooltip: 'Mục lục',
                      onPressed: loading || book == null ? null : contents,
                      icon: const Icon(CupertinoIcons.list_bullet),
                    ),
                  ],
                )
              : null,
          body: Stack(
            fit: StackFit.expand,
            children: [
              SafeArea(
                top: !chrome,
                bottom: false,
                left: false,
                right: false,
                child: loading
                    ? const Center(child: CupertinoActivityIndicator())
                    : error != null
                    ? EmptyPanel(
                        icon: Icons.wifi_off_rounded,
                        title: 'Chưa mở được chương',
                        description: error!,
                        action: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            CupertinoButton.filled(
                              onPressed: () => load(
                                requestedChapter,
                                resume: true,
                                offset: requestedPosition,
                                chapterId: requestedChapterId,
                              ),
                              child: const Text('Thử lại'),
                            ),
                            TextButton.icon(
                              onPressed: () => readerModal(
                                () => Navigator.of(context).push<void>(
                                  CupertinoPageRoute<void>(
                                    builder: (_) =>
                                        const LogDiagnosticsScreen(),
                                  ),
                                ),
                              ),
                              icon: const Icon(CupertinoIcons.doc_text_search),
                              label: const Text('Nhật ký và chẩn đoán'),
                            ),
                          ],
                        ),
                      )
                    : GestureDetector(
                        key: const ValueKey('reader-content'),
                        behavior: HitTestBehavior.translucent,
                        onTapUp: (details) =>
                            tapContent(details.globalPosition),
                        child: ReaderHoldScroll(
                          enabled: manga && options.holdScroll,
                          speed: options.autoScrollSpeed,
                          onSpeed: (speed) {
                            holdingScroll = true;
                            heldSpeed = speed;
                            applyOptions(options);
                          },
                          onStop: () {
                            holdingScroll = false;
                            if (mounted && !closing) applyOptions(options);
                          },
                          child: ReaderPinchScrollGuard(
                            child: LayoutBuilder(
                              builder: (context, bounds) => SingleChildScrollView(
                                key: viewport,
                                controller: scroll,
                                padding: manga
                                    ? EdgeInsets.zero
                                    : const EdgeInsets.fromLTRB(
                                        26,
                                        24,
                                        26,
                                        140,
                                      ),
                                child: manga
                                    ? Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.stretch,
                                        children: List.generate(
                                          content!.images.length,
                                          (i) => Padding(
                                            key: imageKeys[i],
                                            padding: EdgeInsets.fromLTRB(
                                              pageMargins.left,
                                              0,
                                              pageMargins.right,
                                              i == content!.images.length - 1
                                                  ? 0
                                                  : options.gap,
                                            ),
                                            child: GestureDetector(
                                              onLongPress: options.holdScroll
                                                  ? null
                                                  : () => pageActions(i),
                                              child: MangaPageLayout(
                                                mode: options.imageScale,
                                                viewportHeight:
                                                    bounds.maxHeight,
                                                image: (width, height) =>
                                                    ZoomableMangaPage(
                                                      enabled: options.zoom,
                                                      child: ColorFiltered(
                                                        colorFilter:
                                                            options.imageFilter,
                                                        child: ColorFiltered(
                                                          colorFilter:
                                                              ColorFilter.mode(
                                                                Color(
                                                                  options.tint,
                                                                ).withValues(
                                                                  alpha: options
                                                                      .tintOpacity,
                                                                ),
                                                                options
                                                                    .blendMode,
                                                              ),
                                                          child: image(
                                                            content!.images[i],
                                                            i,
                                                            width: width,
                                                            height: height,
                                                          ),
                                                        ),
                                                      ),
                                                    ),
                                              ),
                                            ),
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
                                                if (element.localName ==
                                                    'img') {
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
                                                        settings.font ==
                                                            'NotoSans'
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
                        ),
                      ),
              ),
              if (chrome && book != null)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: ReaderControls(
                    manga: manga,
                    page: page,
                    pageCount: content?.images.length ?? 0,
                    position: position,
                    onSeek: loading || error != null ? null : seek,
                    onPrevious: loading || current <= 0
                        ? null
                        : () => changeChapter(-1),
                    onNext: loading || current >= book!.chapters.length - 1
                        ? null
                        : () => changeChapter(1),
                    onBookmark: loading || error != null ? null : bookmark,
                    onDownload: loading || error != null || downloading
                        ? null
                        : download,
                    onOrientation: orientation,
                    onSettings: () => readerModal(
                      () => showReaderSettings(
                        context,
                        manga: manga,
                        book: latest ?? book,
                        expectedRevision: loadedRevision,
                      ),
                    ),
                  ),
                ),
              if (content != null &&
                  !loading &&
                  error == null &&
                  options.autoScroll)
                Positioned(
                  left: 12,
                  right: 12,
                  bottom:
                      MediaQuery.viewPaddingOf(context).bottom +
                      (chrome ? 146 : 48),
                  child: ReaderAutoScrollStatus(
                    paused: autoScrollPaused,
                    mode: options.autoScrollMode,
                    speed: options.autoScrollSpeed,
                    pageSeconds: options.autoPageSeconds,
                    onToggle: () {
                      setState(() => autoScrollPaused = !autoScrollPaused);
                      applyOptions(options);
                    },
                  ),
                ),
              if (!chrome &&
                  manga &&
                  content!.images.isNotEmpty &&
                  options.showPageNumber)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: MediaQuery.viewPaddingOf(context).bottom + 12,
                  child: ReaderPageBadge(
                    page: page,
                    total: content!.images.length,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
