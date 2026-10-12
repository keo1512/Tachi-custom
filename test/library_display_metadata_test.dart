import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tachi_books/core/theme/app_theme.dart';
import 'package:tachi_books/features/deep_links/application/deep_link_queue.dart';
import 'package:tachi_books/features/library/data/backup_configuration.dart';
import 'package:tachi_books/features/library/data/library_repository.dart';
import 'package:tachi_books/features/library/domain/library_book.dart';
import 'package:tachi_books/features/library/domain/library_grouping.dart';
import 'package:tachi_books/features/library/presentation/library_book_metadata.dart';
import 'package:tachi_books/features/library/presentation/library_book_tile.dart';
import 'package:tachi_books/features/library/presentation/library_filter_controller.dart';
import 'package:tachi_books/features/library/presentation/library_filter_sheet.dart';
import 'package:tachi_books/features/library/presentation/library_screen.dart';
import 'package:tachi_books/features/library/presentation/library_view_model.dart';
import 'package:tachi_books/features/settings/settings_controller.dart';

const _all = LibraryFilter(
  showSource: true,
  showReadingStatus: true,
  showReadCount: true,
  showFavoriteBadge: true,
  showLastUpdated: true,
  showPublicationStatus: true,
  showResumeButton: true,
  showDownloadedBadge: true,
  showLocalBadge: true,
);

