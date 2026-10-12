import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tachi_books/features/privacy/application/app_lock_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:tachi_books/features/library/application/backup_activity.dart';
import 'package:tachi_books/features/library/data/backup_compatibility/mihon_backup.dart';
import 'package:tachi_books/features/library/data/library_repository.dart';
import 'package:tachi_books/features/library/domain/library_book.dart';
import 'package:tachi_books/features/library/presentation/library_view_model.dart';
import 'package:tachi_books/features/settings/settings_controller.dart';
import 'package:tachi_books/features/settings/presentation/backup_settings_screen.dart';

class _ReadyExportLock extends AppLockController {
  @override
  AppLockState build() => const AppLockState(initialized: true);
  @override
  Future<void> initialize() async {}
}

void main() {
  for (final size in [const Size(320, 568), const Size(430, 932)]) {
    testWidgets(
      'preview precedes file picker and cancellation preserves library/full backup activity at $size',
      (tester) async {
        var calls = 0;
        final fixture = await _open(
          tester,
          size: size,
          writer: (_, _) async {
            calls++;
            return Uri.parse('file:///export.tachibk');
          },
        );
        final fingerprint = (await fixture.repo.snapshot()).fingerprint;
        await _preview(tester);
        expect(calls, 0);
        expect(find.textContaining('1 truyện · 2 chương'), findsOneWidget);
        expect(find.textContaining('EPUB/TXT/CBZ'), findsOneWidget);
        await _tapScrolled(tester, 'Hủy');
        expect(calls, 0);
        expect((await fixture.repo.snapshot()).fingerprint, fingerprint);
        expect(
          fixture.container.read(backupActivityProvider).exportedAt,
          _previous,
        );
        expect(find.byType(BackupSettingsScreen), findsOneWidget);
        expect(tester.takeException(), isNull);
        await _dispose(tester, fixture);
      },
    );
  }

  for (final result in ['saved', 'cancelled', 'error']) {
    testWidgets(
      'Mihon export $result cannot stamp a full backup or mutate source snapshot',
      (tester) async {
        Uint8List? output;
        String? filename;
        final fixture = await _open(
          tester,
          writer: (name, bytes) async {
            filename = name;
            output = bytes;
            if (result == 'error') throw StateError('Tệp không khả dụng');
            return result == 'saved'
                ? Uri.parse('file:///export.tachibk')
                : null;
          },
        );
        final fingerprint = (await fixture.repo.snapshot()).fingerprint;
        await _preview(tester);
        expect(output, isNull);
        await _tapScrolled(tester, 'Tiếp tục lưu file .tachibk');
        expect(filename, startsWith('tachibooks-mihon-'));
        expect(filename, endsWith('.tachibk'));
        final imported = await tester.runAsync(() => readMihonBackup(output!));
        expect(imported!.snapshot.entries.single.book.title, 'Truyện nguồn');
        expect(imported.snapshot.entries.single.contents, isEmpty);
        expect((await fixture.repo.snapshot()).fingerprint, fingerprint);
        expect(
          fixture.container.read(backupActivityProvider).exportedAt,
          _previous,
        );
        expect(
          fixture.container.read(backupActivityProvider).restoredAt,
          isNull,
        );
        if (result == 'saved') {
          expect(
            find.text('Đã xuất 1 truyện cho Mihon/Tachiyomi'),
            findsOneWidget,
          );
        }
        if (result == 'error') {
          expect(find.textContaining('Tệp không khả dụng'), findsOneWidget);
        }
        await _dispose(tester, fixture);
      },
    );
  }

  testWidgets(
    'library with only local/vBook entries offers warnings without an empty export',
    (tester) async {
      var calls = 0;
      final fixture = await _open(
        tester,
        onlyLocal: true,
        writer: (_, _) async {
          calls++;
          return Uri.parse('file:///unexpected');
        },
      );
      await _preview(tester);
      await tester.drag(find.byType(ListView).last, const Offset(0, -1000));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Không có truyện nguồn Tachi phù hợp'),
        findsOneWidget,
      );
      expect(find.text('Tiếp tục lưu file .tachibk'), findsNothing);
      expect(calls, 0);
      await _dispose(tester, fixture);
    },
  );
}

final _previous = DateTime.utc(2026, 10, 1);
typedef _Fixture = ({
  MemoryLibraryRepository repo,
  ProviderContainer container,
});

Future<_Fixture> _open(
  WidgetTester tester, {
  required MihonBackupFileWriter writer,
  Size size = const Size(430, 932),
  bool onlyLocal = false,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);
  SharedPreferences.setMockInitialValues({
    BackupActivityController.key: BackupActivity(exportedAt: _previous)
        .encode(),
  });
  final prefs = await SharedPreferences.getInstance();
  final repo = MemoryLibraryRepository();
  await repo.save(
    LibraryBook(
      id: 'source',
      title: 'Truyện nguồn',
      engine: onlyLocal ? 'vbook' : 'tachimanga',
      sourceId: '12345',
      sourceRef: '/title',
      chapters: const [
        BookChapter(
          id: '/1',
          title: 'Chương 1',
          index: 0,
          read: true,
          number: 1,
        ),
        BookChapter(
          id: '/2',
          title: 'Chương 2',
          index: 1,
          read: false,
          number: 2,
        ),
      ],
    ),
  );
  await repo.save(LibraryBook(id: 'local', title: 'Sách EPUB'));
  final container = ProviderContainer(
    overrides: [
      preferencesProvider.overrideWithValue(prefs),
      appLockProvider.overrideWith(_ReadyExportLock.new),
      libraryRepositoryProvider.overrideWithValue(repo),
      mihonBackupFileWriterProvider.overrideWithValue(writer),
    ],
  );
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: BackupSettingsScreen()),
    ),
  );
  await tester.pumpAndSettle();
  return (repo: repo, container: container);
}

Future<void> _preview(WidgetTester tester) async {
  await _tapScrolled(tester, 'Xuất cho Mihon / Tachiyomi', settle: false);
  // Isolate work uses the real event loop, not the widget test's fake clock.
  for (
    var i = 0;
    i < 200 && find.byType(MihonExportPreviewScreen).evaluate().isEmpty;
    i++
  ) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(milliseconds: 20));
  }
  await tester.pumpAndSettle();
  expect(find.byType(MihonExportPreviewScreen), findsOneWidget);
}

Future<void> _tapScrolled(
  WidgetTester tester,
  String title, {
  bool settle = true,
}) async {
  await tester.scrollUntilVisible(
    find.text(title),
    200,
    scrollable: find.byType(Scrollable).last,
  );
  await tester.tap(find.text(title));
  if (settle) await tester.pumpAndSettle();
}

Future<void> _dispose(WidgetTester tester, _Fixture fixture) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pumpAndSettle();
  fixture.container.dispose();
  expect(tester.takeException(), isNull);
}
