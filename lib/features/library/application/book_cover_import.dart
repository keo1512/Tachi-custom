import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';

import '../../../core/platform/book_cover_platform.dart';
import '../data/library_repository.dart';

Future<String?> chooseBookCover({required bool fromPhotos}) async {
  Uint8List? bytes;
  if (fromPhotos) {
    bytes = await BookCoverPlatform.choosePhoto();
  } else {
    final file = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: ['png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp'],
    );
    if (file == null) return null;
    final size = await file.length();
    if (size != null && (size <= 0 || size > LibraryRepository.maxImageBytes)) {
      throw const FormatException('Ảnh bìa trống hoặc vượt giới hạn 8 MB.');
    }
    final stream = file.readAsByteStream();
    final buffer = BytesBuilder(copy: false);
    await for (final chunk in stream) {
      if (buffer.length + chunk.length > LibraryRepository.maxImageBytes) {
        throw const FormatException('Ảnh bìa vượt giới hạn 8 MB.');
      }
      buffer.add(chunk);
    }
    bytes = buffer.takeBytes();
  }
  if (bytes == null) return null;
  return validateBookCoverBytes(bytes);
}

Future<String> validateBookCoverBytes(Uint8List bytes) async {
  if (bytes.isEmpty || bytes.length > LibraryRepository.maxImageBytes) {
    throw const FormatException('Ảnh bìa trống hoặc vượt giới hạn 8 MB.');
  }
  String type;
  if (bytes.length >= 8 &&
      bytes[0] == 137 &&
      ascii.decode(bytes.sublist(1, 4), allowInvalid: true) == 'PNG') {
    type = 'image/png';
  } else if (bytes.length >= 3 && bytes[0] == 255 && bytes[1] == 216) {
    type = 'image/jpeg';
  } else if (bytes.length >= 12 &&
      ascii.decode(bytes.sublist(0, 4), allowInvalid: true) == 'RIFF' &&
      ascii.decode(bytes.sublist(8, 12), allowInvalid: true) == 'WEBP') {
    type = 'image/webp';
  } else if (bytes.length >= 6 &&
      ascii.decode(bytes.sublist(0, 3), allowInvalid: true) == 'GIF') {
    type = 'image/gif';
  } else if (bytes.length >= 2 && bytes[0] == 66 && bytes[1] == 77) {
    type = 'image/bmp';
  } else {
    throw const FormatException('Tệp đã chọn không phải ảnh được hỗ trợ.');
  }
  ui.Codec? codec;
  ui.FrameInfo? frame;
  try {
    codec = await ui.instantiateImageCodec(
      bytes,
      targetWidth: 128,
      targetHeight: 128,
      allowUpscaling: false,
    );
    frame = await codec.getNextFrame();
    if (frame.image.width <= 0 || frame.image.height <= 0) {
      throw const FormatException('Không giải mã được ảnh bìa.');
    }
  } catch (_) {
    throw const FormatException('Không giải mã được ảnh bìa.');
  } finally {
    frame?.image.dispose();
    codec?.dispose();
  }
  return 'data:$type;base64,${base64Encode(bytes)}';
}
