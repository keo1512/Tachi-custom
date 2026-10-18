import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tachi_books/features/downloads/presentation/download_queue_controller.dart';
import 'package:tachi_books/features/library/data/library_repository.dart';
import 'package:tachi_books/features/library/application/library_update_scheduler.dart';
import 'package:tachi_books/features/library/domain/library_book.dart';
import 'package:tachi_books/features/library/presentation/library_view_model.dart';
import 'package:tachi_books/features/reader/presentation/reader_screen.dart';
import 'package:tachi_books/features/settings/settings_controller.dart';
import 'package:tachi_books/features/sources/data/source_repository.dart';
import 'package:tachi_books/features/sources/domain/catalogue.dart';

final _image = SourceImageData(
  bytes: base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAABAAAAAgCAIAAACU62+bAAAAIUlEQVR4nGP4z8BAEiJN9aiGUQ1DS8OgdNSohlENA6MBAEGm/hCBgiIOAAAAAElFTkSuQmCC',
  ),
  mimeType: 'image/png',
);
final _images = [
  for (var page = 0; page < 10; page++) 'https://fixture.example/$page.png',
];

class _Source extends SourceRepository {
  _Source(this.first) : super(tachimangaUrl: '', vbookUrl: '');
  final Completer<SourceImageData> first;
  Completer<SourceImageData>? nextFirst;
  final requests = <String>[];

  @override
  bool usesNativeImageLoader(CatalogueBook book) => true;

  @override
  Future<SourceImageData> fetchImage(
    CatalogueBook book,
    CatalogueChapter chapter,
    int page,
    String url,
  ) {
    requests.add('image:${chapter.ref}:$page');
    if (chapter.ref == 'next' && page == 0 && nextFirst != null) {
      return nextFirst!.future;
    }
    return chapter.ref == 'first' && page == 0
        ? first.future
        : Future.value(_image);
  }

  @override
  Future<ChapterContent> chapter(
    CatalogueBook book,
    CatalogueChapter chapter,
  ) async {
    requests.add('chapter:${chapter.ref}');
    return ChapterContent(kind: ContentKind.manga, images: _images);
  }
}

typedef _Fixture = ({
  MemoryLibraryRepository repo,
  ProviderContainer container,
  _Source source,
  Completer<SourceImageData> image,
  List<String> starts,
});

Future<void> _drain(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<_Fixture> _open(
  WidgetTester tester,
  String layout, {
  bool private = false,
  String kind = 'manga',
  Future<Map<String, bool>?> Function()? conditions,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(430, 932);
  addTearDown(tester.view.reset);
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  SharedPreferences.setMockInitialValues({
    'libraryUpdatePolicyV1': jsonEncode({
      'downloadAhead': 1,
      'wifiOnly': conditions != null,
    }),
    'readerOptionsV1': jsonEncode({'mangaLayout': layout}),
    'incognitoMode': private,
  });
  final preferences = await SharedPreferences.getInstance();
  final repo = MemoryLibraryRepository();
  await repo.save(
    LibraryBook(
      id: 'priority',
      title: 'Reader priority',
      kind: kind,
      engine: 'tachi',
      sourceId: '17',
      sourceRef: '/series',
      chapters: const [
        BookChapter(id: 'first', title: 'First', index: 0, read: false),
        BookChapter(id: 'next', title: 'Next', index: 1, read: false),
        BookChapter(id: 'last', title: 'Last', index: 2, read: false),
      ],
    ),
  );
  await repo.saveChapter(
    'priority',
    0,
    ReaderContent(
      kind: kind,
      images: kind == 'manga' ? _images : [],
      html: kind == 'novel' ? '<p>Text content</p>' : '',
    ),
  );
  final image = Completer<SourceImageData>(), starts = <String>[];
  final source = _Source(image);
  final container = ProviderContainer(
    overrides: [
      preferencesProvider.overrideWithValue(preferences),
      libraryRepositoryProvider.overrideWithValue(repo),
      sourceRepositoryProvider.overrideWithValue(source),
      if (conditions != null)
        updateDeviceConditionsProvider.overrideWithValue(conditions),
      downloadJobExecutorProvider.overrideWithValue((book, index) async {
        starts.add(book.chapters[index].id);
      }),
    ],
  );
  addTearDown(() {
    container.dispose();
    source.dispose();
  });
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: ReaderScreen(id: 'priority')),
    ),
  );
  await _drain(tester);
  return (
    repo: repo,
    container: container,
    source: source,
    image: image,
    starts: starts,
  );
}

