import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tachi_books/features/tasks/data/task_platform.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'native task channel emits expiration and sends numeric summaries only',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      const channel = MethodChannel('dev.tachibooks/tasks');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return [
              'requestNotificationPermission',
              'notify',
              'notifyPausedDownloads',
              'beginBackground',
            ].contains(call.method)
            ? true
            : null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final platform = NativeTaskPlatform();
      var continuedExpired = 0;
      final continuedSubscription = platform.continuedProcessingExpired.listen(
        (_) => continuedExpired++,
      );
      var expired = 0;
      final subscription = platform.backgroundExpired.listen((_) => expired++);
      expect(await platform.beginBackground(), true);
      expect(await platform.notify('downloads', 1, 2), true);
      expect(calls.last.arguments, {
        'kind': 'downloads',
        'completed': 1,
        'failed': 2,
      });
      expect(await platform.notifyPausedDownloads(7, 2), true);
      expect(calls.last.arguments, {'pending': 7, 'failed': 2});
      expect(await platform.notifyPausedDownloads(0, 0), false);
      await expectLater(
        platform.notifyPausedDownloads(-1, 0),
        throwsArgumentError,
      );
      await expectLater(
        platform.notifyPausedDownloads(1000001, 0),
        throwsArgumentError,
      );
      expect(
        calls.any((call) => call.method == 'requestNotificationPermission'),
        false,
      );
      await expectLater(
        platform.notify('secret title', 1, 0),
        throwsArgumentError,
      );
      expect(await platform.requestNotificationPermission(), true);
      final response = Completer<void>();
      messenger.handlePlatformMessage(
        channel.name,
        const StandardMethodCodec().encodeMethodCall(
          const MethodCall('backgroundExpired'),
        ),
        (_) => response.complete(),
      );
      await response.future;
      expect(expired, 1);
      final continuedResponse = Completer<void>();
      messenger.handlePlatformMessage(
        channel.name,
        const StandardMethodCodec().encodeMethodCall(
          const MethodCall('continuedProcessingExpired'),
        ),
        (_) => continuedResponse.complete(),
      );
      await continuedResponse.future;
      expect(continuedExpired, 1);
      expect(expired, 1);
      await platform.downloadPageProgress(7, 62);
      expect(calls.removeLast().arguments, {'completed': 7, 'total': 62});
      await expectLater(
        platform.downloadPageProgress(63, 62),
        throwsArgumentError,
      );
      await platform.clearNotifications();
      await platform.endBackground();
      expect(calls.map((call) => call.method), [
        'beginBackground',
        'notify',
        'notifyPausedDownloads',
        'requestNotificationPermission',
        'clearNotifications',
        'endBackground',
      ]);
      await subscription.cancel();
      await continuedSubscription.cancel();
      platform.dispose();
      await Future<void>.delayed(Duration.zero);
    },
  );
  test('background capability sends only counts and policy; accepts bounded native tokens', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    const channel = MethodChannel('dev.tachibooks/tasks');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    final platform = NativeTaskPlatform();
    final tokens = <int>[];
    final subscription = platform.scheduledBackground.listen(tokens.add);
    await platform.backgroundReady();
    await platform.updateBackgroundSnapshot(
      pending: 4,
      failed: 2,
      notifyOnPause: true,
      resumeRequested: true,
    );
    expect(calls.last.arguments, {
      'pending': 4,
      'failed': 2,
      'notifyOnPause': true,
      'resumeRequested': true,
    });
    await platform.updateBackgroundSnapshot(
      pending: 0,
      failed: 2,
      notifyOnPause: false,
      resumeRequested: true,
    );
    expect((calls.last.arguments as Map)['resumeRequested'], false);
    await platform.updateBackgroundWorkSnapshot(
      pending: 0,
      failed: 0,
      notifyOnPause: false,
      resumeRequested: false,
      updatesRequested: true,
      updateEarliestMillis: 1780000000000,
      updateRemaining: 12,
      updateFailed: 2,
      notifyUpdatePause: true,
    );
    expect(calls.last.arguments, {
      'pending': 0,
      'failed': 0,
      'notifyOnPause': false,
      'resumeRequested': false,
      'updatesRequested': true,
      'updateEarliestMillis': 1780000000000,
      'updateRemaining': 12,
      'updateFailed': 2,
      'notifyUpdatePause': true,
    });
    await platform.updateBackgroundWorkSnapshot(
      pending: 0,
      failed: 0,
      notifyOnPause: false,
      resumeRequested: false,
      updatesRequested: false,
      updateEarliestMillis: 0,
      updateRemaining: 0,
      updateFailed: 0,
      notifyUpdatePause: false,
      backupsRequested: true,
      backupEarliestMillis: 1780000000000,
    );
    expect((calls.last.arguments as Map)['backupsRequested'], true);
    expect(
      (calls.last.arguments as Map)['backupEarliestMillis'],
      1780000000000,
    );
    await expectLater(
      platform.updateBackgroundWorkSnapshot(
        pending: 0,
        failed: 0,
        notifyOnPause: false,
        resumeRequested: false,
        updatesRequested: false,
        updateEarliestMillis: 0,
        updateRemaining: 0,
        updateFailed: 0,
        notifyUpdatePause: false,
        backupsRequested: true,
        backupEarliestMillis: -1,
      ),
      throwsArgumentError,
    );
    await expectLater(
      platform.updateBackgroundWorkSnapshot(
        pending: 0,
        failed: 0,
        notifyOnPause: false,
        resumeRequested: false,
        updatesRequested: true,
        updateEarliestMillis: -1,
        updateRemaining: 12,
        updateFailed: 2,
        notifyUpdatePause: true,
      ),
      throwsArgumentError,
    );
    await expectLater(
      platform.updateBackgroundSnapshot(
        pending: -1,
        failed: 2,
        notifyOnPause: true,
        resumeRequested: true,
      ),
      throwsArgumentError,
    );
    for (final value in [
      7, -1, 'private', 0x80000000,
      {'token': 8, 'resumeDownloads': false},
      {'token': 9, 'resumeDownloads': true},
      {
        'token': 8,
        'resumeDownloads': true,
      }, // A duplicate cannot replace intent.
      {'token': 10, 'resumeDownloads': 'true'},
      {'token': 11, 'resumeDownloads': true, 'extra': 'private'},
    ]) {
      final response = Completer<void>();
      messenger.handlePlatformMessage(
        channel.name,
        const StandardMethodCodec().encodeMethodCall(
          MethodCall('scheduledBackground', value),
        ),
        (_) => response.complete(),
      );
      await response.future;
    }
    expect(tokens, [7, 8, 9]);
    expect(platform.scheduledDownloadsRequested(7), isTrue);
    expect(platform.scheduledDownloadsRequested(8), isFalse);
    expect(platform.scheduledDownloadsRequested(9), isTrue);
    expect(platform.scheduledDownloadsRequested(10), isFalse);
    await platform.completeScheduledBackground(7, success: true);
    expect(calls.last.arguments, {'token': 7, 'success': true});
    expect(platform.scheduledDownloadsRequested(7), isFalse);
    await expectLater(
      platform.completeScheduledBackground(0, success: true),
      throwsArgumentError,
    );
    await subscription.cancel();
    platform.dispose();
    await Future<void>.delayed(Duration.zero);
  });
}
