import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../library/domain/library_book.dart';
import '../../sources/domain/catalogue.dart';
import '../../sources/domain/native_page_locator.dart';

final ordinaryReaderImageLoaderProvider =
    Provider<Future<SourceImageData> Function(ReaderContent, int)>(
      (_) => loadOrdinaryReaderImage,
    );

/// The HTTP path is only for engines without a native image loader. Native
/// page locators and their cookies must always go through the source runtime.
Future<SourceImageData> loadOrdinaryReaderImage(
  ReaderContent data,
  int page, {
  http.Client? client,
}) async {
  final url = data.images[page];
  if (url.startsWith('data:')) {
    if (url.length > 11184900) {
      throw const FormatException('Ảnh vượt giới hạn 8 MB.');
    }
    final bytes = base64Decode(url.substring(url.indexOf(',') + 1));
    if (bytes.isEmpty || bytes.length > 8 * 1024 * 1024) {
      throw const FormatException('Ảnh rỗng hoặc vượt giới hạn 8 MB.');
    }
    return SourceImageData(bytes: bytes, mimeType: 'image/*');
  }
  if (isNativePageLocator(url)) throw nativePageRuntimeRequiredError;
  final uri = Uri.tryParse(url);
  if (uri == null ||
      !{'http', 'https'}.contains(uri.scheme) ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty) {
    throw const FormatException('Địa chỉ ảnh không hợp lệ.');
  }
  final transport = client ?? http.Client();
  try {
    return await (() async {
      final request = http.Request('GET', uri);
      request.headers.addAll(data.headersFor(url));
      final response = await transport.send(request);
      if (response.statusCode != 200 ||
          (response.contentLength ?? 0) > 8 * 1024 * 1024) {
        await response.stream.listen((_) {}).cancel();
        throw ApiException(
          'Không tải được trang truyện.',
          statusCode: response.statusCode,
        );
      }
      final bytes = BytesBuilder(copy: false);
      await for (final block in response.stream) {
        if (bytes.length + block.length > 8 * 1024 * 1024) {
          throw const FormatException('Ảnh vượt giới hạn 8 MB.');
        }
        bytes.add(block);
      }
      return SourceImageData(
        bytes: bytes.takeBytes(),
        mimeType: response.headers['content-type'] ?? 'image/*',
      );
    })().timeout(const Duration(seconds: 30));
  } finally {
    if (client == null) transport.close();
  }
}
