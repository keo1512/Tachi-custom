import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tachi_books/app.dart';
import 'package:tachi_books/core/platform/native_tabs.dart';
import 'package:tachi_books/features/library/data/library_repository.dart';
import 'package:tachi_books/features/library/domain/library_book.dart';
import 'package:tachi_books/features/library/presentation/library_screen.dart';
import 'package:tachi_books/features/library/presentation/library_view_model.dart';
import 'package:tachi_books/features/settings/settings_controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  for (final width in [320.0, 430.0]) {
    testWidgets(
      'native tab return preserves category, search and actual library scroll at $width',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = Size(width, 932);
        addTearDown(tester.view.reset);
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        messenger.setMockMethodCallHandler(
          NativeTabs.channel,
          (_) async => true,
        );
        addTearDown(
          () => messenger.setMockMethodCallHandler(NativeTabs.channel, null),
        );
        final repo = MemoryLibraryRepository();
        for (var i = 0; i < 120; i++) {
          await repo.save(
            LibraryBook(
              id: '$i',
              title: 'Sách ${i.toString().padLeft(3, '0')}',
              collection: i.isEven ? 'Manga' : 'Khác',
            ),
          );
        }
        final prefs = await SharedPreferences.getInstance();
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              preferencesProvider.overrideWithValue(prefs),
              libraryRepositoryProvider.overrideWithValue(repo),
            ],
            child: const TachiBooksApp(),
          ),
        );
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text('Manga'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Manga'));
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Tìm trong thư viện'));
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField), 'Sách');
        await tester.pumpAndSettle();
        final grid = find.byType(GridView);
        await tester.drag(grid, const Offset(0, -1100));
        await tester.pumpAndSettle();
        double offset() => tester
            .state<ScrollableState>(
              find
                  .descendant(
                    of: find.byType(GridView),
                    matching: find.byType(Scrollable),
                  )
                  .first,
            )
            .position
            .pixels;
        final before = offset();
        expect(before, greaterThan(100));
        Future<void> tab(int id) async {
          await messenger.handlePlatformMessage(
            NativeTabs.channel.name,
            const StandardMethodCodec().encodeMethodCall(
              MethodCall('selectTab', {'index': id, 'tabId': id}),
            ),
            null,
          );
          await tester.pumpAndSettle();
        }

        await tab(5);
        expect(find.byType(LibraryScreen), findsNothing);
        await tab(0);
        expect(
          (tester.widget<TextField>(find.byType(TextField))).controller!.text,
          'Sách',
        );
        expect(offset(), closeTo(before, 1));
        expect(find.byKey(const ValueKey('library-book-1')), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );
  }
}
