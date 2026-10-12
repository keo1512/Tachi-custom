import 'package:tachi_books/features/privacy/application/app_lock_controller.dart';

/// Isolated layout/scheduling tests have no native authentication bridge.
/// Privacy behavior itself is exercised by the dedicated app-lock tests.
class UnlockedAppLock extends AppLockController {
  @override
  AppLockState build() => const AppLockState(initialized: true);
  @override
  Future<void> initialize() async {}
}
