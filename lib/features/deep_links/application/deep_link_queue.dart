import '../../library/data/coordinated_preferences.dart';
import '../../library/data/library_repository.dart';

import 'package:shared_preferences/shared_preferences.dart';

import '../domain/app_deep_link.dart';

/// Internal handoff only: the revision comes from the accepted link session,
/// never from untrusted URL query parameters.
class LibraryLinkHandoff {
  const LibraryLinkHandoff(this.expectedRevision);
  final int expectedRevision;
}

class PendingDeepLink {
  PendingDeepLink(this.link, this.repository, this.preferences)
    : revision = repository.replacementRevision,
      generation = preferences is CoordinatedPreferences
          ? preferences.mutationGeneration
          : null;
  final AppDeepLink link;
  final LibraryRepository repository;
  final SharedPreferences preferences;
  final int revision;
  final int? generation;
  bool get current =>
      repository.replacementRevision == revision &&
      (preferences is! CoordinatedPreferences ||
          (preferences as CoordinatedPreferences).mutationGeneration ==
              generation);

  Future<String> libraryRoute() async {
    if (!current) {
      throw const FormatException('Thư viện đã đổi. Hãy mở lại liên kết.');
    }
    final request = link as LibraryDeepLink;
    final book = await repository.find(request.bookId);
    if (!current) {
      throw const FormatException('Thư viện đã đổi. Hãy mở lại liên kết.');
    }
    if (book == null) {
      throw const FormatException(
        'Truyện trong liên kết chưa có trong thư viện.',
      );
    }
    // URI parsers normalize dot segments even when percent encoded. Preserve
    // these two valid opaque library IDs in a query field instead of a path.
    final dotId = book.id == '.' || book.id == '..';
    final pathId = dotId ? 'link' : book.id;
    if (!request.reader) {
      return Uri(
        pathSegments: ['', 'book', pathId],
        queryParameters: dotId ? {'bookId': book.id} : null,
      ).toString();
    }
    if (book.chapters.isEmpty) {
      throw const FormatException('Truyện này chưa có chương để đọc.');
    }
    final chapter = request.chapterId == null
        ? book.currentChapter.clamp(0, book.chapters.length - 1)
        : book.chapters.indexWhere(
            (chapter) => chapter.id == request.chapterId,
          );
    if (chapter < 0) {
      throw const FormatException(
        'Chương trong liên kết không còn trong mục lục.',
      );
    }
    // A TOC can reorder without replacing the library. Carry the stable ID
    // through navigation; the reader resolves it against its own loaded book.
    return Uri(
      pathSegments: ['', 'read', pathId],
      queryParameters: {
        if (dotId) 'bookId': book.id,
        'chapterId': book.chapters[chapter].id,
      },
    ).toString();
  }
}

/// Bounded ephemeral queue: links are not library data and are never backed up.
class DeepLinkQueue {
  DeepLinkQueue({DateTime Function()? now}) : now = now ?? DateTime.now;
  final DateTime Function() now;
  final _pending = <PendingDeepLink>[];
  final _recent = <String, DateTime>{};
  final _active = <String>{};
  int get length => _pending.length;
  bool add(PendingDeepLink request) {
    final time = now();
    _recent.removeWhere(
      (_, when) => time.difference(when) >= const Duration(seconds: 2),
    );
    final key = request.link.identity;
    if (_active.contains(key) ||
        _recent.containsKey(key) ||
        _pending.any((value) => value.link.identity == key)) {
      return false;
    }
    if (_pending.length >= 16) return false;
    _pending.add(request);
    _recent[key] = time;
    return true;
  }

  PendingDeepLink? take() {
    if (_pending.isEmpty) return null;
    final next = _pending.removeAt(0);
    _active.add(next.link.identity);
    return next;
  }

  void finish(PendingDeepLink request) => _active.remove(request.link.identity);
  void clear() {
    _pending.clear();
    _active.clear();
    _recent.clear();
  }
}
