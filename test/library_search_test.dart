import 'package:flutter_test/flutter_test.dart';
import 'package:tachi_books/features/library/domain/library_book.dart';
import 'package:tachi_books/features/library/domain/library_search.dart';

void main() {
  final book = LibraryBook(
    id: 'stable',
    title: 'Hành trình',
    author: 'Nguyễn Văn A',
    artist: 'Họa sĩ B',
    genres: ['Phiêu lưu', 'Đời thường'],
    notes: 'Đọc sau chuyến đi',
    series: 'Bộ A',
    sourceId: '9007199254740995',
    engine: 'tachimanga',
    chapters: const [
      BookChapter(id: 'a', title: 'A', index: 0, read: true),
      BookChapter(id: 'b', title: 'B', index: 1, read: false),
      BookChapter(id: 'c', title: 'C', index: 2, read: true),
    ],
  );

  test(
    'metadata search supports Vietnamese quoted phrases and field aliases',
    () {
      expect(
        LibrarySearch('author:"nguyễn văn a" artist:"họa sĩ"').matches(book),
        isTrue,
      );
      expect(
        LibrarySearch("note:'sau chuyến đi' tag:'đời thường'").matches(book),
        isTrue,
      );
      expect(LibrarySearch('nguyễn chuyến').matches(book), isTrue);
      expect(LibrarySearch('author:"Nguyễn B"').matches(book), isFalse);
      expect(
        LibrarySearch('series:"Bộ A" source:tachimanga').matches(book),
        isTrue,
      );
    },
  );
  test('AND has priority over OR and grouped negation changes the whole expression', () {
    expect(
      LibrarySearch('title:sai || author:nguyễn && genre:sai').matches(book),
      isFalse,
    );
    expect(
      LibrarySearch('(title:sai || author:nguyễn) && genre:phiêu')
          .matches(book),
      isTrue,
    );
    expect(LibrarySearch('-(notes:sau || artist:B)').matches(book), isFalse);
    expect(LibrarySearch('--author:nguyễn -genre:kinh').matches(book), isTrue);
  });
  test('nonsequential read flags drive read/unread counts and exact int64 source matching', () {
    expect(readChapterCount(book), 2);
    expect(
      LibrarySearch('read>=2 unread=1 total<=3 source_id:9007199254740995')
          .matches(book),
      isTrue,
    );
    expect(
      LibrarySearch('sourceid:9007199254740994 || read<2').matches(book),
      isFalse,
    );
    expect(
      LibrarySearch('unread=0').matches(book.copyWith(completed: true)),
      isTrue,
    );
  });
  test('old JSON defaults and sequential progress remain compatible with field/count queries', () {
    final old = LibraryBook.fromJson({
      'id': 'old',
      'title': 'Old',
      'chapters': [
        for (var index = 0; index < 3; index++)
          {'id': '$index', 'title': 'Chapter $index', 'index': index},
      ],
      'currentChapter': 1,
      'progress': .5,
      'lastRead': '2026-10-10T10:00:00Z',
    });
    expect(
      LibrarySearch('notes:"" artist:"" genre:"" read=1 unread=2').matches(old),
      isTrue,
    );
    expect(LibrarySearch('-notes:""').matches(old), isFalse);
  });
  test('oversized and deeply nested queries are bounded without recursion failures', () {
    expect(LibrarySearch('x' * 4097).matches(book), isFalse);
    expect(
      LibrarySearch('${'(' * 1000}title:Hành${')' * 1000}').matches(book),
      isFalse,
    );
  });
}
