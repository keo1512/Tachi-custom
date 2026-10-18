import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tachi_books/core/platform/device_tools.dart';
import 'package:tachi_books/features/sources/application/source_maintenance.dart';
import 'package:tachi_books/features/sources/data/native_tachi_repository.dart';
import 'package:tachi_books/features/sources/domain/catalogue.dart';
import 'package:tachi_books/features/settings/presentation/network_tools_screen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('native maintenance preserves contracts, no caller path reaches engine; source and WebKit logout both invoked', () async {
    final directory = await Directory.systemTemp.createTemp(
      'tachi-maintenance-channel-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final requests = <Map<String, dynamic>>[];
    final runtime = NativeTachiRepository(
      storageDirectory: directory,
      executor: (raw) async {
        final request = jsonDecode(raw) as Map<String, dynamic>;
        requests.add(request);
        return jsonEncode({'ok': true, 'result': true});
      },
    );
    addTearDown(runtime.dispose);
    final device = _Tools();
    final service = SourceMaintenance([runtime], device);
    await service.clearCaches();
    await service.clearWebData();
    await service.resetUserAgents();
    expect(requests.map((r) => r['method']), [
      'initialize',
      'clearSourceCache',
      'clearCookies',
      'resetUserAgents',
    ]);
    expect(requests.skip(1).every((r) => (r['args'] as Map).isEmpty), true);
    expect(device.operations, [
      'clearHttpCache',
      'clearCookies',
      'clearWebData',
      'resetUserAgents',
    ]);
  });
  for (final failure in ['engine', 'browser', 'both']) {
    test(
      'UA reset reports $failure failure and attempts both stores',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'tachi-ua-reset-',
        );
        addTearDown(() => directory.delete(recursive: true));
        var resetCalls = 0;
        final runtime = NativeTachiRepository(
          storageDirectory: directory,
          executor: (raw) async {
            if (jsonDecode(raw)['method'] == 'resetUserAgents') {
              resetCalls++;
              if (failure != 'browser') {
                return jsonEncode({
                  'ok': false,
                  'error': {'code': 'fixture_failure'},
                });
              }
            }
            return jsonEncode({'ok': true, 'result': true});
          },
        );
        addTearDown(runtime.dispose);
        final device = _Tools()..failReset = failure != 'engine';
        await expectLater(
          SourceMaintenance([runtime], device).resetUserAgents(),
          throwsA(
            isA<ApiException>().having(
              (e) => e.message,
              'partial completion message',
              failure == 'both'
                  ? contains('engine và trình duyệt')
                  : failure == 'engine'
                  ? contains('chưa đặt lại User-Agent của engine')
                  : contains('chưa đặt lại User-Agent của trình duyệt'),
            ),
          ),
        );
        expect(resetCalls, 1);
        expect(device.operations, ['resetUserAgents']);
      },
    );
  }
  testWidgets('UA reset UI invokes source and WebKit maintenance', (
    tester,
  ) async {
    final directory = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('tachi-ua-ui-'),
    ))!;
    addTearDown(() => directory.delete(recursive: true));
    var resets = 0;
    final runtime = NativeTachiRepository(
      storageDirectory: directory,
      executor: (raw) async {
        final method = jsonDecode(raw)['method'];
        if (method == 'resetUserAgents') resets++;
        return jsonEncode({
          'ok': true,
          'result': method == 'health' ? {} : true,
        });
      },
    );
    addTearDown(runtime.dispose);
    await tester.runAsync(runtime.health);
    final tools = _Tools();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sourceMaintenanceProvider.overrideWithValue(
            SourceMaintenance([runtime], tools),
          ),
        ],
        child: const MaterialApp(home: NetworkToolsScreen()),
      ),
    );
    await tester.tap(find.text('Khôi phục tất cả User-Agent mặc định'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(CupertinoDialogAction, 'Thực hiện'));
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 80));
    });
    await tester.pumpAndSettle();
    expect(resets, 1);
    expect(tools.operations, ['resetUserAgents']);
    expect(find.text('Đã hoàn tất thao tác trên thiết bị.'), findsOneWidget);
  });
  test('device tools reject oversized exports and malformed usage, invoke exact allowlisted actions', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    const channel = NativeDeviceTools.channel;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final calls = <MethodCall>[];
    var invalid = false;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == 'usage') {
        return invalid
            ? {'libraryBytes': -1}
            : {'libraryBytes': 1024, 'backgroundRunning': 0};
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    final tools = NativeDeviceTools();
    expect((await tools.usage())['libraryBytes'], 1024);
    await tools.clearCookies();
    await tools.clearWebData();
    await tools.resetUserAgents();
    await tools.resetMutedDomains();
    await tools.shareLog(Uint8List.fromList(utf8.encode('{}')));
    expect(calls.map((c) => c.method), [
      'usage',
      'clearCookies',
      'clearWebData',
      'resetUserAgents',
      'resetMutedDomains',
      'shareLog',
    ]);
    expect(
      () => tools.shareLog(Uint8List(128 * 1024 + 1)),
      throwsFormatException,
    );
    invalid = true;
    await expectLater(tools.usage(), throwsFormatException);
  });
}

class _Tools implements DeviceTools {
  final operations = <String>[];
  bool failReset = false;
  @override
  Future<void> clearHttpCache() async => operations.add('clearHttpCache');
  @override
  Future<void> clearCookies() async => operations.add('clearCookies');
  @override
  Future<void> clearWebData() async => operations.add('clearWebData');
  @override
  Future<Map<String, int>> usage() async => {};
  @override
  Future<void> resetMutedDomains() async {}
  @override
  Future<void> resetUserAgents() async {
    operations.add('resetUserAgents');
    if (failReset) throw StateError('fixture reset failure');
  }

  @override
  Future<void> shareLog(Uint8List bytes) async {}
}
