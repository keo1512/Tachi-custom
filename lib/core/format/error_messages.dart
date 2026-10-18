import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

import '../../features/sources/domain/catalogue.dart';

/// Only stable codes are retained. An extension may supply arbitrary messages
/// or codes containing account data, so neither is used in diagnostic output.
String? sourceErrorDiagnosticCode(Object error) {
  final code = switch (error) {
    ApiException() => error.code,
    PlatformException() => error.code,
    _ => null,
  };
  return switch (code?.toLowerCase()) {
    'source_requires_browser' => 'source_browser_required',
    'unsupported_extension' => 'source_api_unsupported',
    'engine_unavailable' => 'source_engine_unavailable',
    'runtime_missing' => 'source_runtime_missing',
    'extension_failed' || 'source_error' => 'source_operation_failed',
    'invalid_request' || 'invalid_runtime_request' => 'source_invalid_request',
    'restored_title_unresolved' => 'source_title_unresolved',
    'chapter_identity_changed' => 'source_chapter_unresolved',
    'source_context_missing' => 'source_chapter_context_missing',
    'source_not_installed' || 'unknown_source' => 'source_not_installed',
    'connection_failed' => 'source_connection_failed',
    'timeout' => 'timeout',
    'invalid_source_data' => 'invalid_data',
    _ => null,
  };
}

String? sourceErrorMessage(String code) => switch (code) {
  'source_browser_required' => 'Nguồn cần xác minh hoặc đăng nhập trên trang web. Mở trang web nguồn trong app, hoàn tất rồi thử lại.',
  'source_api_unsupported' => 'Extension đang dùng API Android hoặc Java mà engine chưa hỗ trợ. Kiểm tra cập nhật extension và ứng dụng.',
  'source_engine_unavailable' => 'Không khởi tạo được engine extension trên thiết bị. Mở lại ứng dụng; nếu vẫn lỗi, xuất nhật ký chẩn đoán.',
  'source_runtime_missing' =>
    'Bản ứng dụng chưa có engine extension phù hợp. Cần cài bản IPA có engine.',
  'source_operation_failed' => 'Extension không lấy được nội dung. Kiểm tra mạng và trang web nguồn, rồi thử lại; nếu vẫn lỗi, xuất nhật ký chẩn đoán.',
  'source_invalid_request' => 'Yêu cầu tới engine extension không hợp lệ. Mở lại truyện từ nguồn; nếu vẫn lỗi, xuất nhật ký chẩn đoán.',
  'source_title_unresolved' => 'Truyện đang dùng mã của server cũ. Mở đúng truyện từ nguồn đã cài hoặc dùng Di chuyển nguồn để liên kết lại.',
  'source_chapter_unresolved' => 'Chương chưa có địa chỉ nguồn hợp lệ. Cập nhật mục lục truyện rồi mở lại chương.',
  'source_chapter_context_missing' => 'Extension cần dữ liệu phụ gốc của chương. Cập nhật mục lục từ đúng nguồn rồi mở lại chương; nội dung đã tải và tiến độ đọc được giữ nguyên.',
  'source_not_installed' => 'Nguồn của truyện chưa được cài hoặc chưa nạp được trên máy. Kiểm tra Duyệt → Phần mở rộng. Cài extension tương ứng hoặc cập nhật extension rồi thử lại.',
  'source_connection_failed' =>
    'Không kết nối được nguồn. Kiểm tra mạng rồi thử lại.',
  _ => null,
};

int? errorHttpStatus(Object error) {
  if (error is ApiException &&
      error.statusCode != null &&
      error.statusCode! >= 100 &&
      error.statusCode! <= 599) {
    return error.statusCode;
  }
  final match = RegExp(
    r'\bHTTP(?: status)?[ :]+([1-5][0-9]{2})\b',
    caseSensitive: false,
  ).firstMatch('$error');
  return match == null ? null : int.parse(match[1]!);
}

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
    final http = errorHttpStatus(error);
    if (http != null) return _httpErrorMessage(http);
    final message = error.message;
    if (message != null && _isVietnamese(message)) return _clean(message);
    final code = sourceErrorDiagnosticCode(error);
    if (code == 'timeout') {
      return 'Nguồn phản hồi quá lâu. Hãy thử lại sau.';
    }
    if (code != null && sourceErrorMessage(code) != null) {
      return sourceErrorMessage(code)!;
    }
    return 'Không hoàn tất được thao tác trên thiết bị. Hãy thử lại.';
  }
  final message = switch (error) {
    FormatException() => error.message,
    StateError() => error.message,
    _ => error.toString(),
  };
  final http = errorHttpStatus(error);
  if (http != null && !_isVietnamese(message)) {
    return _httpErrorMessage(http);
  }
  if (_isVietnamese(message)) return _clean(message);
  final sourceCode = sourceErrorDiagnosticCode(error);
  if (sourceCode != null) {
    if (sourceCode == 'timeout') {
      return 'Nguồn phản hồi quá lâu. Hãy thử lại sau.';
    }
    final explanation = sourceErrorMessage(sourceCode);
    if (explanation != null) return explanation;
  }
  if (error is FormatException) {
    return 'Dữ liệu không đúng định dạng hoặc không được hỗ trợ.';
  }
  return 'Thao tác chưa hoàn tất. Hãy thử lại; nếu vẫn lỗi, mở Chẩn đoán thư viện để kiểm tra.';
}

String _httpErrorMessage(int code) {
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
