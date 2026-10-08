import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tachi_books/app.dart';
import 'package:tachi_books/core/widgets/book_cover.dart';
import 'package:tachi_books/features/library/data/library_repository.dart';
import 'package:tachi_books/features/library/presentation/library_view_model.dart';
import 'package:tachi_books/features/settings/presentation/app_settings_screens.dart';
import 'package:tachi_books/features/settings/presentation/more_screen.dart';
import 'package:tachi_books/features/settings/settings_controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('flutter_tts'),
          (_) async => 1,
        );
  });
  testWidgets(
    'empty library adds authored sample and opens a real offline chapter',
    (tester) async {
      final prefs = await SharedPreferences.getInstance();
      final repository = MemoryLibraryRepository();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            preferencesProvider.overrideWithValue(prefs),
            libraryRepositoryProvider.overrideWithValue(repository),
          ],
          child: const TachiBooksApp(),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Tủ sách của bạn'), findsOneWidget);
      expect(find.text('Thư viện'), findsWidgets);
      await tester.tap(find.text('Thử reader với sách mẫu'));
      await tester.pumpAndSettle();
      expect((await repository.list()).length, 1);
      await tester.tap(find.byType(BookCover).first);
      await tester.pumpAndSettle();
      expect(find.text('Bắt đầu đọc'), findsOneWidget);
      await tester.tap(find.text('Bắt đầu đọc'));
      await tester.pumpAndSettle();
      expect(
        find.text('Một nơi dành cho những trang sách', findRichText: true),
        findsOneWidget,
      );
      await tester.tap(find.byTooltip('Chương tiếp theo'));
      await tester.pumpAndSettle();
      expect(
        find.text('Đọc theo nhịp của mình', findRichText: true),
        findsOneWidget,
      );
      final book = await repository.find('example-original-v1');
      expect(book!.currentChapter, 1);
      expect(book.lastRead, isNotNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'navigation preserves library and exposes both source ecosystems',
    (tester) async {
      final prefs = await SharedPreferences.getInstance();
      final repository = MemoryLibraryRepository();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            preferencesProvider.overrideWithValue(prefs),
            libraryRepositoryProvider.overrideWithValue(repository),
          ],
          child: const TachiBooksApp(),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Duyệt').last);
      await tester.pumpAndSettle();
      expect(find.text('Nguồn'), findsOneWidget);
      expect(find.text('Phần mở rộng'), findsOneWidget);
      expect(find.text('Di chuyển'), findsOneWidget);
      expect(find.text('Kết nối Tachimanga'), findsOneWidget);
      expect(find.text('Kết nối vBook'), findsOneWidget);
      expect(find.text('Nguồn trong thiết bị'), findsOneWidget);
      await tester.tap(find.text('Phần mở rộng'));
      await tester.pumpAndSettle();
      expect(find.text('Thêm repository hoặc extension'), findsOneWidget);
      await tester.tap(find.text('Thêm repository hoặc extension'));
      await tester.pumpAndSettle();
      expect(find.text('Tachimanga'), findsWidgets);
      expect(find.text('vBook'), findsWidgets);
      await tester.tap(find.text('Hủy'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Thêm').last);
      await tester.pumpAndSettle();
      expect(find.byType(MoreScreen), findsOneWidget);
      expect(find.text('Chung'), findsOneWidget);
      expect(find.text('Tài khoản'), findsOneWidget);
      await tester.tap(find.text('Chung'));
      await tester.pumpAndSettle();
      expect(find.byType(GeneralSettingsScreen), findsOneWidget);
      expect(find.text('Nhập sách & truyện'), findsOneWidget);
      expect(find.text('Kết nối nguồn'), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.tap(find.text('Thư viện').last);
      await tester.pumpAndSettle();
      expect(find.text('Tủ sách của bạn'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
