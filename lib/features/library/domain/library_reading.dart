import 'library_book.dart';

bool chapterIsRead(LibraryBook book, int index) =>
    book.completed ||
    (book.chapters[index].read ??
        (book.lastRead != null &&
            (index < book.currentChapter ||
                (index == book.currentChapter &&
                    book.progress * book.chapters.length - index >= .999))));

int readChapterCount(LibraryBook book) => book.chapters.indexed
    .where((entry) => chapterIsRead(book, entry.$1))
    .length;
