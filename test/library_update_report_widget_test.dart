import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tachi_books/features/library/domain/library_update_result.dart';
import 'package:tachi_books/features/library/presentation/library_update_report_panel.dart';

void main() {
  for (final size in [const Size(320, 568), const Size(430, 932)]) {
    testWidgets(
      'update report exposes grouped errors, skip reasons and retry at $size',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = size;
        addTearDown(tester.view.reset);
        var retries = 0;
        final result = LibraryUpdateResult(
          requestedBooks: 3,
          checkedBooks: 1,
          addedChapters: 2,
          skippedBooks: 1,
          failures: const [
            LibraryUpdateFailure(
              bookId: 'a',
              title: 'Truyện lỗi',
              message: 'HTTP 503',
              sourceIdentity: 'tachimanga:9223372036854775810',
            ),
          ],
          skipped: const [
            LibraryUpdateSkipped(
              bookId: 'b',
              title: 'Truyện local',
              reason: 'Truyện trên máy',
            ),
          ],
        );
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: LibraryUpdateReportPanel(
                report: result,
                busy: false,
                onRetry: () => retries++,
              ),
            ),
          ),
        );
        await tester.tap(find.text('Thử lại 1 truyện lỗi'));
        expect(retries, 1);
        await tester.tap(find.text('Chi tiết kết quả'));
        await tester.pumpAndSettle();
        expect(find.text('Truyện lỗi'), findsOneWidget);
        expect(
          find.text('Nguồn đang gặp lỗi máy chủ. Hãy thử lại sau (HTTP 503).'),
          findsOneWidget,
        );
        expect(find.text('Truyện trên máy'), findsOneWidget);
        expect(find.textContaining('9223372036854775810'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
    testWidgets('update progress presents actual processed count at $size', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = size;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: LibraryUpdateReportPanel(
              busy: true,
              onRetry: () {},
              progress: const LibraryUpdateProgress(
                requestedBooks: 4,
                processedBooks: 2,
                checkedBooks: 1,
                addedChapters: 8,
                skippedBooks: 1,
                failedBooks: 0,
                currentTitle: 'Tên truyện đang tải rất dài để kiểm tra bố cục',
              ),
            ),
          ),
        ),
      );
      expect(
        tester
            .widget<LinearProgressIndicator>(
              find.byType(LinearProgressIndicator),
            )
            .value,
        .5,
      );
      expect(find.text('2/4 truyện · 8 chương mới · 0 lỗi'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
