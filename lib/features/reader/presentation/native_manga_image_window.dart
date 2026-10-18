import '../../../core/format/error_messages.dart';
import '../../../core/diagnostics/diagnostic_log.dart';

import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../sources/domain/catalogue.dart';

class NativeMangaImage {
  const NativeMangaImage(this.data, this.width, this.height);
  final SourceImageData data;
  final int width;
  final int height;
  double get aspectRatio => width / height;
}

/// Holds only the current page and its two neighbours on either side. Requests
/// are selected when the serial engine becomes available, so dragging across a
/// long chapter does not queue every intermediate page in the native runtime.
class NativeMangaImageWindow extends ChangeNotifier {
  NativeMangaImageWindow({required this.count, required this.fetch});
  final int count;
  final Future<SourceImageData> Function(int index) fetch;
  final _images = <int, NativeMangaImage>{};
  final _errors = <int, Object>{};
  final _ratios = <int, double>{};
  final _sizes = <int, Size>{};
  Set<int> _wanted = {};
  int _focus = 0;
  bool _running = false, _disposed = false;

  NativeMangaImage? imageAt(int index) => _images[index];
  Object? errorAt(int index) => _errors[index];
  bool wants(int index) => _wanted.contains(index);
  double aspectRatioAt(int index) => _ratios[index] ?? 2 / 3;
  Size? pixelSizeAt(int index) => _sizes[index];

  /// A failed page remains visible until the reader explicitly retries it.
  /// Keep its measured dimensions and do not refetch neighbouring ready pages.
  void retry(int index) {
    if (_disposed || index < 0 || index >= count || !_wanted.contains(index)) {
      return;
    }
    _errors.remove(index);
    _images.remove(index);
    _focus = index;
    notifyListeners();
    unawaited(_pump());
  }

  int get retainedImages => _images.length;
  @visibleForTesting
  int get retainedBytes =>
      _images.values.fold(0, (total, image) => total + image.data.bytes.length);

  /// Retain page geometry but release bytes while another chapter is visible.
  /// An in-flight request may finish; it cannot repopulate a suspended window.
  void suspend() {
    if (_disposed || _wanted.isEmpty) return;
    _wanted = {};
    _images.clear();
    _errors.clear();
    notifyListeners();
  }

  void focus(int index) {
    if (_disposed || count == 0) return;
    _focus = index.clamp(0, count - 1);
    final wanted = {
      for (
        var i = math.max(0, _focus - 2);
        i <= math.min(count - 1, _focus + 2);
        i++
      )
        i,
    };
    if (!setEquals(wanted, _wanted)) {
      _wanted = wanted;
      _images.removeWhere((index, _) => !wanted.contains(index));
      _errors.removeWhere((index, _) => !wanted.contains(index));
      notifyListeners();
    }
    unawaited(_pump());
  }

  Future<void> _pump() async {
    if (_running || _disposed) return;
    _running = true;
    try {
      while (!_disposed) {
        final missing =
            _wanted
                .where(
                  (i) => !_images.containsKey(i) && !_errors.containsKey(i),
                )
                .toList()
              ..sort((a, b) {
                final distance = (a - _focus).abs().compareTo(
                  (b - _focus).abs(),
                );
                return distance != 0 ? distance : a.compareTo(b);
              });
        if (missing.isEmpty) break;
        final index = missing.first;
        try {
          final data = await fetch(index);
          if (_disposed || !_wanted.contains(index)) continue;
          if (data.bytes.isEmpty || data.bytes.length > 8 * 1024 * 1024) {
            throw StateError('Ảnh rỗng hoặc vượt giới hạn 8 MiB.');
          }
          final buffer = await ui.ImmutableBuffer.fromUint8List(data.bytes);
          ui.ImageDescriptor? descriptor;
          try {
            descriptor = await ui.ImageDescriptor.encoded(buffer);
            if (_disposed || !_wanted.contains(index)) continue;
            if (descriptor.width <= 0 || descriptor.height <= 0) {
              throw StateError('Kích thước ảnh không hợp lệ.');
            }
            final image = NativeMangaImage(
              data,
              descriptor.width,
              descriptor.height,
            );
            _ratios[index] = image.aspectRatio;
            _sizes[index] = Size(
              image.width.toDouble(),
              image.height.toDouble(),
            );
            _images[index] = image;
          } finally {
            descriptor?.dispose();
            buffer.dispose();
          }
        } catch (error) {
          if (!_disposed && _wanted.contains(index)) {
            _errors[index] = error;
            DiagnosticLogs.error('source', error);
          }
        }
        if (!_disposed && _wanted.contains(index)) notifyListeners();
      }
    } finally {
      _running = false;
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _wanted.clear();
    _images.clear();
    _errors.clear();
    super.dispose();
  }
}

/// Evicts the resized image provider when a page leaves the retained window.
/// Otherwise Flutter's image cache could keep the bytes after the window drops
/// them. Decoding is limited to the display width and four million pixels.
class NativeMangaPage extends StatefulWidget {
  const NativeMangaPage({
    super.key,
    required this.image,
    required this.aspectRatio,
    required this.error,
    required this.loading,
    required this.onReady,
    this.onRetry,
  });
  final NativeMangaImage? image;
  final double aspectRatio;
  final Object? error;
  final bool loading;
  final void Function(bool success) onReady;
  final VoidCallback? onRetry;

