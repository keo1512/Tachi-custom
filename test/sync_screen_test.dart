import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tachi_books/features/settings/settings_controller.dart';
import 'package:tachi_books/features/privacy/application/app_lock_controller.dart';
import 'package:tachi_books/features/library/data/library_repository.dart';
import 'package:tachi_books/features/library/presentation/library_view_model.dart';
import 'package:tachi_books/features/sync/application/sync_controller.dart';
import 'package:tachi_books/features/sync/domain/sync_engine.dart';
import 'package:tachi_books/features/sync/presentation/sync_screen.dart';

import 'support/sync_fakes.dart';
import 'support/unlocked_app_lock.dart';

void main() {
  for (final size in [const Size(320, 568), const Size(430, 932)]) {
    testWidgets('backup is reachable inside Sync without login at $size', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final auth = FakeSyncAuth();
      final local = FakeSyncLocal();
      final remote = FakeSyncRemote();
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            preferencesProvider.overrideWithValue(preferences),
            appLockProvider.overrideWith(UnlockedAppLock.new),
            libraryRepositoryProvider.overrideWithValue(
              MemoryLibraryRepository(),
            ),
            syncAuthProvider.overrideWithValue(auth),
            syncLocalProvider.overrideWithValue(local),
            syncRemoteFactoryProvider.overrideWithValue((_) => remote),
          ],
          child: const MaterialApp(home: SyncScreen()),
        ),
      );
      expect(
        find.text('Đăng nhập Google trước khi bật đồng bộ.'),
        findsOneWidget,
      );
      expect(find.text('Sao lưu & Khôi phục'), findsOneWidget);
      await tester.tap(find.text('Sao lưu & Khôi phục'));
      await tester.pumpAndSettle();
      expect(find.text('Tạo bản sao lưu'), findsOneWidget);
      await tester.scrollUntilVisible(find.text('Khôi phục bản sao lưu'), 150);
      expect(find.text('Khôi phục bản sao lưu'), findsOneWidget);
      expect(auth.signIns, 0);
      expect(remote.headReads, 0);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'Google config error keeps the account signed out and offline access available',
    (tester) async {
      final auth = FakeSyncAuth()
        ..error = const SyncFailure('Cấu hình Google chưa hợp lệ.');
      final remote = FakeSyncRemote();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            syncAuthProvider.overrideWithValue(auth),
            syncLocalProvider.overrideWithValue(FakeSyncLocal()),
            syncRemoteFactoryProvider.overrideWithValue((_) => remote),
          ],
          child: const MaterialApp(home: AccountScreen()),
        ),
      );
      await tester.tap(find.text('Đăng nhập bằng Google'));
      await tester.pumpAndSettle();
      expect(find.text('Cấu hình Google chưa hợp lệ.'), findsOneWidget);
      expect(find.text('Đăng nhập bằng Google'), findsOneWidget);
      expect(find.text('Alice'), findsNothing);
      expect(find.textContaining('đọc và sao lưu file'), findsOneWidget);
      expect(remote.publishes, 0);
      expect(tester.takeException(), isNull);
    },
  );
}
