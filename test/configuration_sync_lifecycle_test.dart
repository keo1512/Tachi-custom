import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tachi_books/features/library/data/backup_service.dart';
import 'package:tachi_books/features/library/data/coordinated_preferences.dart';
import 'package:tachi_books/features/library/data/library_repository.dart';
import 'package:tachi_books/features/library/domain/library_book.dart';
import 'package:tachi_books/features/library/presentation/library_view_model.dart';
import 'package:tachi_books/features/settings/settings_controller.dart';
import 'package:tachi_books/features/privacy/application/app_lock_controller.dart';
import 'package:tachi_books/features/sync/application/sync_controller.dart';
import 'package:tachi_books/features/sync/application/sync_lifecycle.dart';
import 'package:tachi_books/features/sync/data/google_session.dart';
import 'package:tachi_books/features/sync/data/sync_link_store.dart';
import 'package:tachi_books/features/sync/domain/sync_engine.dart';

import 'support/sync_fakes.dart';

class _ReadySyncLock extends AppLockController {
  @override
  AppLockState build() => const AppLockState(initialized: true);
  @override
  Future<void> initialize() async {}
}

void main() {
  Future<
    ({
      CoordinatedPreferences prefs,
      FakeSyncRemote remote,
      MemoryLibraryRepository repo,
    })
  >
  mount(WidgetTester tester, {bool enabled = true}) async {
    SharedPreferences.setMockInitialValues({
      'dark': true,
      'readingGoalMinutes': 20,
    });
    final repo = MemoryLibraryRepository();
    await repo.save(LibraryBook(id: 'book', title: 'Original', progress: .3));
    final prefs = await CoordinatedPreferences.open(
      await SharedPreferences.getInstance(),
      repo,
    );
    final backup = BackupService(
      repo,
      configuration: AppConfigurationStore(prefs),
    );
    final bytes = await backup.export(), remote = FakeSyncRemote()..seed(bytes);
    await SyncLinkStore(prefs).save(
      SyncLink(
        uid: 'alice',
        headId: remote.current!.id,
        fingerprint: backup.fingerprint(bytes),
        enabled: enabled,
      ),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          libraryRepositoryProvider.overrideWithValue(repo),
          preferencesProvider.overrideWithValue(prefs),
          appLockProvider.overrideWith(_ReadySyncLock.new),
          syncAuthProvider.overrideWithValue(
            FakeSyncAuth()..user = const SyncUser(uid: 'alice'),
          ),
          syncRemoteFactoryProvider.overrideWithValue((_) => remote),
          syncClockProvider.overrideWithValue(() => tester.binding.clock.now()),
        ],
        child: const SyncLifecycle(child: SizedBox()),
      ),
    );
    await tester.pump();
    await tester.pump();
    return (prefs: prefs, remote: remote, repo: repo);
  }

  testWidgets(
    'configuration-only edits debounce and upload full config without book mutation or idle polling',
    (tester) async {
      final fixture = await mount(tester);
      expect(fixture.remote.headReads, 1);
      await tester.pump(const Duration(minutes: 2));
      await fixture.prefs.setInt('readingGoalMinutes', 45);
      await fixture.prefs.setString('appearanceV1', 'light');
      await fixture.prefs.setString(
        'savedSourceFiltersV1',
        jsonEncode({
          'tachimanga:9007199254740993': {
            'Writer': {
              'schema': '1' * 64,
              'filters': [
                {
                  'name': 'Author',
                  'type': 'text',
                  'supported': true,
                  'state': 'Some writer',
                },
              ],
            },
          },
        }),
      );
      await tester.pump(const Duration(seconds: 5));
      expect(fixture.remote.headReads, 1);
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      expect(fixture.remote.headReads, 2);
      expect(fixture.remote.publishes, 1);
      final config =
          jsonDecode(
                utf8.decode(fixture.remote.bytes!),
              )['configuration']['preferences']
              as Map;
      expect(config['readingGoalMinutes'], 45);
      expect(config['appearanceV1'], 'light');
      expect(config['savedSourceFiltersV1'], contains('Some writer'));
      expect((await fixture.repo.find('book'))!.progress, .3);
      await tester.pump(const Duration(minutes: 2));
      expect(fixture.remote.headReads, 2);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'device/private/queue edits never trigger sync and public edits never enable paused link',
    (tester) async {
      final enabled = await mount(tester);
      await tester.pump(const Duration(minutes: 2));
      await enabled.prefs.setString('privacyV1', 'device-only');
      await enabled.prefs.setBool('incognitoMode', true);
      await enabled.prefs.setString('downloadQueueV1', 'pending');
      await tester.pump(const Duration(minutes: 2));
      expect(enabled.remote.headReads, 1);
      expect(enabled.remote.publishes, 0);
      await tester.pumpWidget(const SizedBox());
      final paused = await mount(tester, enabled: false);
      expect(paused.remote.headReads, 0);
      await paused.prefs.setInt('readingGoalMinutes', 60);
      await tester.pump(const Duration(minutes: 2));
      expect(paused.remote.headReads, 0);
      expect(paused.remote.publishes, 0);
      expect(SyncLinkStore(paused.prefs).read()!.enabled, false);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
