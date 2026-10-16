import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../../core/platform/reader_platform.dart';
import '../../../core/widgets/feedback.dart';

/// Reuses the exact provider from the title header, including source headers.
class BookCoverViewer extends StatefulWidget {
  const BookCoverViewer({super.key, required this.title, required this.image});

  final String title;
  final ImageProvider<Object> image;

  @override
  State<BookCoverViewer> createState() => _BookCoverViewerState();
}

class _BookCoverViewerState extends State<BookCoverViewer> {
  int retry = 0;
  int generation = 0;
  bool busy = false;
  ImageStream? stream;
  ImageStreamListener? listener;
  ImageInfo? frame;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    resolveImage();
  }

  @override
  void didUpdateWidget(covariant BookCoverViewer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.image != widget.image) resolveImage();
  }

  void releaseImage() {
    generation++;
    if (listener != null) stream?.removeListener(listener!);
    listener = null;
    stream = null;
    frame?.dispose();
    frame = null;
  }

  void resolveImage() {
    final next = widget.image.resolve(createLocalImageConfiguration(context));
    if (stream?.key == next.key) return;
    releaseImage();
    stream = next;
    final request = generation;
    listener = ImageStreamListener(
      (image, _) {
        if (!mounted || request != generation) {
          image.dispose();
          return;
        }
        setState(() {
          frame?.dispose();
          frame = image;
        });
      },
      onError: (Object _, StackTrace? _) {
        if (!mounted || request != generation) return;
        setState(() {
          frame?.dispose();
          frame = null;
        });
      },
    );
    next.addListener(listener!);
  }

  Future<void> exportCover({required bool share}) async {
    if (busy || frame == null) return;
    final image = frame!.image.clone();
    final request = generation;
    setState(() => busy = true);
    try {
      await perform(context, () async {
        if (image.width * image.height > 40000000) {
          throw StateError('Ảnh bìa vượt giới hạn 40 triệu điểm ảnh.');
        }
        // Generic providers expose decoded frames. Export the displayed cover
        // as PNG without fetching its URL again or bypassing source headers.
        final encoded = await image.toByteData(format: ui.ImageByteFormat.png);
        if (!mounted || request != generation) return;
        if (encoded == null ||
            encoded.lengthInBytes == 0 ||
            encoded.lengthInBytes > 8 * 1024 * 1024) {
          throw StateError('Ảnh bìa xuất ra trống hoặc vượt giới hạn 8 MB.');
        }
        final bytes = encoded.buffer.asUint8List(
          encoded.offsetInBytes,
          encoded.lengthInBytes,
        );
        if (share) {
          await ReaderPlatform.shareImage(bytes);
        } else {
          await ReaderPlatform.saveImageToPhotos(bytes);
          if (mounted && request == generation) {
            message(context, 'Đã lưu ảnh bìa PNG vào Ảnh.');
          }
        }
      });
    } finally {
      image.dispose();
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  void dispose() {
    releaseImage();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(widget.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      actions: [
        if (busy)
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: CupertinoActivityIndicator(),
          ),
        IconButton(
          tooltip: 'Lưu ảnh bìa vào Ảnh',
          onPressed: frame == null || busy
              ? null
              : () => exportCover(share: false),
          icon: const Icon(CupertinoIcons.arrow_down_to_line),
        ),
        IconButton(
          tooltip: 'Chia sẻ ảnh bìa',
          onPressed: frame == null || busy
              ? null
              : () => exportCover(share: true),
          icon: const Icon(CupertinoIcons.square_arrow_up),
        ),
      ],
    ),
    body: SafeArea(
      child: Center(
        child: InteractiveViewer(
          minScale: 1,
          maxScale: 5,
          child: Image(
            key: ValueKey(retry),
            image: widget.image,
            fit: BoxFit.contain,
            semanticLabel: 'Bìa ${widget.title}',
            frameBuilder: (context, child, frame, synchronouslyLoaded) =>
                frame != null || synchronouslyLoaded
                ? child
                : const CupertinoActivityIndicator(),
            errorBuilder: (context, _, _) => Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(CupertinoIcons.book, size: 48),
                  const SizedBox(height: 12),
                  const Text('Chưa tải được ảnh bìa'),
                  TextButton(
                    onPressed: () async {
                      releaseImage();
                      await widget.image.evict();
                      if (mounted) {
                        setState(() => retry++);
                        resolveImage();
                      }
                    },
                    child: const Text('Thử lại'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
}
