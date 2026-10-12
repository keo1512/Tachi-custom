import 'dart:convert';

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
import 'package:tachi_books/features/privacy/application/app_lock_controller.dart';
import 'package:tachi_books/features/privacy/domain/privacy_preferences.dart';
import 'package:tachi_books/features/privacy/presentation/privacy_gate.dart';
import 'package:tachi_books/features/settings/presentation/more_screen.dart';
import 'package:tachi_books/features/settings/settings_controller.dart';

import 'privacy_app_lock_test.dart' show FakePrivacyPlatform;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late List<MethodCall> calls;
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    calls = [];
    messenger.setMockMethodCallHandler(NativeTabs.channel, (call) async {
      calls.add(call);
      return true;
    });
  });
  tearDown(() {
    NativeTabs.channel.setMethodCallHandler(null);
    messenger.setMockMethodCallHandler(NativeTabs.channel, null);
  });

  Future<void> select(WidgetTester tester, int index) async {
    await messenger.handlePlatformMessage(
      NativeTabs.channel.name,
      const StandardMethodCodec().encodeMethodCall(
        MethodCall('selectTab', {'index': index}),
      ),
      null,
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'real app privacy wiring blocks native navigation and retains route/library bytes after unlock',
    (tester) async {
      tester.view.physicalSize = const Size(430, 932);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final preferences = await SharedPreferences.getInstance();
      await preferences.setString(
        AppLockController.preferenceKey,
        jsonEncode(const PrivacyPreferences(enabled: true).toJson()),
      );
      final repository = MemoryLibraryRepository();
      final book = LibraryBook(
        id: 'private-library',
        title: 'Authored offline fixture',
        progress: .4,
        bookmarks: ['0:0.4'],
        chapters: const [
          BookChapter(
            id: 'offline',
            title: 'Local chapter',
            index: 0,
            downloaded: true,
          ),
        ],
      );
      await repository.save(book);
      await repository.saveChapter(
        book.id,
        0,
        ReaderContent(
          kind: 'novel',
          html: '<p>Local fixture bytes survive locking.</p>',
        ),
      );
      final before = (await repository.find(book.id))!.toJson();
      final platform = FakePrivacyPlatform();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            preferencesProvider.overrideWithValue(preferences),
            libraryRepositoryProvider.overrideWithValue(repository),
            privacyPlatformProvider.overrideWithValue(platform),
          ],
          child: const TachiBooksApp(),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(LibraryScreen), findsOneWidget);
      expect(find.text('TachiBooks đã khóa'), findsOneWidget);
      expect((calls.last.arguments as Map)['visible'], isFalse);
      await select(tester, 5);
      expect(find.byType(MoreScreen), findsNothing);
      expect((calls.last.arguments as Map)['index'], 0);
      await tester.tap(find.byKey(const ValueKey('privacy-unlock')));
      await tester.pumpAndSettle();
      expect((calls.last.arguments as Map)['visible'], isTrue);
      await select(tester, 5);
      expect(find.byType(MoreScreen), findsOneWidget);
      final container = ProviderScope.containerOf(
        tester.element(find.byType(PrivacyGate)),
      );
      container.read(appLockProvider.notifier).lockNow();
      await tester.pumpAndSettle();
      expect((calls.last.arguments as Map)['visible'], isFalse);
      await select(tester, 0);
      expect(find.byType(MoreScreen), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('privacy-unlock')));
      await tester.pumpAndSettle();
      expect((calls.last.arguments as Map)['visible'], isTrue);
      expect((calls.last.arguments as Map)['index'], 5);
      expect((await repository.find(book.id))!.toJson(), before);
      expect(
        (await repository.readChapter(book.id, 0))!.html,
        '<p>Local fixture bytes survive locking.</p>',
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );
}
