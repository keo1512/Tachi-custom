import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tachi_books/core/diagnostics/diagnostic_log.dart';
import 'package:tachi_books/core/platform/device_tools.dart';
import 'package:tachi_books/features/library/data/library_repository.dart';
import 'package:tachi_books/features/library/presentation/library_view_model.dart';
import 'package:tachi_books/features/privacy/application/app_lock_controller.dart';
import 'package:tachi_books/features/settings/presentation/log_diagnostics_screen.dart';
import 'package:tachi_books/features/settings/settings_controller.dart';
import 'package:tachi_books/features/sources/data/source_repository.dart';
import 'package:tachi_books/features/sources/domain/catalogue.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final width in [320.0, 430.0]) {
    testWidgets(
      'logs show redacted real errors and sharing/engine/background outcomes at $width',
      (tester) async {
        await tester.binding.setSurfaceSize(Size(width, 932));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        SharedPreferences.setMockInitialValues({});
        final prefs = await SharedPreferences.getInstance();
        final tools = _Tools(), source = _Source();
        final container = ProviderContainer(
          overrides: [
            preferencesProvider.overrideWithValue(prefs),
            libraryRepositoryProvider.overrideWithValue(
              MemoryLibraryRepository(),
            ),
            deviceToolsProvider.overrideWithValue(tools),
            sourceRepositoryProvider.overrideWithValue(source),
            appLockProvider.overrideWith(_UnlockedLock.new),
          ],
        );
        addTearDown(container.dispose);
        addTearDown(source.dispose);
        final store = container.read(diagnosticLogProvider);
        await store.record(
          DiagnosticEvent.error(
            'source',
            StateError(
              'HTTP 503 https://private.example cookie=secret PrivateBook',
            ),
          ),
        );
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: const MaterialApp(home: LogDiagnosticsScreen()),
          ),
        );
        await tester.pumpAndSettle();
        expect(source.calls, 0);
        await tester.tap(find.text('Chia sẻ file nhật ký'));
        await tester.pumpAndSettle();
        expect(tools.shared, isNotNull);
        expect(utf8.decode(tools.shared!), contains('http_503'));
        expect(utf8.decode(tools.shared!), isNot(contains('PrivateBook')));
        final check = find.text('Kiểm tra engine và extension');
        await tester.scrollUntilVisible(check, 200);
        await Scrollable.ensureVisible(tester.element(check), alignment: .4);
        await tester.pumpAndSettle();
        await tester.tap(check);
        await tester.pumpAndSettle();
        expect(source.calls, 4);
        await tester.scrollUntilVisible(
          find.text('tachiyomi.extension.en.komga'),
          120,
        );
        expect(find.text('tachiyomi.extension.en.komga'), findsOneWidget);
        final background = find.text('Kiểm tra trạng thái nền của iOS');
        await tester.scrollUntilVisible(background, -200);
        await Scrollable.ensureVisible(
          tester.element(background),
          alignment: .4,
        );
        await tester.pumpAndSettle();
        await tester.tap(background);
        await tester.pumpAndSettle();
        expect(
          find.textContaining(
            'Đã yêu cầu: có · đang được cấp thời gian: không',
          ),
          findsOneWidget,
        );
        expect(find.textContaining('PrivateBook'), findsNothing);
        expect(find.textContaining('private.example'), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }
  testWidgets('invalid log bytes are kept until explicit clear confirmation', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      DiagnosticLogStore.key: 'invalid-original-bytes',
    });
    final prefs = await SharedPreferences.getInstance();
    final container = ProviderContainer(
      overrides: [
        preferencesProvider.overrideWithValue(prefs),
        libraryRepositoryProvider.overrideWithValue(MemoryLibraryRepository()),
        deviceToolsProvider.overrideWithValue(_Tools()),
        appLockProvider.overrideWith(_UnlockedLock.new),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: LogDiagnosticsScreen()),
      ),
    );
    await tester.pumpAndSettle();
    expect(prefs.getString(DiagnosticLogStore.key), 'invalid-original-bytes');
    await tester.tap(find.text('Xóa nhật ký trên máy'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Hủy'));
    await tester.pumpAndSettle();
    expect(prefs.getString(DiagnosticLogStore.key), 'invalid-original-bytes');
    await tester.tap(find.text('Xóa nhật ký trên máy'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Xóa'));
    await tester.pumpAndSettle();
    expect(prefs.getString(DiagnosticLogStore.key), isNull);
    expect(tester.takeException(), isNull);
  });
}

class _UnlockedLock extends AppLockController {
  @override
  AppLockState build() => const AppLockState(initialized: true);
}

class _Tools implements DeviceTools {
  Uint8List? shared;
  @override
  Future<Map<String, int>> usage() async => {
    'backgroundRequested': 1,
    'backgroundRunning': 0,
  };
  @override
  Future<void> shareLog(Uint8List bytes) async {
    shared = bytes;
  }

  @override
  Future<void> clearCookies() async {}
  @override
  Future<void> clearWebData() async {}
  @override
  Future<void> clearHttpCache() async {}
  @override
  Future<void> resetMutedDomains() async {}
  @override
  Future<void> resetUserAgents() async {}
}

class _Source extends SourceRepository {
  _Source()
    : super(
        tachimangaUrl: 'http://localhost:4567',
        vbookUrl: 'http://localhost:4570',
      );
  int calls = 0;
  @override
  Future<Map<String, dynamic>> health(SourceEngine engine) async {
    calls++;
    return {'status': 'ok', 'private': 'PrivateBook'};
  }

  @override
  Future<List<CatalogueExtension>> extensions(SourceEngine engine) async {
    calls++;
    return [
      if (engine == SourceEngine.tachimanga)
        const CatalogueExtension(
          id: 'tachiyomi.extension.en.komga',
          name: 'Komga',
          version: '1.6.71',
          engine: SourceEngine.tachimanga,
          installed: true,
        ),
    ];
  }
}
