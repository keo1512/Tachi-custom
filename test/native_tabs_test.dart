import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tachi_books/app.dart';
import 'package:tachi_books/core/platform/native_tabs.dart';
import 'package:tachi_books/core/widgets/book_cover.dart';
import 'package:tachi_books/features/downloads/presentation/downloads_screen.dart';
import 'package:tachi_books/features/library/data/library_repository.dart';
import 'package:tachi_books/features/library/domain/library_book.dart';
import 'package:tachi_books/features/library/presentation/activity_screens.dart';
import 'package:tachi_books/features/library/presentation/book_detail_screen.dart';
import 'package:tachi_books/features/library/presentation/library_screen.dart';
import 'package:tachi_books/features/library/presentation/library_view_model.dart';
import 'package:tachi_books/features/settings/presentation/app_settings_screens.dart';
import 'package:tachi_books/features/settings/presentation/more_screen.dart';
import 'package:tachi_books/features/settings/settings_controller.dart';
import 'package:tachi_books/features/sources/presentation/browse_screen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late List<MethodCall> outbound;
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(() {
    SharedPreferences.setMockInitialValues({'dark': true});
    outbound = [];
    messenger.setMockMethodCallHandler(NativeTabs.channel, (call) async {
      outbound.add(call);
      return true;
    });
    messenger.setMockMethodCallHandler(
      const MethodChannel('flutter_tts'),
      (_) async => 1,
    );
  });
  tearDown(() {
    NativeTabs.channel.setMethodCallHandler(null);
    messenger.setMockMethodCallHandler(NativeTabs.channel, null);
  });

  test('removing a lower route retains the observer top route for replacement navigation', () {
    final names = <String?>[];
    final observer = NativeTabsRouteObserver(onRouteChanged: names.add);
    Route<void> route(String name) => CupertinoPageRoute<void>(
      settings: RouteSettings(name: name),
      builder: (_) => const SizedBox.shrink(),
    );
    final first = route('library');
    final second = route('downloads');
    final settings = route('settings');
    observer.didPush(first, null);
    observer.didPush(second, first);
    observer.didRemove(first, null);
    expect(names.last, 'downloads');
    observer.didPush(settings, second);
    observer.didPop(settings, second);
    expect(names.last, 'downloads');
    final more = route('more');
    observer.didReplace(newRoute: more, oldRoute: second);
    expect(names.last, 'more');
  });

  testWidgets(
    'six native callbacks open actual routes without a Flutter footer',
    (tester) async {
      await _openApp(tester);
      final configured = outbound
          .where((call) => call.method == 'configure')
          .first;
      expect((configured.arguments as Map)['titles'], mainTabLabels);
      expect(
        (configured.arguments as Map)['badges'],
        List<String?>.filled(6, null),
      );
      expect(_last(outbound)['visible'], true);
      expect(_last(outbound)['index'], 0);
      expect(find.byType(CupertinoTabBar), findsNothing);
      for (final route in <({int index, Type screen})>[
        (index: 1, screen: UpdatesScreen),
        (index: 2, screen: BrowseScreen),
        (index: 3, screen: DownloadsScreen),
        (index: 4, screen: HistoryScreen),
        (index: 5, screen: MoreScreen),
        (index: 0, screen: LibraryScreen),
      ]) {
        await _nativeSelect(tester, route.index);
        expect(find.byType(route.screen), findsOneWidget);
        expect(_last(outbound)['index'], route.index);
        expect(_last(outbound)['visible'], true);
        expect(find.byType(CupertinoTabBar), findsNothing);
        expect(tester.takeException(), isNull);
      }
      final count = outbound.length;
      await _nativeSelect(tester, 6);
      await _nativeSelect(tester, -1);
      expect(find.byType(LibraryScreen), findsOneWidget);
      expect(
        outbound.length,
        count,
        reason:
            'Invalid native indices must not navigate or send a new selection.',
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets(
    'native bar hides for pushed reader-detail and settings pages and restores selected tab on pop',
    (tester) async {
      await _openApp(tester);
      await tester.tap(find.byType(BookCover).first);
      await tester.pumpAndSettle();
      expect(find.byType(BookDetailScreen), findsOneWidget);
      expect(_last(outbound)['visible'], false);
      expect(_last(outbound)['index'], 0);
      await tester.tap(find.byTooltip('Quay lại'));
      await tester.pumpAndSettle();
      expect(find.byType(LibraryScreen), findsOneWidget);
      expect(_last(outbound)['visible'], true);
      expect(_last(outbound)['index'], 0);
      await _nativeSelect(tester, 5);
      await tester.ensureVisible(find.text('Cài đặt'));
      await tester.tap(find.text('Cài đặt'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Chung'));
      await tester.pumpAndSettle();
      expect(find.byType(GeneralSettingsScreen), findsOneWidget);
      expect(_last(outbound)['visible'], false);
      await tester.tap(find.byTooltip('Quay lại'));
      await tester.pumpAndSettle();
      expect(_last(outbound)['visible'], false);
      await tester.tap(find.byTooltip('Quay lại'));
      await tester.pumpAndSettle();
      expect(find.byType(MoreScreen), findsOneWidget);
      expect(_last(outbound)['visible'], true);
      expect(_last(outbound)['index'], 5);
      expect(find.byType(CupertinoTabBar), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets(
    'appearance changes reconfigure native theme and retain selection and visibility',
    (tester) async {
      final prefs = await _openApp(tester);
      await _nativeSelect(tester, 5);
      await tester.ensureVisible(find.text('Cài đặt'));
      await tester.tap(find.text('Cài đặt'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Giao diện'));
      await tester.pumpAndSettle();
      expect(find.byType(AppearanceSettingsScreen), findsOneWidget);
      expect(_last(outbound)['visible'], false);
      final previousConfigurations = outbound
          .where((call) => call.method == 'configure')
          .length;
      await tester.tap(find.text('Sáng'));
      await tester.pumpAndSettle();
      expect(prefs.getBool('dark'), false);
      expect(
        outbound.where((call) => call.method == 'configure').length,
        greaterThan(previousConfigurations),
      );
      final configuration =
          outbound.lastWhere((call) => call.method == 'configure').arguments
              as Map;
      expect(configuration['dark'], false);
      expect(configuration['titles'], mainTabLabels);
      expect(configuration['visible'], false);
      expect(configuration['index'], 5);
      await tester.tap(find.byTooltip('Quay lại'));
      await tester.pumpAndSettle();
      expect(_last(outbound)['visible'], false);
      await tester.tap(find.byTooltip('Quay lại'));
      await tester.pumpAndSettle();
      expect(_last(outbound)['index'], 5);
      expect(_last(outbound)['visible'], true);
      expect(find.byType(CupertinoTabBar), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );
}

Map<dynamic, dynamic> _last(List<MethodCall> calls) =>
    calls.last.arguments as Map;

Future<void> _nativeSelect(WidgetTester tester, int index) async {
  final reply = TestDefaultBinaryMessengerBinding
      .instance
      .defaultBinaryMessenger
      .handlePlatformMessage(
        NativeTabs.channel.name,
        const StandardMethodCodec().encodeMethodCall(
          MethodCall('selectTab', {'index': index}),
        ),
        null,
      );
  await tester.pumpAndSettle();
  await reply;
}

Future<SharedPreferences> _openApp(WidgetTester tester) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(390, 844);
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
  final prefs = await SharedPreferences.getInstance();
  final repository = MemoryLibraryRepository();
  await repository.save(
    LibraryBook(
      id: 'native-navigation-book',
      title: 'Sách điều hướng native',
      chapters: const [
        BookChapter(
          id: 'first',
          title: 'Chương đầu',
          index: 0,
          downloaded: true,
        ),
      ],
    ),
  );
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
  return prefs;
}
