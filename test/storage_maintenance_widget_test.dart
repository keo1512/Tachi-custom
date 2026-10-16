import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tachi_books/core/platform/device_tools.dart';
import 'package:tachi_books/features/library/data/library_repository.dart';
import 'package:tachi_books/features/library/domain/library_book.dart';
import 'package:tachi_books/features/library/presentation/library_view_model.dart';
import 'package:tachi_books/features/privacy/application/app_lock_controller.dart';
import 'package:tachi_books/features/settings/presentation/storage_maintenance_screen.dart';
import 'package:tachi_books/features/settings/settings_controller.dart';

void main() {
  for (final width in [320.0, 430.0]) {
    testWidgets(
      'storage display and confirmed transient cache clear fit ${width.toInt()}px',
      (tester) async {
        tester.view.physicalSize = Size(width, 932);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        SharedPreferences.setMockInitialValues({});
        final prefs = await SharedPreferences.getInstance();
        final repository = MemoryLibraryRepository();
        await repository.save(
          LibraryBook(
            id: 'one',
            title: 'One',
            engine: 'tachimanga',
            sourceId: '1',
            sourceRef: '/book',
            chapters: const [BookChapter(id: '0', title: '1', index: 0)],
          ),
        );
        await repository.saveChapter(
          'one',
          0,
          ReaderContent(
            kind: 'novel',
            html: '<p>Temp</p><img src="https://example.org/a.png">',
          ),
        );
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              preferencesProvider.overrideWithValue(prefs),
              libraryRepositoryProvider.overrideWithValue(repository),
              deviceToolsProvider.overrideWithValue(_FakeDevice()),
              appLockProvider.overrideWith(_Unlocked.new),
            ],
            child: MaterialApp(
              theme: ThemeData(platform: TargetPlatform.iOS),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(textScaler: TextScaler.linear(1.5)),
                child: child!,
              ),
              home: const StorageMaintenanceScreen(),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('Bộ nhớ và cache'), findsOneWidget);
        expect(find.text('2,0 MiB'), findsWidgets);
        await _scrollTo(tester, find.text('Xóa cache chương'));
        await tester.tap(find.text('Xóa cache chương'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Hủy'));
        await tester.pumpAndSettle();
        expect(await repository.readChapter('one', 0), isNotNull);
        await tester.tap(find.text('Xóa cache chương'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Tiếp tục'));
        await tester.pumpAndSettle();
        expect(await repository.readChapter('one', 0), isNull);
        expect(await repository.recoverySnapshot(), isNotNull);
        await tester.pump(const Duration(seconds: 5));
        await tester.pumpAndSettle();
        await _scrollTo(tester, find.text('Quản lý truyện cục bộ'));
        await tester.tap(find.text('Quản lý truyện cục bộ'));
        await tester.pumpAndSettle();
        expect(find.text('Truyện trong thiết bị'), findsOneWidget);
        expect(find.text('Nhập truyện từ Files'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }
}

Future<void> _scrollTo(WidgetTester tester, Finder target) async {
  for (var index = 0; index < 25; index++) {
    if (target.evaluate().isNotEmpty && tester.getCenter(target).dy < 820) {
      return;
    }
    await tester.drag(find.byType(ListView).first, const Offset(0, -280));
    await tester.pumpAndSettle();
  }
  throw StateError('Missing cache control');
}

class _Unlocked extends AppLockController {
  @override
  AppLockState build() => const AppLockState(initialized: true);
  @override
  Future<void> initialize() async {}
}

class _FakeDevice implements DeviceTools {
  @override
  Future<Map<String, int>> usage() async => const {
    'documentsBytes': 2097152,
    'backupBytes': 2097152,
    'libraryBytes': 2097152,
  };
  @override
  Future<void> clearCookies() async {}
  @override
  Future<void> clearHttpCache() async {}
  @override
  Future<void> clearWebData() async {}
  @override
  Future<void> resetMutedDomains() async {}
  @override
  Future<void> resetUserAgents() async {}
  @override
  Future<void> shareLog(Uint8List bytes) async {}
}
