import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tachi_books/core/theme/app_theme.dart';
import 'package:tachi_books/features/library/data/library_recovery_store.dart';
import 'package:tachi_books/features/library/data/library_repository.dart';
import 'package:tachi_books/features/library/data/library_snapshot.dart';
import 'package:tachi_books/features/library/domain/library_book.dart';
import 'package:tachi_books/features/library/presentation/library_view_model.dart';
import 'package:tachi_books/features/privacy/application/app_lock_controller.dart';
import 'package:tachi_books/features/settings/presentation/library_diagnostics_screen.dart';
import 'package:tachi_books/features/settings/presentation/library_recovery_screen.dart';
import 'package:tachi_books/features/settings/settings_controller.dart';

import 'support/unlocked_app_lock.dart';

class _Recovery extends LibraryRecoveryStore {
  _Recovery() : super(Directory.systemTemp);
  int restored = 0;
  @override
  Future<LibraryRecoverySelection> selection({
    bool forRecovery = false,
  }) async => const LibraryRecoverySelection('fixture', 'original');
  @override
  Future<LibraryRecoveryResult> restore({
    required LibrarySnapshot snapshot,
    required String expectedSelectionToken,
    Uint8List? sourceBytes,
    void Function()? guard,
  }) async {
    guard?.call();
    restored++;
    return LibraryRecoveryResult(
      selection: const LibraryRecoverySelection('new', 'new'),
      snapshot: snapshot,
      preservedDirectoryPath: 'kept',
      originalBackupPath: 'input',
      copiedFiles: 3,
      copiedBytes: 10,
    );
  }
}

void main() {
  for (final size in [const Size(320, 568), const Size(430, 932)]) {
    testWidgets(
      'safe repair preview cancel/success with verified outcome at $size',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = size;
        addTearDown(tester.view.reset);
        SharedPreferences.setMockInitialValues({});
        final prefs = await SharedPreferences.getInstance();
        final repo = MemoryLibraryRepository();
        await repo.save(
          LibraryBook(
            id: 'b',
            title: 'B',
            progress: 2,
            chapters: const [
              BookChapter(id: 'c', title: 'C', index: 0, downloaded: true),
            ],
          ),
        );
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              preferencesProvider.overrideWithValue(prefs),
              libraryRepositoryProvider.overrideWithValue(repo),
            ],
            child: MaterialApp(
              theme: appTheme(Brightness.dark),
              home: const LibraryDiagnosticsScreen(),
            ),
          ),
        );
        await tester.tap(find.text('Kiểm tra dữ liệu và nội dung offline'));
        await tester.pumpAndSettle();
        await tester.scrollUntilVisible(
          find.text('Xem trước và sửa dữ liệu an toàn'),
          220,
        );
        await tester.tap(find.text('Xem trước và sửa dữ liệu an toàn'));
        await tester.pumpAndSettle();
        expect(
          find.textContaining('vị trí đọc ngoài phạm vi được đặt lại'),
          findsWidgets,
        );
        await tester.tap(find.widgetWithText(CupertinoDialogAction, 'Hủy'));
        await tester.pumpAndSettle();
        expect((await repo.find('b'))!.progress, 2);
        expect(await repo.recoverySnapshot(), isNull);
        await tester.tap(find.text('Xem trước và sửa dữ liệu an toàn'));
        await tester.pumpAndSettle();
        await tester.tap(
          find.widgetWithText(CupertinoDialogAction, 'Sao lưu và sửa'),
        );
        await tester.pumpAndSettle();
        expect((await repo.find('b'))!.progress, 0);
        expect(await repo.recoverySnapshot(), isNotNull);
        expect(find.textContaining('Đã sửa và xác minh'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
    testWidgets(
      'recovery confirmation, cancel and reopen are explicit at $size',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = size;
        addTearDown(tester.view.reset);
        SharedPreferences.setMockInitialValues({});
        final prefs = await SharedPreferences.getInstance();
        final store = _Recovery();
        final image = LibrarySnapshot([
          LibrarySnapshotEntry(LibraryBook(id: 'b', title: 'B'), {}),
        ]);
        var reopened = 0;
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              preferencesProvider.overrideWithValue(prefs),
              appLockProvider.overrideWith(UnlockedAppLock.new),
            ],
            child: MaterialApp(
              theme: appTheme(Brightness.dark),
              home: LibraryRecoveryScreen(
                store: store,
                retry: () async {
                  reopened++;
                },
                pickBackup: () async => image.encode(),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Chọn bản sao lưu hợp lệ'));
        await tester.pump(const Duration(milliseconds: 350));
        await tester.tap(find.widgetWithText(CupertinoDialogAction, 'Hủy'));
        await tester.pumpAndSettle();
        expect(store.restored, 0);
        await tester.tap(find.text('Chọn bản sao lưu hợp lệ'));
        await tester.pump(const Duration(milliseconds: 350));
        await tester.tap(
          find.widgetWithText(
            CupertinoDialogAction,
            'Giữ dữ liệu gốc và phục hồi',
          ),
        );
        await tester.pumpAndSettle();
        expect(store.restored, 1);
        expect(
          find.textContaining('Đã phục hồi và kiểm tra 1 truyện'),
          findsOneWidget,
        );
        await tester.scrollUntilVisible(find.text('Mở lại ứng dụng'), 170);
        await tester.tap(find.text('Mở lại ứng dụng'));
        await tester.pumpAndSettle();
        expect(reopened, 1);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
