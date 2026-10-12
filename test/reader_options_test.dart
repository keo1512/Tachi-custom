import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tachi_books/features/library/data/backup_service.dart';
import 'package:tachi_books/features/library/data/backup_configuration.dart';
import 'package:tachi_books/features/library/data/coordinated_preferences.dart';
import 'package:tachi_books/features/library/data/library_snapshot.dart';
import 'package:tachi_books/features/library/data/library_repository.dart';
import 'package:tachi_books/features/library/domain/library_book.dart';
import 'package:tachi_books/features/library/presentation/library_view_model.dart';
import 'package:tachi_books/features/reader/domain/reader_options.dart';
import 'package:tachi_books/features/reader/presentation/reader_advanced_settings.dart';
import 'package:tachi_books/features/reader/presentation/reader_options_controller.dart';
import 'package:tachi_books/features/reader/presentation/reader_screen.dart';
import 'package:tachi_books/features/reader/presentation/zoomable_manga_page.dart';
import 'package:tachi_books/features/settings/settings_controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('flutter_tts'),
          (_) => Future.value(1),
        ),
  );
  test('legacy defaults and untrusted numeric preferences are bounded', () {
    final legacy = ReaderOptions.fromJson({});
    expect(legacy.margin, 0);
    expect(legacy.gap, 0);
    expect(legacy.showPageNumber, true);
    expect(legacy.orientationMargins, false);
    expect(legacy.backgroundMode, 'system');
    expect(legacy.disableBackSwipe, false);
    final invalid = ReaderOptions.fromJson({
      'margin': 999,
      'brightness': double.nan,
      'gap': -4,
      'orientation': 'android-only',
      'showPageNumber': 'false',
    });
    expect(invalid.margin, 64);
    expect(invalid.brightness, 1);
    expect(invalid.gap, 0);
    expect(invalid.orientation, 'free');
    expect(invalid.showPageNumber, true);
  });
  test('display options roundtrip and bound untrusted restored values', () {
    final options = ReaderOptions.fromJson({
      'margin': 12,
      'orientationMargins': true,
      'portraitLeft': 8,
      'portraitRight': 16,
      'landscapeLeft': 20,
      'landscapeRight': 28,
      'backgroundMode': 'custom',
      'backgroundColor': 0x00f5ebdc,
      'fullScreen': true,
      'hideStatusBar': true,
      'disableBackSwipe': true,
    });
    expect(
      options.pageMargins(Orientation.portrait),
      const EdgeInsets.only(left: 8, right: 16),
    );
    expect(
      options.pageMargins(Orientation.landscape),
      const EdgeInsets.only(left: 20, right: 28),
    );
    expect(options.pageBackground(Colors.black), const Color(0xfff5ebdc));
    expect(ReaderOptions.fromJson(options.toJson()).toJson(), options.toJson());
    expect(
      options
          .patch({'portraitLeft': null})
          .pageMargins(Orientation.portrait)
          .left,
      12,
    );
    expect(
      options
          .patch({'orientationMargins': false})
          .pageMargins(Orientation.landscape),
      const EdgeInsets.symmetric(horizontal: 12),
    );
    expect(
      ReaderOptions.fromJson({'portraitLeft': -5, 'landscapeRight': 999})
          .portraitLeft,
      0,
    );
    expect(ReaderOptions.fromJson({'landscapeRight': 999}).landscapeRight, 64);
  });
  test('concurrent patches retain independent options and restart', () async {
    SharedPreferences.setMockInitialValues({});
    final p = await SharedPreferences.getInstance();
    final c = ProviderContainer(
      overrides: [preferencesProvider.overrideWithValue(p)],
    );
    addTearDown(c.dispose);
    await Future.wait([
      c.read(readerOptionsProvider.notifier).patch({'grayscale': true}),
      c.read(readerOptionsProvider.notifier).patch({'gap': 12}),
      c.read(readerOptionsProvider.notifier).patch({'inverted': true}),
    ]);
    final restarted = ProviderContainer(
      overrides: [preferencesProvider.overrideWithValue(p)],
    );
    addTearDown(restarted.dispose);
    final options = restarted.read(readerOptionsProvider);
    expect(options.grayscale, true);
    expect(options.inverted, true);
    expect(options.gap, 12);
  });
  test('global reader editor generation refuses a write after configuration restore', () async {
    SharedPreferences.setMockInitialValues({});
    final repo = MemoryLibraryRepository();
    final prefs = await CoordinatedPreferences.open(
      await SharedPreferences.getInstance(),
      repo,
    );
    final container = ProviderContainer(
      overrides: [preferencesProvider.overrideWithValue(prefs)],
    );
    addTearDown(container.dispose);
    final editor = container.read(readerOptionsProvider.notifier);
    final generation = prefs.mutationGeneration;
    final backup = BackupService(
      repo,
      configuration: AppConfigurationStore(prefs),
    );
    final before = await backup.export();
    final incoming = LibrarySnapshot(
      [],
      configuration: BackupConfiguration.fromJson({
        'version': 1,
        'preferences': {
          'readerOptionsV1': jsonEncode({'gap': 4}),
        },
      }),
    ).encode();
    await backup.replace(
      incoming,
      expectedFingerprint: backup.fingerprint(before),
    );
    await expectLater(
      editor.patch({'holdScroll': true}, expectedGeneration: generation),
      throwsStateError,
    );
    expect(jsonDecode(prefs.getString('readerOptionsV1')!), {'gap': 4});
  });
  test(
    'per-title reader options travel with full backup to new library',
    () async {
      final repo = MemoryLibraryRepository();
      await repo.save(
        LibraryBook(
          id: 'b',
          title: 'Book',
          readerPreferences: const {
            'grayscale': true,
            'margin': 8,
            'orientationMargins': true,
            'portraitLeft': 10.0,
            'backgroundMode': 'dark',
            'fullScreen': true,
          },
        ),
      );
      final target = MemoryLibraryRepository();
      await BackupService(target).merge(await BackupService(repo).export());
      expect((await target.find('b'))!.readerPreferences, {
        'grayscale': true,
        'margin': 8,
        'orientationMargins': true,
        'portraitLeft': 10.0,
        'backgroundMode': 'dark',
        'fullScreen': true,
      });
    },
  );
  testWidgets('private setting dialog refuses writes after restore', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final p = await SharedPreferences.getInstance();
    final repo = MemoryLibraryRepository();
    final book = LibraryBook(id: 'b', title: 'Before');
    await repo.save(book);
    final container = ProviderContainer(
      overrides: [
        preferencesProvider.overrideWithValue(p),
        libraryRepositoryProvider.overrideWithValue(repo),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showAdvancedReaderSettings(
                  context,
                  book: book,
                  expectedRevision: repo.replacementRevision,
                ),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await repo.clear();
    await repo.save(
      LibraryBook(
        id: 'b',
        title: 'Restored',
        readerPreferences: const {'gap': 4},
      ),
    );
    await tester.tap(find.byType(SwitchListTile).first);
    await tester.pumpAndSettle();
    expect((await repo.find('b'))!.readerPreferences, {'gap': 4});
    expect(find.textContaining('khôi phục'), findsWidgets);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });
  testWidgets('double tap zoom changes image transform and resets', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: ZoomableMangaPage(
            child: SizedBox(
              width: 300,
              height: 300,
              child: ColoredBox(color: Colors.red),
            ),
          ),
        ),
      ),
    );
    InteractiveViewer viewer() =>
        tester.widget<InteractiveViewer>(find.byType(InteractiveViewer));
    await tester.tapAt(const Offset(120, 120));
    await tester.pump(const Duration(milliseconds: 80));
    await tester.tapAt(const Offset(120, 120));
    await tester.pumpAndSettle();
    expect(viewer().transformationController!.value.getMaxScaleOnAxis(), 2);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tapAt(const Offset(120, 120));
    await tester.pump(const Duration(milliseconds: 80));
    await tester.tapAt(const Offset(120, 120));
    await tester.pumpAndSettle();
    expect(viewer().transformationController!.value.getMaxScaleOnAxis(), 1);
  });
  testWidgets('reader skip-read navigates by original chapter ID', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'readerOptionsV1': jsonEncode({'skipRead': true}),
    });
    final p = await SharedPreferences.getInstance();
    final repo = MemoryLibraryRepository();
    await repo.save(
      LibraryBook(
        id: 'b',
        title: 'Skip',
        chapters: const [
          BookChapter(
            id: 'a',
            title: 'A',
            index: 0,
            downloaded: true,
            read: false,
          ),
          BookChapter(
            id: 'b',
            title: 'B',
            index: 1,
            downloaded: true,
            read: true,
          ),
          BookChapter(
            id: 'c',
            title: 'C',
            index: 2,
            downloaded: true,
            read: false,
          ),
        ],
      ),
    );
    for (var i = 0; i < 3; i++) {
      await repo.saveChapter(
        'b',
        i,
        ReaderContent(
          kind: 'novel',
          html: '<p>${'Long paragraph. ' * 400}</p>',
        ),
      );
    }
    final container = ProviderContainer(
      overrides: [
        preferencesProvider.overrideWithValue(p),
        libraryRepositoryProvider.overrideWithValue(repo),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: ReaderScreen(id: 'b')),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Chương tiếp theo'));
    await tester.pumpAndSettle();
    expect(find.text('C'), findsOneWidget);
    expect((await repo.find('b'))!.currentChapter, 2);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });
}
