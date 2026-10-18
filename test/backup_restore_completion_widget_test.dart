import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tachi_books/core/theme/app_theme.dart';
import 'package:tachi_books/features/library/application/automatic_backup_controller.dart';
import 'package:tachi_books/features/library/data/automatic_backup_store.dart';
import 'package:tachi_books/features/library/data/backup_directory_platform.dart';
import 'package:tachi_books/features/library/data/backup_service.dart';
import 'package:tachi_books/features/library/data/library_repository.dart';
import 'package:tachi_books/features/library/domain/library_book.dart';
import 'package:tachi_books/features/library/presentation/library_view_model.dart';
import 'package:tachi_books/features/settings/presentation/automatic_backup_screen.dart';
import 'package:tachi_books/features/settings/settings_controller.dart';

class _SavedBackups extends AutomaticBackupStore {
  _SavedBackups(super.directory, super.backup, this.bytes);
  final Uint8List bytes;
  final item = StoredBackup(
    'tachibooks-auto-1792022400000000.json',
    DateTime(2026, 10, 15),
    512,
  );
  @override
  Future<List<StoredBackup>> list() async => [item];
  @override
  Future<Uint8List> read(String name) async => bytes;
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
      'saved backup shows its location and offers library only after restore at $size',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = size;
        addTearDown(tester.view.reset);
        SharedPreferences.setMockInitialValues({});
        final source = MemoryLibraryRepository();
        await source.save(
          LibraryBook(
            id: 'offline',
            title: 'Sách đã nhập',
            chapters: const [
              BookChapter(
                id: 'chapter',
                title: 'Chương 1',
                index: 0,
                downloaded: true,
              ),
            ],
          ),
        );
        await source.saveChapter(
          'offline',
          0,
          ReaderContent(kind: 'novel', html: '<p>Nội dung offline</p>'),
        );
        final target = MemoryLibraryRepository();
        final store = _SavedBackups(
          Directory('unused'),
          BackupService(target),
          await BackupService(source).export(),
        );
        final router = GoRouter(
          initialLocation: '/more',
          routes: [
            GoRoute(
              path: '/',
              builder: (_, _) => const Scaffold(body: Text('Thư viện đích')),
            ),
            GoRoute(
              path: '/more',
              builder: (_, _) => const RepaintBoundary(
                key: ValueKey('backup-completion-capture'),
                child: AutomaticBackupScreen(),
              ),
            ),
          ],
        );
        addTearDown(router.dispose);
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              preferencesProvider.overrideWithValue(
                await SharedPreferences.getInstance(),
              ),
              libraryRepositoryProvider.overrideWithValue(target),
              automaticBackupStoreProvider.overrideWith((_) async => store),
              backupDirectoryLocationProvider.overrideWith((_) async => null),
            ],
            child: MaterialApp.router(
              theme: appTheme(Brightness.light),
              routerConfig: router,
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(textScaler: const TextScaler.linear(1.5)),
                child: child!,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('Về thư viện'), findsNothing);
        await tester.scrollUntilVisible(find.text(store.item.name), 500);
        expect(
          find.textContaining('MB\nTrong dữ liệu ứng dụng'),
          findsOneWidget,
        );
        await Scrollable.ensureVisible(
          tester.element(find.text(store.item.name)),
          alignment: .5,
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text(store.item.name));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Xem trước và khôi phục'));
        await tester.pumpAndSettle();
        await tester.scrollUntilVisible(find.text('Khôi phục 1 sách mới'), 400);
        await Scrollable.ensureVisible(
          tester.element(find.text('Khôi phục 1 sách mới')),
          alignment: .5,
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Khôi phục 1 sách mới'));
        await tester.pumpAndSettle();
        expect((await target.find('offline'))!.title, 'Sách đã nhập');
        expect(
          (await target.readChapter('offline', 0))!.html,
          '<p>Nội dung offline</p>',
        );
        expect(router.routeInformationProvider.value.uri.path, '/more');
        // The completion action stays reachable immediately even when the
        // user restored a file from the bottom of a long backup list.
        final immediateAction = find.descendant(
          of: find.byType(SnackBar),
          matching: find.text('Về thư viện'),
        );
        expect(immediateAction, findsOneWidget);
        if (size.width == 430) {
          final boundary = tester.renderObject<RenderRepaintBoundary>(
            find.byKey(const ValueKey('backup-completion-capture')),
          );
          await tester.runAsync(() async {
            final image = await boundary.toImage();
            final png = await image.toByteData(format: ui.ImageByteFormat.png);
            image.dispose();
            final output = File(
              'artifacts/ui-spec-backup-completion-light-430.png',
            );
            await output.parent.create(recursive: true);
            await output.writeAsBytes(png!.buffer.asUint8List());
          });
        }
        await tester.tap(immediateAction);
        await tester.pumpAndSettle();
        expect(find.text('Thư viện đích'), findsOneWidget);
        expect(router.routeInformationProvider.value.uri.path, '/');
        expect(tester.takeException(), isNull);
      },
    );
  }
}
