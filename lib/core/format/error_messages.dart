import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

/// User-facing text only. Callers retain original exceptions for diagnostics.
String userFacingError(Object error) {
  if (error is SocketException || error is HttpException) {
    return 'Không kết nối được nguồn. Kiểm tra mạng rồi thử lại.';
  }
  if (error is TimeoutException) {
    return 'Nguồn phản hồi quá lâu. Hãy thử lại sau.';
  }
  if (error is FileSystemException) {
    return error.osError?.errorCode == 28 || error.osError?.errorCode == 112
        ? 'Thiết bị không còn đủ dung lượng. Giải phóng bộ nhớ rồi thử lại.'
        : 'Không đọc hoặc ghi được dữ liệu trên máy. Kiểm tra dung lượng và quyền truy cập rồi thử lại.';
  }
  if (error is MissingPluginException) {
    return 'Tính năng này chưa sẵn sàng trên thiết bị. Hãy mở lại ứng dụng.';
  }
  if (error is PlatformException) {
    final message = error.message;
    if (message != null && _isVietnamese(message)) return _clean(message);
    return 'Không hoàn tất được thao tác trên thiết bị. Hãy thử lại.';
  }
  final message = switch (error) {
    FormatException() => error.message,
    StateError() => error.message,
    _ => error.toString(),
  };
  final http = RegExp(
    r'\bHTTP(?: status)?[ :]+([1-5][0-9]{2})\b',
    caseSensitive: false,
  ).firstMatch(message);
  if (http != null && !_isVietnamese(message)) {
    final code = int.parse(http[1]!);
    final hint = code == 401 || code == 403
        ? 'Nguồn từ chối truy cập. Mở trang web nguồn để kiểm tra đăng nhập hoặc xác minh truy cập'
        : code == 404
        ? 'Không tìm thấy nội dung trên nguồn. Kiểm tra lại truyện hoặc chương'
        : code == 429
        ? 'Nguồn đang giới hạn số yêu cầu. Chờ một lúc rồi thử lại'
        : code >= 500
        ? 'Nguồn đang gặp lỗi máy chủ. Hãy thử lại sau'
        : 'Nguồn chưa hoàn tất yêu cầu. Hãy thử lại';
    return '$hint (HTTP $code).';
  }
  if (_isVietnamese(message)) return _clean(message);
  if (error is FormatException) {
    return 'Dữ liệu không đúng định dạng hoặc không được hỗ trợ.';
  }
  return 'Thao tác chưa hoàn tất. Hãy thử lại; nếu vẫn lỗi, mở Chẩn đoán thư viện để kiểm tra.';
}

bool _isVietnamese(String value) => RegExp(r'[À-ỹĐđ]').hasMatch(value);

String _clean(String value) {
  var result = value.replaceFirst(
    RegExp(r'^(Bad state:|FormatException:|Exception:|StateError:)\s*'),
    '',
  );
  result = result.replaceAllMapped(RegExp(r'https?://[^\s]+'), (match) {
    final uri = Uri.tryParse(match[0]!);
    if (uri == null || uri.host.isEmpty) return '[địa chỉ nguồn]';
    return Uri(
      scheme: uri.scheme,
      host: uri.host,
      port: uri.hasPort ? uri.port : null,
      path: uri.path,
    ).toString();
  });
  result = result.replaceAll(
    RegExp(r'Bearer\s+[^\s,;]+', caseSensitive: false),
    'Bearer [đã ẩn]',
  );
  result = result.replaceAllMapped(
    RegExp(
      r'(token|password|authorization|api[_-]?key)\s*[:=]\s*[^\s,;]+',
      caseSensitive: false,
    ),
    (match) => '${match[1]}=[đã ẩn]',
  );
  return result.length <= 1000 ? result : '${result.substring(0, 997)}…';
}
