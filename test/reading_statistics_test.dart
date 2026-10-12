import 'package:flutter_test/flutter_test.dart';
import 'package:tachi_books/features/library/domain/library_book.dart';
import 'package:tachi_books/features/library/domain/reading_statistics.dart';

void main() {
  test(
    'real read flags, offline flags and overlapping categories remain separate',
    () {
      final stats = ReadingStatistics([
        LibraryBook(
          id: 'one',
          title: 'Started',
          progress: .8,
          favorite: true,
          categories: const ['Writer', 'Series'],
          chapters: const [
            BookChapter(
              id: 'a',
              title: 'A',
              index: 0,
              read: false,
              downloaded: true,
            ),
            BookChapter(id: 'b', title: 'B', index: 1, read: true),
          ],
        ),
        LibraryBook(
          id: 'two',
          title: 'Completed',
          completed: true,
          categories: const ['Series'],
          chapters: const [
            BookChapter(id: 'c', title: 'C', index: 0, read: true),
          ],
        ),
        LibraryBook(id: 'three', title: 'Unstarted'),
      ]);
      expect(stats.chapters, 3);
      expect(stats.read, 2);
      expect(stats.unread, 1);
      expect(stats.progress, closeTo(2 / 3, .0001));
      expect(stats.offlineBooks, 1);
      expect(stats.downloaded, 1);
      expect(stats.completed, 1);
      expect(stats.inProgress, 1);
      expect(stats.notStarted, 1);
      expect(stats.categories, {'Series': 2, 'Mặc định': 1, 'Writer': 1});
      expect(stats.sources, {'Truyện cục bộ': 3});
    },
  );
}