void main() {
  for (final layout in ['continuous', 'leftToRight']) {
    for (final stop in ['dispose', 'restore', 'pause']) {
      testWidgets(
        '$layout pending download conditions cannot enqueue after $stop',
        (tester) async {
          final conditions = Completer<Map<String, bool>?>();
          var checks = 0;
          final fixture = await _open(
            tester,
            layout,
            conditions: () {
              checks++;
              return conditions.future;
            },
          );
          expect(checks, 0);
          fixture.image.complete(_image);
          await _drain(tester);
          expect(checks, 1);
          if (stop == 'dispose') {
            await tester.pumpWidget(const SizedBox.shrink());
          }
          if (stop == 'pause') {
            tester.binding.handleAppLifecycleStateChanged(
              AppLifecycleState.paused,
            );
          }
          if (stop == 'restore') {
            final snapshot = await fixture.repo.snapshot();
            await fixture.repo.replaceSnapshot(
              snapshot,
              expectedFingerprint: snapshot.fingerprint,
            );
          }
          conditions.complete({'wifi': true, 'charging': true});
          await _drain(tester);
          expect(fixture.starts, isEmpty);
          expect(fixture.container.read(downloadQueueProvider).tasks, isEmpty);
          if (stop == 'pause') {
            tester.binding.handleAppLifecycleStateChanged(
              AppLifecycleState.resumed,
            );
            await _drain(tester);
            expect(fixture.starts, ['next']);
          }
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
        },
      );
    }

    testWidgets(
      '$layout old reader generation cannot start download ahead for the new chapter',
      (tester) async {
        final fixture = await _open(tester, layout);
        fixture.source.nextFirst = Completer<SourceImageData>();
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: fixture.container,
            child: const MaterialApp(
              home: ReaderScreen(id: 'priority', chapter: 1),
            ),
          ),
        );
        await _drain(tester);
        expect(fixture.source.requests, contains('image:next:0'));
        fixture.image.complete(_image);
        await _drain(tester);
        expect(fixture.starts, isEmpty);
        fixture.source.nextFirst!.complete(_image);
        await _drain(tester);
        expect(fixture.starts, ['last']);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );

    testWidgets(
      '$layout download ahead waits for first visible decode and starts only once',
      (tester) async {
        final fixture = await _open(tester, layout);
        expect(fixture.source.requests, ['image:first:0']);
        expect(fixture.starts, isEmpty);
        fixture.image.complete(_image);
        await _drain(tester);
        expect(fixture.starts, ['next']);
        await _drain(tester);
        expect(fixture.starts, ['next']);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );

    for (final stop in ['failure', 'dispose', 'restore', 'private']) {
      testWidgets(
        '$layout late first image cannot start download ahead after $stop',
        (tester) async {
          final fixture = await _open(
            tester,
            layout,
            private: stop == 'private',
          );
          expect(fixture.starts, isEmpty);
          if (stop == 'dispose') {
            await tester.pumpWidget(const SizedBox.shrink());
          }
          if (stop == 'restore') {
            final snapshot = await fixture.repo.snapshot();
            await fixture.repo.replaceSnapshot(
              snapshot,
              expectedFingerprint: snapshot.fingerprint,
            );
          }
          if (stop == 'failure') {
            fixture.image.completeError(
              const ApiException('Fixture image unavailable'),
            );
          } else {
            fixture.image.complete(_image);
          }
          await _drain(tester);
          expect(fixture.starts, isEmpty);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
        },
      );
    }

    testWidgets(
      '$layout paused reader defers download ahead until resumed with a decoded page',
      (tester) async {
        final fixture = await _open(tester, layout);
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        fixture.image.complete(_image);
        await _drain(tester);
        expect(fixture.starts, isEmpty);
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await _drain(tester);
        expect(fixture.starts, ['next']);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets(
    'text reader keeps automatic download ahead without an image gate',
    (tester) async {
      final fixture = await _open(tester, 'continuous', kind: 'novel');
      expect(fixture.starts, ['next']);
      expect(fixture.source.requests, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
