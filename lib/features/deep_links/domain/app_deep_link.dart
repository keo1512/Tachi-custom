import 'dart:convert';

import '../../sources/data/extension_index.dart';
import '../../sources/domain/catalogue.dart';

sealed class AppDeepLink {
  const AppDeepLink();

  /// Shared with the native inbox: a link is at most 8 KiB of URL bytes.
  /// Library IDs are opaque exact strings, not filesystem paths or source IDs.
  static const maxUrlBytes = 8192;
  String get identity;

  static String _bounded(String value) {
    if (value.length > maxUrlBytes || utf8.encode(value).length > maxUrlBytes) {
      throw const FormatException('Liên kết ứng dụng quá dài.');
    }
    return value;
  }

  static String _encodedBookId(String id) {
    if (id.isEmpty || id.length > maxUrlBytes) {
      throw const FormatException('ID truyện trong liên kết không hợp lệ.');
    }
    var encoded = Uri.encodeComponent(id);
    if (Uri.decodeComponent(encoded) != id) {
      throw const FormatException('ID truyện không thể mã hóa thành liên kết.');
    }
    // Uri(pathSegments:) normalizes these two opaque IDs as navigation paths.
    if (id == '.' || id == '..') encoded = encoded.replaceAll('.', '%2E');
    return encoded;
  }

  static String _decodedBookId(String segment) {
    final bytes = <int>[];
    var start = 0;
    while (start < segment.length) {
      final next = segment.indexOf('%', start);
      if (next < 0) {
        bytes.addAll(utf8.encode(segment.substring(start)));
        break;
      }
      bytes.addAll(utf8.encode(segment.substring(start, next)));
      if (next + 2 >= segment.length) {
        throw const FormatException(
          'Mã hóa ID truyện trong liên kết không hợp lệ.',
        );
      }
      final value = int.tryParse(
        segment.substring(next + 1, next + 3),
        radix: 16,
      );
      if (value == null) {
        throw const FormatException(
          'Mã hóa ID truyện trong liên kết không hợp lệ.',
        );
      }
      bytes.add(value);
      start = next + 3;
    }
    return utf8.decode(bytes);
  }

  static void _validateChapterId(String? chapter) {
    if (chapter != null &&
        (chapter.isEmpty ||
            chapter.length > 4096 ||
            chapter.contains(RegExp(r'[\x00-\x1f\x7f]')))) {
      throw const FormatException('ID chương trong liên kết không hợp lệ.');
    }
  }

