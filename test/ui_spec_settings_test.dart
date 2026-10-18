import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tachi_books/core/theme/app_theme.dart';
import 'package:tachi_books/features/library/application/automatic_backup_controller.dart';
import 'package:tachi_books/features/library/data/automatic_backup_store.dart';
import 'package:tachi_books/features/library/data/backup_service.dart';
import 'package:tachi_books/features/library/data/library_repository.dart';
import 'package:tachi_books/features/library/presentation/library_view_model.dart';
import 'package:tachi_books/features/settings/presentation/automatic_backup_screen.dart';
import 'package:tachi_books/features/settings/presentation/more_screen.dart';
import 'package:tachi_books/features/settings/presentation/settings_home_screen.dart';
import 'package:tachi_books/features/settings/presentation/settings_widgets.dart';
import 'package:tachi_books/features/settings/settings_controller.dart';

class _Backups extends AutomaticBackupStore {
  _Backups()
    : super(Directory('unused'), BackupService(MemoryLibraryRepository()));
  final item = StoredBackup(
    'tachibooks-auto-1792022400000000.json',
    DateTime(2026, 10, 15),
    1048576,
  );
  int deletes = 0;
  bool failRead = false;
  Completer<List<StoredBackup>>? pending;
  @override
  Future<List<StoredBackup>> list() async {
    if (failRead) throw StateError('Chưa đọc được thư mục sao lưu.');
    return pending == null
        ? (deletes == 0 ? [item] : [])
        : await pending!.future;
  }

  @override
  Future<void> delete(String name) async {
    expect(name, item.name);
    deletes++;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    for (final family in [
      'NotoSans',
      'CupertinoSystemText',
      'CupertinoSystemDisplay',
    ]) {
      final font = FontLoader(family)
        ..addFont(rootBundle.load('assets/fonts/notosans.ttf'));
      await font.load();
    }
    final icons = FontLoader('packages/cupertino_icons/CupertinoIcons')
      ..addFont(
        rootBundle.load('packages/cupertino_icons/assets/CupertinoIcons.ttf'),
      );
    await icons.load();
  });
  for (final size in [
    const Size(320, 568),
    const Size(430, 932),
    const Size(1024, 768),
  ]) {
    testWidgets(
      'More tools lead to grouped settings at $size with large text',
      (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        SharedPreferences.setMockInitialValues({});
        final prefs = await SharedPreferences.getInstance();
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              preferencesProvider.overrideWithValue(prefs),
              libraryRepositoryProvider.overrideWithValue(
                MemoryLibraryRepository(),
              ),
            ],
            child: MaterialApp(
              theme: appTheme(Brightness.dark).copyWith(
                textTheme: appTheme(Brightness.dark).textTheme
                    .apply(fontFamily: 'NotoSans'),
              ),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(textScaler: const TextScaler.linear(1.5)),
                child: child!,
              ),
              home: const RepaintBoundary(
                key: ValueKey('settings-capture'),
                child: MoreScreen(),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        if (size.width == 430) {
          final boundary = tester.renderObject<RenderRepaintBoundary>(
            find.byKey(const ValueKey('settings-capture')),
          );
          await tester.runAsync(() async {
            final image = await boundary.toImage(pixelRatio: 1);
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            final output = File('artifacts/ui-spec-more-dark-430.png');
            await output.parent.create(recursive: true);
            await output.writeAsBytes(bytes!.buffer.asUint8List());
            image.dispose();
          });
        }
        expect(find.text('Tài khoản'), findsOneWidget);
        expect(find.byType(PremiumCrown), findsNothing);
        for (final label in [
          'Tải xuống',
          'Thống kê',
          'Quản lý danh mục',
          'Chuyển nguồn',
          'Trạng thái và đánh giá',
          'Đồng bộ',
          'Lưu trữ',
          'Cài đặt',
        ]) {
          await tester.scrollUntilVisible(find.text(label), 180);
          expect(find.text(label), findsOneWidget);
        }
        await tester.tap(find.text('Cài đặt'));
        await tester.pumpAndSettle();
        expect(find.byType(SettingsHomeScreen), findsOneWidget);
        await tester.tap(find.text('Chung'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Thanh tab'));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('tab-order-5')), findsOneWidget);
        expect(find.byKey(const ValueKey('tab-order-3')), findsOneWidget);
        expect(find.byType(ReorderableDragStartListener), findsNWidgets(6));
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('backup list distinguishes loading from an empty folder', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final store = _Backups()..pending = Completer<List<StoredBackup>>();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          preferencesProvider.overrideWithValue(prefs),
          automaticBackupStoreProvider.overrideWith((_) async => store),
        ],
        child: const MaterialApp(home: AutomaticBackupScreen()),
      ),
    );
    await tester.pump();
    expect(find.text('Chưa có bản sao lưu tự động.'), findsNothing);
    store.pending!.complete([]);
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('Chưa có bản sao lưu tự động.'),
      400,
    );
    expect(find.text('Đang đọc danh sách sao lưu…'), findsNothing);
    expect(find.text('Chưa có bản sao lưu tự động.'), findsOneWidget);
  });

  testWidgets('failed backup listing retries without deleting files', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final store = _Backups()..failRead = true;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          preferencesProvider.overrideWithValue(prefs),
          automaticBackupStoreProvider.overrideWith((_) async => store),
        ],
        child: const MaterialApp(home: AutomaticBackupScreen()),
      ),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('Thử lại danh sách sao lưu').hitTestable(),
      200,
    );
    expect(find.text('Chưa có bản sao lưu tự động.'), findsNothing);
    store.failRead = false;
    await tester.tap(find.text('Thử lại danh sách sao lưu'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text(store.item.name), 180);
    expect(find.text(store.item.name), findsOneWidget);
    expect(store.deletes, 0);
    expect(find.text('Thử lại danh sách sao lưu'), findsNothing);
  });

  testWidgets(
    'backup confirmation cannot delete a same-named file after destination changes',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final first = _Backups();
      final second = _Backups();
      var current = first;
      final container = ProviderContainer(
        overrides: [
          preferencesProvider.overrideWithValue(prefs),
          automaticBackupStoreProvider.overrideWith((_) async => current),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: AutomaticBackupScreen()),
        ),
      );
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.text(first.item.name), 400);
      await tester.tap(find.text(first.item.name));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Xóa bản sao lưu này'));
      await tester.pumpAndSettle();
      current = second;
      container.invalidate(automaticBackupStoreProvider);
      await tester.tap(find.text('Xóa'));
      await tester.pumpAndSettle();
      expect(first.deletes, 0);
      expect(second.deletes, 0);
      expect(find.textContaining('Vị trí sao lưu đã thay đổi'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'backup deletion requires an explicit second confirmation and Cancel preserves the file',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final store = _Backups();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            preferencesProvider.overrideWithValue(prefs),
            automaticBackupStoreProvider.overrideWith((_) async => store),
          ],
          child: const MaterialApp(home: AutomaticBackupScreen()),
        ),
      );
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.text(store.item.name), 400);
      await tester.tap(find.text(store.item.name));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Xóa bản sao lưu này'));
      await tester.pumpAndSettle();
      expect(find.text('Xóa bản sao lưu?'), findsOneWidget);
      expect(store.deletes, 0);
      await tester.tap(find.text('Hủy'));
      await tester.pumpAndSettle();
      expect(store.deletes, 0);
      await tester.tap(find.text(store.item.name));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Xóa bản sao lưu này'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Xóa'));
      await tester.pumpAndSettle();
      expect(store.deletes, 1);
      expect(find.text('Chưa có bản sao lưu tự động.'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
