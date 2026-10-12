import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tachi_books/core/format/error_messages.dart';
import 'package:tachi_books/core/format/vietnamese_format.dart';

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
}