LibraryBook _book() => LibraryBook(
  id: 'book',
  title: 'Một truyện có tiêu đề rất dài để kiểm tra bố cục',
  engine: 'tachimanga',
  sourceId: '9223372036854775807',
  sourceName: 'Nguồn tên dài để kiểm tra hiển thị',
  sourceRef: 'https://example.test/story',
  favorite: true,
  status: 1,
  lastUpdated: DateTime(2026, 10, 12),
  lastRead: DateTime(2026, 10, 11),
  currentChapter: 1,
  chapters: const [
    BookChapter(id: 'c1', title: 'Một', index: 0, read: true),
    BookChapter(
      id: 'c 2/?#✓',
      title: 'Hai',
      index: 1,
      read: false,
      downloaded: true,
    ),
  ],
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('display flags retain defaults for old preferences and roundtrip through portable backup', () async {
    final old = LibraryFilter.fromJson({'showUnreadBadge': false});
    expect(old.showSource, isFalse);
    expect(old.showResumeButton, isFalse);
    expect(old.showUnreadBadge, isFalse);
    expect(
      () => LibraryFilter.fromJson({'showReadCount': 'true'}),
      throwsFormatException,
    );
    expect(LibraryFilter.fromJson(_all.toJson()).toJson(), _all.toJson());
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(
      'libraryFilterV1',
      jsonEncode(LibraryFilterPreferences(filter: _all).toJson()),
    );
    final configuration = BackupConfiguration.capture(preferences);
    final restored = BackupConfiguration.fromJson(configuration.toJson());
    final portable = LibraryFilterPreferences.fromJson(
      jsonDecode(restored.values['libraryFilterV1'] as String)
          as Map<String, dynamic>,
    );
    expect(portable.filter.toJson(), _all.toJson());
    final scoped = LibraryFilterPreferences(
      filter: _all,
      sorts: {
        LibraryFilterPreferences.scope(
          LibraryGrouping.collection,
          'value:Nhóm',
        ): const LibraryFilter(
          order: LibraryOrder.title,
        ),
      },
    ).forGroup(LibraryGrouping.collection, 'value:Nhóm');
    expect(scoped.order, LibraryOrder.title);
    expect(scoped.showSource, isTrue);
    expect(scoped.showResumeButton, isTrue);
  });

  test('source names are optional and preserve exact source IDs', () {
    final book = _book();
    expect(LibraryBook.fromJson(book.toJson()).sourceName, book.sourceName);
    expect(LibraryBook.fromJson(book.toJson()).sourceId, '9223372036854775807');
    final old = book.toJson()..remove('sourceName');
    expect(LibraryBook.fromJson(old).sourceName, '');
    expect(book.copyWith(notes: 'Ghi chú').sourceName, book.sourceName);
  });

  for (final size in const [Size(320, 568), Size(430, 932)]) {
    for (final display in LibraryDisplay.values) {
      testWidgets(
        'metadata and stable chapter resume at $size in ${display.name}',
        (tester) async {
          tester.view.devicePixelRatio = 1;
          tester.view.physicalSize = size;
          addTearDown(tester.view.reset);
          final prefs = await SharedPreferences.getInstance();
          final filter = _all.copyWith(display: display);
          await prefs.setString(
            'libraryFilterV1',
            jsonEncode(LibraryFilterPreferences(filter: filter).toJson()),
          );
          final repo = MemoryLibraryRepository();
          await repo.save(
            _book().copyWith(
              clearLastRead: display == LibraryDisplay.coverOnly,
            ),
          );
          Uri? opened;
          Object? handoff;
          final router = GoRouter(
            routes: [
              GoRoute(path: '/', builder: (_, _) => const LibraryScreen()),
              GoRoute(
                path: '/read/:id',
                builder: (_, state) {
                  opened = state.uri;
                  handoff = state.extra;
                  return const Scaffold(body: Text('Reader thử nghiệm'));
                },
              ),
              GoRoute(
                path: '/book/:id',
                builder: (_, _) => const Scaffold(body: Text('Chi tiết')),
              ),
            ],
          );
          addTearDown(router.dispose);
          await tester.pumpWidget(
            ProviderScope(
              overrides: [
                libraryRepositoryProvider.overrideWithValue(repo),
                preferencesProvider.overrideWithValue(prefs),
              ],
              child: MaterialApp.router(
                routerConfig: router,
                theme: appTheme(Brightness.dark),
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(context)
                      .copyWith(textScaler: const TextScaler.linear(1.5)),
                  child: child!,
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          for (final key in [
            'source',
            'reading',
            'read',
            'favorite',
            'updated',
            'status',
          ]) {
            expect(
              find.byKey(ValueKey('library-metadata-book-$key')),
              findsOneWidget,
            );
          }
          expect(find.byType(LibraryBookMetadata), findsOneWidget);
          if (display != LibraryDisplay.list) {
            expect(find.byType(LibraryBookTile), findsOneWidget);
            expect(
              find.byKey(const ValueKey('library-metadata-book-downloaded')),
              findsNothing,
            );
          } else {
            expect(
              find.byKey(const ValueKey('library-metadata-book-downloaded')),
              findsOneWidget,
            );
          }
          expect(tester.takeException(), isNull);
          final before = (await repo.snapshot()).encode();
          await tester.ensureVisible(
            find.byKey(const ValueKey('library-resume-book')),
          );
          await tester.tap(find.byKey(const ValueKey('library-resume-book')));
          await tester.pumpAndSettle();
          expect(opened?.queryParameters['chapterId'], 'c 2/?#✓');
          expect(handoff, isA<LibraryLinkHandoff>());
          expect(
            (handoff as LibraryLinkHandoff).expectedRevision,
            repo.replacementRevision,
          );
          expect(find.text('Reader thử nghiệm'), findsOneWidget);
          expect((await repo.snapshot()).encode(), before);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pumpAndSettle();
        },
      );
    }
  }

  testWidgets('disabled labels remain hidden and selection disables resume', (
    tester,
  ) async {
    final book = _book();
    var resumes = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 100,
            height: 180,
            child: LibraryBookTile(
              book: book,
              filter: const LibraryFilter(),
              onResume: () => resumes++,
            ),
          ),
        ),
      ),
    );
    expect(find.byType(LibraryBookMetadata), findsOneWidget);
    expect(
      find.byKey(const ValueKey('library-metadata-book-source')),
      findsNothing,
    );
    expect(find.byKey(const ValueKey('library-resume-book')), findsNothing);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 100,
            height: 400,
            child: LibraryBookTile(
              book: book,
              filter: _all,
              selected: true,
              onResume: () => resumes++,
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('library-resume-book')));
    expect(resumes, 0);
    expect(tester.takeException(), isNull);
  });
}
