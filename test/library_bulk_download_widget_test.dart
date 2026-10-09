import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tachi_books/core/theme/app_theme.dart';
import 'package:tachi_books/features/downloads/data/download_queue_repository.dart';
import 'package:tachi_books/features/downloads/presentation/download_queue_controller.dart';
import 'package:tachi_books/features/library/data/library_repository.dart';
import 'package:tachi_books/features/library/domain/library_book.dart';
import 'package:tachi_books/features/library/presentation/library_screen.dart';
import 'package:tachi_books/features/library/presentation/library_view_model.dart';
import 'package:tachi_books/features/settings/settings_controller.dart';

void main() {
  setUp(
    () => SharedPreferences.setMockInitialValues({'downloadConcurrency': 1}),
  );

  for (final size in const [Size(320, 568), Size(430, 932)]) {
    testWidgets(
      'bulk download selects visible books, deduplicates and supports pause/resume at $size',
      (tester) async {
        final fixture = await _mount(tester, size);
        final queue = fixture.container.read(downloadQueueProvider.notifier);
        await queue.enqueue('tachi', ['read']);
        await _selectVisible(tester);
        expect(find.text('Đã chọn 3'), findsOneWidget);
        await _choose(tester, 'Tất cả chương chưa tải');
        final state = fixture.container.read(downloadQueueProvider);
        expect(state.running, isTrue);
        expect(state.tasks.map((job) => '${job.bookId}:${job.chapterId}'), [
          'tachi:read',
          'tachi:shared-unread',
          'vbook:shared-unread',
          'vbook:read',
        ]);
        expect(fixture.calls, ['tachi:read']);
        expect(find.text('Đã thêm 3 chương vào hàng đợi tải'), findsOneWidget);
        expect(
          DownloadQueueRepository(fixture.preferences).load(),
          hasLength(4),
        );
        await _expectMetadata(fixture);
        ScaffoldMessenger.of(tester.element(find.byType(LibraryScreen)))
            .clearSnackBars();
        await tester.pumpAndSettle();
        await _choose(tester, 'Tất cả chương chưa tải');
        expect(
          fixture.container.read(downloadQueueProvider).tasks,
          hasLength(4),
        );
        expect(fixture.calls, ['tachi:read']);
        expect(
          find.text('Không có chương mới cần thêm vào hàng đợi'),
          findsOneWidget,
        );

        queue.pause();
        fixture.blockers['tachi:read']!.complete();
        await tester.pumpAndSettle();
        expect(fixture.container.read(downloadQueueProvider).running, isFalse);
        expect(
          fixture.container.read(downloadQueueProvider).tasks,
          hasLength(3),
        );
        expect(fixture.calls, ['tachi:read']);
        await queue.start();
        await tester.pumpAndSettle();
        expect(fixture.calls, ['tachi:read', 'tachi:shared-unread']);
        queue.pause();
        fixture.blockers['tachi:shared-unread']!.complete();
        await tester.pumpAndSettle();
        expect(
          fixture.container.read(downloadQueueProvider).tasks,
          hasLength(2),
        );
        await _expectMetadata(fixture);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      },
    );
  }

  testWidgets(
    'unread-only bulk download preserves original IDs and independent read flags',
    (tester) async {
      final fixture = await _mount(tester, const Size(320, 568));
      await _selectVisible(tester);
      await _choose(tester, 'Chương chưa đọc chưa tải');
      expect(
        fixture.container
            .read(downloadQueueProvider)
            .tasks
            .map((job) => '${job.bookId}:${job.chapterId}'),
        ['tachi:shared-unread', 'vbook:shared-unread'],
      );
      expect(fixture.calls, ['tachi:shared-unread']);
      expect(find.text('Đã thêm 2 chương vào hàng đợi tải'), findsOneWidget);
      await _expectMetadata(fixture);
      fixture.container.read(downloadQueueProvider.notifier).pause();
      fixture.blockers['tachi:shared-unread']!.complete();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'cancel and queue errors do not report a successful bulk download',
    (tester) async {
      SharedPreferences.setMockInitialValues({
        'downloadConcurrency': 1,
        DownloadQueueRepository.key: 'invalid saved queue',
      });
      final fixture = await _mount(tester, const Size(320, 568));
      await _selectVisible(tester);
      await tester.tap(find.byTooltip('Tải truyện đã chọn'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Hủy'));
      await tester.pumpAndSettle();
      expect(fixture.calls, isEmpty);
      await _choose(tester, 'Tất cả chương chưa tải');
      expect(fixture.calls, isEmpty);
      expect(fixture.container.read(downloadQueueProvider).running, isFalse);
      expect(
        fixture.container.read(downloadQueueProvider).storageError,
        isNotNull,
      );
      expect(find.textContaining('Đã thêm'), findsNothing);
      expect(
        fixture.preferences.getString(DownloadQueueRepository.key),
        'invalid saved queue',
      );
      await _expectMetadata(fixture);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'bulk sheet opened before restore cannot enqueue the replacement',
    (tester) async {
      final fixture = await _mount(tester, const Size(430, 932));
      await _selectVisible(tester);
      await tester.tap(find.byTooltip('Tải truyện đã chọn'));
      await tester.pumpAndSettle();
      await fixture.repository.clear();
      final replacement = fixture.books.first.copyWith(
        title: 'Sách sau khôi phục',
        sourceRef: 'different-source-reference',
      );
      await fixture.repository.save(replacement);
      await fixture.container.read(libraryProvider.notifier).refresh();
      await tester.pumpAndSettle();
      await tester.tap(find.text('Tất cả chương chưa tải'));
      await tester.pumpAndSettle();
      expect(fixture.calls, isEmpty);
      expect(fixture.container.read(downloadQueueProvider).tasks, isEmpty);
      expect(find.textContaining('Đã thêm'), findsNothing);
      expect(
        (await fixture.repository.find(replacement.id))!.toJson(),
        replacement.toJson(),
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );
}

typedef _Fixture = ({
  MemoryLibraryRepository repository,
  ProviderContainer container,
  SharedPreferences preferences,
  List<LibraryBook> books,
  List<String> calls,
  Map<String, Completer<void>> blockers,
});

Future<_Fixture> _mount(WidgetTester tester, Size size) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);
  final preferences = await SharedPreferences.getInstance();
  final repository = MemoryLibraryRepository();
  final books = [
    LibraryBook(
      id: 'tachi',
      title: 'Truyện tranh',
      engine: 'tachimanga',
      kind: 'manga',
      sourceId: 'tachi-source',
      sourceRef: 'original-tachi-title',
      collection: 'Kệ tải',
      currentChapter: 2,
      progress: .8,
      lastRead: DateTime(2026, 10, 10),
      bookmarks: const ['2:0.5000'],
      chapters: const [
        BookChapter(id: 'read', title: 'Đã đọc', index: 0, read: true),
        BookChapter(
          id: 'downloaded',
          title: 'Đã tải',
          index: 1,
          downloaded: true,
          read: false,
        ),
        BookChapter(
          id: 'shared-unread',
          title: 'Chưa đọc',
          index: 2,
          read: false,
        ),
      ],
    ),
    LibraryBook(
      id: 'vbook',
      title: 'Truyện chữ',
      engine: 'vbook',
      sourceId: 'vbook-source',
      sourceRef: 'original-vbook-title',
      collection: 'Kệ tải',
      favorite: true,
      notes: 'Giữ ghi chú',
      chapters: const [
        BookChapter(
          id: 'shared-unread',
          title: 'Chưa đọc',
          index: 0,
          read: false,
        ),
        BookChapter(id: 'read', title: 'Đã đọc', index: 1, read: true),
      ],
    ),
    LibraryBook(
      id: 'local',
      title: 'EPUB đã nhập',
      collection: 'Kệ tải',
      chapters: const [BookChapter(id: 'local', title: 'Trong máy', index: 0)],
    ),
    LibraryBook(
      id: 'outside',
      title: 'Ngoài bộ lọc',
      engine: 'vbook',
      collection: 'Kệ khác',
      chapters: const [BookChapter(id: 'outside', title: 'Ngoài kệ', index: 0)],
    ),
  ];
  for (final book in books) {
    await repository.save(book);
  }
  final calls = <String>[];
  final blockers = <String, Completer<void>>{};
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        preferencesProvider.overrideWithValue(preferences),
        libraryRepositoryProvider.overrideWithValue(repository),
        downloadJobExecutorProvider.overrideWithValue((book, index) {
          final identity = '${book.id}:${book.chapters[index].id}';
          calls.add(identity);
          return (blockers[identity] = Completer<void>()).future;
        }),
      ],
      child: MaterialApp(
        theme: appTheme(Brightness.dark),
        home: const LibraryScreen(),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return (
    repository: repository,
    container: ProviderScope.containerOf(
      tester.element(find.byType(LibraryScreen)),
    ),
    preferences: preferences,
    books: books,
    calls: calls,
    blockers: blockers,
  );
}

Future<void> _selectVisible(WidgetTester tester) async {
  await tester.ensureVisible(
    find.byKey(const ValueKey('library-group-value:Kệ tải')),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const ValueKey('library-group-value:Kệ tải')));
  await tester.pumpAndSettle();
  expect(find.byKey(const ValueKey('library-book-outside')), findsNothing);
  await tester.longPress(find.byKey(const ValueKey('library-book-tachi')));
  await tester.pumpAndSettle();
  await tester.tap(find.byTooltip('Chọn tất cả sách hiển thị'));
  await tester.pumpAndSettle();
}

Future<void> _choose(WidgetTester tester, String option) async {
  await tester.tap(find.byTooltip('Tải truyện đã chọn'));
  await tester.pumpAndSettle();
  await tester.tap(find.text(option));
  await tester.pumpAndSettle();
}

Future<void> _expectMetadata(_Fixture fixture) async {
  expect(
    fixture.container
        .read(libraryProvider)
        .requireValue
        .map((book) => book.toJson()),
    fixture.books.map((book) => book.toJson()),
  );
  expect(
    (await fixture.repository.list()).map((book) => book.toJson()),
    fixture.books.map((book) => book.toJson()),
  );
}
