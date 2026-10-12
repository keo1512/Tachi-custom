import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tachi_books/core/platform/device_tools.dart';
import 'package:tachi_books/features/sources/application/source_maintenance.dart';
import 'package:tachi_books/features/sources/data/native_tachi_repository.dart';

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
    expect(requests.map((r) => r['method']), [
      'initialize',
      'clearSourceCache',
      'clearCookies',
    ]);
    expect(requests.skip(1).every((r) => (r['args'] as Map).isEmpty), true);
    expect(device.operations, [
      'clearHttpCache',
      'clearCookies',
      'clearWebData',
    ]);
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
  Future<void> resetUserAgents() async {}
  @override
  Future<void> shareLog(Uint8List bytes) async {}
}