  /// Links only address existing library identities or propose a repository.
  /// A website URL is never treated as a downloaded title or executable.
  static AppDeepLink? parse(String value) {
    _bounded(value);
    if (RegExp(r'%(?![0-9A-Fa-f]{2})').hasMatch(value)) {
      throw const FormatException('Mã hóa liên kết ứng dụng không hợp lệ.');
    }
    final uri = Uri.tryParse(value);
    if (uri == null) {
      throw const FormatException('Liên kết ứng dụng không hợp lệ.');
    }
    if (uri.scheme != 'tachibooks') return null;
    if (uri.userInfo.isNotEmpty || uri.hasPort || uri.hasFragment) {
      throw const FormatException('Liên kết ứng dụng không hợp lệ.');
    }
    if (uri.queryParametersAll.values.any((values) => values.length != 1)) {
      throw const FormatException('Liên kết có tham số bị lặp.');
    }
    switch (uri.host) {
      case 'tasks':
        if (uri.query.isNotEmpty ||
            !['/downloads', '/updates'].contains(uri.path) ||
            !RegExp(r'^[A-Za-z][A-Za-z0-9+.-]*://tasks/(downloads|updates)$')
                .hasMatch(value)) {
          throw const FormatException('Liên kết tác vụ không hợp lệ.');
        }
        return TaskDeepLink(uri.path.substring(1));
      case 'book':
      case 'read':
      case 'notification-book':
        // Read one encoded segment before Uri removes dot segments. Decoding
        // once preserves literal slashes, spaces, Unicode and percent signs.
        final path = RegExp(
          r'^[A-Za-z][A-Za-z0-9+.-]*://[^/?#]+/([^/?#]+)(?:\?|$)',
        ).firstMatch(value);
        if (path == null ||
            uri.queryParameters.keys.any(
              (key) => uri.host != 'read' || key != 'chapterId',
            )) {
          throw const FormatException('Liên kết truyện không hợp lệ.');
        }
        final bookId = _decodedBookId(path.group(1)!);
        if (bookId.isEmpty) {
          throw const FormatException('ID truyện trong liên kết không hợp lệ.');
        }
        final chapter = uri.queryParameters['chapterId'];
        _validateChapterId(chapter);
        final result = LibraryDeepLink(
          bookId,
          reader: uri.host == 'read',
          chapterId: chapter,
          notification: uri.host == 'notification-book',
        );
        // Native URL delivery percent-encodes Unicode. Check canonical URL
        // bytes too so a short raw Unicode input cannot exceed the transport.
        _bounded(result.identity);
        return result;
      case 'repository':
        if (uri.path.isNotEmpty && uri.path != '/' ||
            uri.queryParameters.keys.any(
              (key) => !['engine', 'url'].contains(key),
            ) ||
            !SourceEngine.values.any(
              (engine) => engine.name == uri.queryParameters['engine'],
            ) ||
            (uri.queryParameters['url'] ?? '').isEmpty) {
          throw const FormatException('Liên kết kho tiện ích không hợp lệ.');
        }
        final engine = SourceEngine.values.byName(
          uri.queryParameters['engine']!,
        );
        final result = RepositoryDeepLink(
          engine,
          ExtensionIndexRepository.normalize(
            uri.queryParameters['url']!,
            engine,
          ).toString(),
        );
        _bounded(result.identity);
        return result;
      default:
        throw const FormatException('Chưa hỗ trợ thao tác trong liên kết này.');
    }
  }
}

/// Allowlisted tab navigation only; cannot trigger a download or HTTP request.
class TaskDeepLink extends AppDeepLink {
  const TaskDeepLink(this.task);
  final String task;
  String get route {
    if (!['downloads', 'updates'].contains(task)) {
      throw const FormatException('Liên kết tác vụ không hợp lệ.');
    }
    return '/$task';
  }

  @override
  String get identity {
    route; // Validate programmatically constructed links too.
    return 'tachibooks://tasks/$task';
  }
}

class LibraryDeepLink extends AppDeepLink {
  const LibraryDeepLink(
    this.bookId, {
    this.reader = false,
    this.chapterId,
    this.notification = false,
  });
  final String bookId;
  final bool reader;
  final String? chapterId;
  final bool notification;
  @override
  String get identity {
    AppDeepLink._validateChapterId(chapterId);
    if (!reader && chapterId != null) {
      throw const FormatException('Liên kết truyện không có ID chương.');
    }
    if (notification && reader) {
      throw const FormatException('Thông báo chỉ mở chi tiết truyện.');
    }
    final path = AppDeepLink._encodedBookId(bookId);
    final query = chapterId == null
        ? ''
        : '?${Uri(queryParameters: {'chapterId': chapterId!}).query}';
    return AppDeepLink._bounded(
      'tachibooks://${notification
          ? 'notification-book'
          : reader
          ? 'read'
          : 'book'}/$path$query',
    );
  }
}

class RepositoryDeepLink extends AppDeepLink {
  const RepositoryDeepLink(this.engine, this.url);
  final SourceEngine engine;
  final String url;
  @override
  String get identity => AppDeepLink._bounded(
    Uri(
      scheme: 'tachibooks',
      host: 'repository',
      queryParameters: {'engine': engine.name, 'url': url},
    ).toString(),
  );
}