  @override
  State<NativeMangaPage> createState() => _NativeMangaPageState();
}

class _NativeMangaPageState extends State<NativeMangaPage> {
  ImageProvider? _provider;
  NativeMangaImage? _image;
  int? _decodeWidth;
  int? _decodeHeight;

  void _evict() {
    final provider = _provider;
    _provider = null;
    _image = null;
    _decodeWidth = null;
    _decodeHeight = null;
    if (provider != null) unawaited(provider.evict());
  }

  @override
  void dispose() {
    _evict();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AspectRatio(
    aspectRatio: widget.aspectRatio,
    child: LayoutBuilder(
      builder: (context, constraints) {
        final image = widget.image;
        if (image == null) {
          _evict();
          if (widget.error != null) {
            widget.onReady(false);
            return ReaderPageError(
              error: widget.error!,
              onRetry: widget.onRetry,
            );
          }
          return widget.loading
              ? const Center(child: CircularProgressIndicator())
              : const SizedBox.expand();
        }
        final width = math
            .min(
              math.min(image.width.toDouble(), 1440),
              math.min(
                constraints.maxWidth * MediaQuery.devicePixelRatioOf(context),
                math.sqrt(4 * 1024 * 1024 * image.aspectRatio),
              ),
            )
            .floor()
            .clamp(1, image.width);
        final height = (width / image.aspectRatio).floor().clamp(1, 8192);
        if (!identical(image, _image) ||
            width != _decodeWidth ||
            height != _decodeHeight) {
          _evict();
          _image = image;
          _decodeWidth = width;
          _decodeHeight = height;
          _provider = ResizeImage(
            MemoryImage(image.data.bytes),
            width: width,
            height: height,
            policy: ResizeImagePolicy.fit,
          );
        }
        return Image(
          image: _provider!,
          width: double.infinity,
          fit: BoxFit.contain,
          frameBuilder: (_, child, frame, synchronous) {
            if (frame != null || synchronous) widget.onReady(true);
            return child;
          },
          errorBuilder: (_, error, _) {
            widget.onReady(false);
            return ReaderPageError(error: error, onRetry: widget.onRetry);
          },
        );
      },
    ),
  );
}

class ReaderPageError extends StatelessWidget {
  const ReaderPageError({
    super.key,
    required this.error,
    this.onRetry,
    this.retryLabel = 'Thử lại ảnh',
    this.title = 'Không tải được ảnh',
    this.scrollable = true,
  });
  final String retryLabel;
  final String title;
  final bool scrollable;
  final Object error;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final content = Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.broken_image_outlined,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
          const SizedBox(height: 8),
          Text(title, textAlign: TextAlign.center),
          const SizedBox(height: 4),
          Text(
            userFacingError(error),
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall,
          ),
          if (onRetry != null)
            TextButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
              label: Text(retryLabel),
            ),
        ],
      ),
    );
    return Center(
      child: scrollable ? SingleChildScrollView(child: content) : content,
    );
  }
}
