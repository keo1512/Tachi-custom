import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tachi_books/core/format/error_messages.dart';
import 'package:tachi_books/core/format/vietnamese_format.dart';
import 'package:tachi_books/features/sources/domain/catalogue.dart';

void main() {
  test('Vietnamese dates and numbers are display-only', () {
    final date = DateTime(2026, 10, 12, 3, 4);
    expect(vietnameseDateTime(date), '12/10/2026 03:04');
    expect(vietnameseDateTime(date, includeTime: false), '12/10/2026');
    expect(vietnameseNumber(1234567), '1.234.567');
    expect(vietnameseNumber(-1234.678, decimals: 2), '-1.234,68');
    expect(vietnameseNumber(0, decimals: 2), '0,00');
    expect(() => vietnameseNumber(double.nan), throwsArgumentError);
  });
  test(
    'localized actionable errors keep instructions and redact URL credentials',
    () {
      final error = StateError(
        'Không tải được https://user:secret@source.test/book?token=secret#fragment; hãy thử lại.',
      );
      final message = userFacingError(error);
      expect(message, contains('Không tải được https://source.test/book'));
      expect(message, contains('hãy thử lại'));
      for (final private in [
        'Bad state:',
        'secret',
        'token=',
        'fragment',
        'user:',
      ]) {
        expect(message, isNot(contains(private)));
      }
      expect(
        userFacingError(const FormatException('Bản sao lưu không hợp lệ.')),
        'Bản sao lưu không hợp lệ.',
      );
    },
  );
  test('storage, native and network errors do not expose provider details', () {
    expect(
      userFacingError(const SocketException('secret token')),
      contains('Kiểm tra mạng'),
    );
    expect(
      userFacingError(TimeoutException('secret token')),
      contains('quá lâu'),
    );
    expect(
      userFacingError(
        const FileSystemException(
          'secret path',
          '/secret',
          OSError('no space', 28),
        ),
      ),
      contains('đủ dung lượng'),
    );
    expect(
      userFacingError(
        PlatformException(code: 'native', message: 'secret token'),
      ),
      isNot(contains('secret')),
    );
    expect(
      userFacingError(Exception('English provider internals')),
      contains('Chẩn đoán'),
    );
  });
  test(
    'HTTP errors keep the useful status code with Vietnamese action text',
    () {
      expect(
        userFacingError('HTTP 503'),
        'Nguồn đang gặp lỗi máy chủ. Hãy thử lại sau (HTTP 503).',
      );
      expect(userFacingError('HTTP 429'), contains('giới hạn số yêu cầu'));
      expect(
        userFacingError('HTTP 403 token=secret'),
        contains('kiểm tra đăng nhập'),
      );
      expect(
        userFacingError('HTTP 403 token=secret'),
        isNot(contains('secret')),
      );
      expect(userFacingError('HTTP 404'), contains('Không tìm thấy nội dung'));
    },
  );
  test('native extension RPC errors retain distinct actionable categories', () {
    final cases = {
      'source_requires_browser': 'xác minh hoặc đăng nhập',
      'unsupported_extension': 'API Android hoặc Java',
      'engine_unavailable': 'Không khởi tạo được engine',
      'extension_failed': 'Extension không lấy được nội dung',
      'invalid_request': 'Yêu cầu tới engine extension không hợp lệ',
      'RESTORED_TITLE_UNRESOLVED': 'Di chuyển nguồn',
      'CHAPTER_IDENTITY_CHANGED': 'Cập nhật mục lục',
      'SOURCE_NOT_INSTALLED': 'Cài extension tương ứng',
    };
    for (final entry in cases.entries) {
      final error = ApiException(
        'private https://example.test/secret?token=secret UserBook',
        code: entry.key,
      );
      final message = userFacingError(error);
      expect(message, contains(entry.value), reason: entry.key);
      expect(message, isNot(contains('secret')));
      expect(message, isNot(contains('UserBook')));
    }
    expect(
      userFacingError(
        PlatformException(code: 'engine_unavailable', message: 'private'),
      ),
      contains('Không khởi tạo được engine'),
    );
    expect(
      userFacingError(
        const ApiException('opaque provider message', statusCode: 403),
      ),
      contains('(HTTP 403)'),
    );
    expect(
      userFacingError(const ApiException('English', code: 'PRIVATE_token')),
      contains('Chẩn đoán'),
    );
  });
  test(
    'platform source errors preserve HTTP status and explicit timeout remedies',
    () {
      for (final code in [403, 404, 429, 503]) {
        final error = PlatformException(
          code: 'source_error',
          message: 'HTTP $code private_token_secret',
        );
        final message = userFacingError(error);
        expect(message, contains('(HTTP $code)'));
        expect(message, isNot(contains('private_token_secret')));
      }
      expect(
        userFacingError(PlatformException(code: 'timeout', message: 'private')),
        contains('Nguồn phản hồi quá lâu'),
      );
      expect(
        userFacingError(
          const ApiException('private', code: 'source_not_installed'),
        ),
        contains('chưa được cài hoặc chưa nạp được'),
      );
    },
  );
}
