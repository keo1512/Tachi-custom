import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tachi_books/core/widgets/book_cover.dart';
import 'package:tachi_books/features/library/data/library_repository.dart';
import 'package:tachi_books/features/library/domain/library_book.dart';
import 'package:tachi_books/features/library/presentation/library_view_model.dart';
import 'package:tachi_books/features/settings/presentation/tracking_settings_screen.dart';
import 'package:tachi_books/features/settings/settings_controller.dart';

class _PendingCover extends ImageProvider<_PendingCover> {
  final completer = Completer<ImageInfo>();
  @override
  Future<_PendingCover> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(this);
  @override
  ImageStreamCompleter loadImage(
    _PendingCover key,
    ImageDecoderCallback decode,
  ) => OneFrameImageStreamCompleter(completer.future);
}

void main() {
  testWidgets('cover loading and failure keep geometry, title and badges', (
    tester,
  ) async {
    final provider = _PendingCover();
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: SizedBox(
            width: 80,
            height: 120,
            child: BookCover(
              title: 'Truyện mẫu',
              imageProvider: provider,
              unread: 12,
              downloaded: 3,
              showDownloadedBadge: true,
            ),
          ),
        ),
      ),
    );
    expect(find.byKey(const ValueKey('book-cover-loading')), findsOneWidget);
    final size = tester.getSize(find.byType(BookCover));
    provider.completer.completeError(StateError('cover unavailable'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('book-cover-error')), findsOneWidget);
    expect(find.byKey(const ValueKey('book-cover-loading')), findsNothing);
    expect(tester.getSize(find.byType(BookCover)), size);
    expect(find.text('Truyện mẫu'), findsOneWidget);
    expect(find.text('12'), findsOneWidget);
    expect(find.text('3'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await provider.evict();
  });

  for (final width in [320.0, 430.0, 1024.0]) {
    testWidgets(
      'local reading status edits real library and resets search at $width',
      (tester) async {
        tester.view.physicalSize = Size(width, 768);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        SharedPreferences.setMockInitialValues({});
        final preferences = await SharedPreferences.getInstance();
        final library = MemoryLibraryRepository();
        await library.save(
          LibraryBook(
            id: 'one',
            title: 'Truyện mẫu',
            chapters: const [
              BookChapter(id: 'chapter', title: 'Chương một', index: 0),
            ],
          ),
        );
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              preferencesProvider.overrideWithValue(preferences),
              libraryRepositoryProvider.overrideWithValue(library),
            ],
            child: MaterialApp(
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(textScaler: const TextScaler.linear(1.5)),
                child: child!,
              ),
              home: const TrackingSettingsScreen(),
            ),
          ),
        );
        expect(find.text('Trạng thái và đánh giá'), findsOneWidget);
        expect(find.text('Dịch vụ theo dõi bên ngoài'), findsNothing);
        await tester.tap(find.text('Trạng thái và đánh giá từng truyện'));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byType(CupertinoSearchTextField),
          'Không có',
        );
        await tester.pumpAndSettle();
        expect(find.text('Không có truyện phù hợp.'), findsOneWidget);
        await tester.tap(find.text('Hiện tất cả truyện'));
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<CupertinoSearchTextField>(
                find.byType(CupertinoSearchTextField),
              )
              .controller!
              .text,
          isEmpty,
        );
        await tester.tap(find.byKey(const ValueKey('statistics-state-one')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('statistics-state-paused')));
        await tester.pumpAndSettle();
        expect((await library.list()).single.readingState, 'paused');
        expect(tester.takeException(), isNull);
      },
    );
  }
}
