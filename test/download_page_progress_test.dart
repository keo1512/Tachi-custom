import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tachi_books/features/downloads/presentation/download_queue_controller.dart';
import 'package:tachi_books/features/downloads/presentation/downloads_screen.dart';
import 'package:tachi_books/features/library/data/library_repository.dart';
import 'package:tachi_books/features/library/domain/library_book.dart';
import 'package:tachi_books/features/library/presentation/library_view_model.dart';
import 'package:tachi_books/features/settings/settings_controller.dart';

void main() {
  for (final size in [const Size(320, 568), const Size(430, 932)]) {
    testWidgets(
      'measured page progress updates without durable writes or stale callbacks at $size',
      (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        SharedPreferences.setMockInitialValues({});
        final preferences = await SharedPreferences.getInstance();
        final repository = MemoryLibraryRepository();
        await repository.save(
          LibraryBook(
            id: 'a',
            title: 'Truyện thử',
            engine: 'vbook',
            sourceId: 'source',
            sourceRef: '/book',
            chapters: [BookChapter(id: 'c', title: 'Chương thử', index: 0)],
          ),
        );
        DownloadExecution? execution;
        final release = Completer<void>();
        final container = ProviderContainer(
          overrides: [
            preferencesProvider.overrideWithValue(preferences),
            libraryRepositoryProvider.overrideWithValue(repository),
            guardedDownloadJobExecutorProvider.overrideWithValue((
              book,
              index,
              current,
            ) async {
              execution = current;
              await release.future;
            }),
          ],
        );
        addTearDown(container.dispose);
        await container.read(libraryProvider.future);
        final controller = container.read(downloadQueueProvider.notifier);
        await controller.enqueue('a', ['c']);
        await controller.start();
        for (var i = 0; i < 25 && execution == null; i++) {
          await tester.pump();
        }
        expect(execution, isNotNull);
        final identity = container
            .read(downloadQueueProvider)
            .tasks
            .single
            .identity;
        final before = {
          for (final key in preferences.getKeys()) key: preferences.get(key),
        };
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              home: MediaQuery(
                data: MediaQueryData(
                  size: size,
                  textScaler: const TextScaler.linear(1.5),
                ),
                child: const DownloadsScreen(),
              ),
            ),
          ),
        );
        await tester.pump();
        for (
          var i = 0;
          i < 30 && find.text('Truyện thử').evaluate().isEmpty;
          i++
        ) {
          await tester.pump(const Duration(milliseconds: 20));
        }
        await tester.tap(find.text('Truyện thử'));
        await tester.pump(const Duration(milliseconds: 350));
        await tester.pump();
        expect(
          tester
              .widget<LinearProgressIndicator>(
                find.byType(LinearProgressIndicator),
              )
              .value,
          isNull,
        );
        execution!.reportPageProgress(2, 7);
        await tester.pump();
        expect(find.text('Đang tải • 2/7 trang'), findsOneWidget);
        expect(
          tester
              .widget<LinearProgressIndicator>(
                find.byType(LinearProgressIndicator),
              )
              .value,
          closeTo(2 / 7, 1e-12),
        );
        expect({
          for (final key in preferences.getKeys()) key: preferences.get(key),
        }, before);
        for (final pair in [(-1, 7), (8, 7), (0, 0), (1, 7), (3, 8)]) {
          execution!.reportPageProgress(pair.$1, pair.$2);
        }
        expect(controller.pageProgressFor(identity)!.completed, 2);
        await controller.pauseJob(identity);
        execution!.reportPageProgress(7, 7);
        await tester.pump();
        expect(controller.pageProgressFor(identity), isNull);
        expect(find.text('Đang tải • 7/7 trang'), findsNothing);
        expect(
          container.read(downloadQueueProvider).tasks.single.status,
          DownloadJobStatus.paused,
        );
        release.complete();
        await tester.pump();
        await tester.pumpWidget(const SizedBox());
        expect(tester.takeException(), isNull);
      },
    );
  }
}
