import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';

Future<Rect?> showReaderImageRegion(BuildContext context, Uint8List bytes) =>
    showModalBottomSheet<Rect>(
      context: context,
      isScrollControlled: true,
      builder: (context) => SizedBox(
        height: MediaQuery.sizeOf(context).height * .92,
        child: ReaderImageRegion(bytes: bytes),
      ),
    );

/// Selects a normalized region on a preview. The original page stays intact.
class ReaderImageRegion extends StatefulWidget {
  const ReaderImageRegion({super.key, required this.bytes});
  final Uint8List bytes;
  @override
  State<ReaderImageRegion> createState() => _ReaderImageRegionState();
}

class _ReaderImageRegionState extends State<ReaderImageRegion> {
  Size? pixels;
  String? error;
  Rect selection = const Rect.fromLTRB(0, 0, 1, 1);
  Offset? anchor;
  bool selecting = true;
  final transform = TransformationController();

  @override
  void initState() {
    super.initState();
    loadDimensions();
  }

  Future<void> loadDimensions() async {
    ui.ImmutableBuffer? buffer;
    ui.ImageDescriptor? descriptor;
    try {
      if (widget.bytes.isEmpty || widget.bytes.length > 8 * 1024 * 1024) {
        throw const FormatException('Ảnh trống hoặc vượt giới hạn 8 MB.');
      }
      buffer = await ui.ImmutableBuffer.fromUint8List(widget.bytes);
      descriptor = await ui.ImageDescriptor.encoded(buffer);
      final width = descriptor.width, height = descriptor.height;
      if (width <= 0 || height <= 0 || width * height > 40000000) {
        throw const FormatException('Ảnh vượt giới hạn 40 triệu điểm ảnh.');
      }
      if (mounted) {
        setState(() => pixels = Size(width.toDouble(), height.toDouble()));
      }
    } catch (_) {
      if (mounted) setState(() => error = 'Chưa đọc được ảnh để chọn vùng.');
    } finally {
      descriptor?.dispose();
      buffer?.dispose();
    }
  }

  @override
  void dispose() {
    transform.dispose();
    super.dispose();
  }

  Offset normalized(Offset point, Size size) => Offset(
    (point.dx / size.width).clamp(0.0, 1.0),
    (point.dy / size.height).clamp(0.0, 1.0),
  );

  @override
  Widget build(BuildContext context) {
    final size = pixels;
    return SafeArea(
      child: Column(
        children: [
          ListTile(
            title: const Text('Chọn vùng nhận dạng chữ'),
            subtitle: const Text(
              'Kéo để khoanh vùng. Chuyển sang di chuyển để phóng to ảnh.',
            ),
            trailing: IconButton(
              tooltip: 'Hủy chọn vùng',
              onPressed: () => Navigator.pop(context),
              icon: const Icon(Icons.close),
            ),
          ),
          Wrap(
            alignment: WrapAlignment.center,
            spacing: 12,
            children: [
              TextButton.icon(
                onPressed: () => setState(() => selecting = !selecting),
                icon: Icon(selecting ? Icons.pan_tool_alt : Icons.crop_free),
                label: Text(selecting ? 'Di chuyển / phóng to' : 'Chọn vùng'),
              ),
              TextButton(
                onPressed: () => setState(() {
                  selection = const Rect.fromLTRB(0, 0, 1, 1);
                  transform.value = Matrix4.identity();
                }),
                child: const Text('Toàn bộ ảnh'),
              ),
            ],
          ),
          Expanded(
            child: error != null
                ? Center(child: Text(error!))
                : size == null
                ? const Center(child: CircularProgressIndicator())
                : LayoutBuilder(
                    builder: (context, constraints) {
                      final fitted = applyBoxFit(
                        BoxFit.contain,
                        size,
                        constraints.biggest,
                      ).destination;
                      final previewWidth = math.max(
                        1,
                        (size.width *
                                math.min(
                                  1,
                                  2048 / math.max(size.width, size.height),
                                ))
                            .round(),
                      );
                      return InteractiveViewer(
                        transformationController: transform,
                        panEnabled: !selecting,
                        scaleEnabled: !selecting,
                        maxScale: 8,
                        child: Center(
                          child: SizedBox(
                            width: fitted.width,
                            height: fitted.height,
                            child: GestureDetector(
                              key: const ValueKey('ocr-region-image'),
                              dragStartBehavior: DragStartBehavior.down,
                              behavior: HitTestBehavior.opaque,
                              onPanStart: !selecting
                                  ? null
                                  : (details) => setState(() {
                                      anchor = normalized(
                                        details.localPosition,
                                        fitted,
                                      );
                                      selection = Rect.fromPoints(
                                        anchor!,
                                        anchor!,
                                      );
                                    }),
                              onPanUpdate: !selecting
                                  ? null
                                  : (details) => setState(() {
                                      if (anchor != null) {
                                        selection = Rect.fromPoints(
                                          anchor!,
                                          normalized(
                                            details.localPosition,
                                            fitted,
                                          ),
                                        );
                                      }
                                    }),
                              child: Stack(
                                fit: StackFit.expand,
                                children: [
                                  Image.memory(
                                    widget.bytes,
                                    cacheWidth: previewWidth,
                                    fit: BoxFit.fill,
                                    errorBuilder: (_, _, _) {
                                      WidgetsBinding.instance
                                          .addPostFrameCallback((_) {
                                            if (mounted && error == null) {
                                              setState(
                                                () => error = 'Không hiển thị được ảnh để chọn vùng.',
                                              );
                                            }
                                          });
                                      return const Center(
                                        child: Text('Không hiển thị được ảnh.'),
                                      );
                                    },
                                  ),
                                  IgnorePointer(
                                    child: CustomPaint(
                                      painter: _RegionPainter(
                                        selection,
                                        Theme.of(context).colorScheme.primary,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
          ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: FilledButton.icon(
              onPressed:
                  size == null ||
                      error != null ||
                      selection.width < .005 ||
                      selection.height < .005
                  ? null
                  : () => Navigator.pop(context, selection),
              icon: const Icon(Icons.text_fields),
              label: const Text('Nhận dạng vùng đã chọn'),
            ),
          ),
        ],
      ),
    );
  }
}

class _RegionPainter extends CustomPainter {
  const _RegionPainter(this.region, this.color);
  final Rect region;
  final Color color;
  @override
  void paint(Canvas canvas, Size size) {
    final rect = Rect.fromLTRB(
      region.left * size.width,
      region.top * size.height,
      region.right * size.width,
      region.bottom * size.height,
    );
    final mask = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(Offset.zero & size)
      ..addRect(rect);
    canvas.drawPath(mask, Paint()..color = Colors.black.withValues(alpha: .55));
    canvas.drawRect(
      rect.deflate(1),
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
  }

  @override
  bool shouldRepaint(_RegionPainter old) =>
      old.region != region || old.color != color;
}
