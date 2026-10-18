import 'dart:io';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path_provider/path_provider.dart';

import 'app.dart';
import 'core/format/error_messages.dart';
import 'core/platform/application_recovery.dart';
import 'core/platform/native_tabs.dart';
import 'core/theme/app_theme.dart';
import 'features/library/data/coordinated_preferences.dart';
import 'features/library/data/library_recovery_store.dart';
import 'features/library/data/library_repository.dart';
import 'features/library/presentation/library_view_model.dart';
import 'features/settings/settings_controller.dart';
import 'features/privacy/presentation/privacy_gate.dart';
import 'features/privacy/application/app_lock_controller.dart';
import 'features/settings/presentation/library_recovery_screen.dart';
import 'features/tasks/application/task_lifecycle.dart';
import 'features/tasks/data/task_platform.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await _ApplicationBootstrap().start();
}

class _ApplicationBootstrap {
  _ApplicationBootstrap() {
    if (Platform.isIOS) {
      _channel.setMethodCallHandler((call) async {
        if (call.method == 'foreground') _activateUI();
        return null;
      });
    }
  }
  static const _channel = MethodChannel('dev.tachibooks/application');
  LibraryRepository? library;
  SharedPreferences? rawPreferences;
  ProviderContainer? container;
  ProviderSubscription<TaskCoordinator>? taskSubscription;
  bool uiAttached = false, uiRequested = false;
  bool working = false;

  Future<void> _detach() async {
    // Dispose lifecycle/controller owners before closing storage. close() also
    // drains writes already queued by the old repository owners.
    if (uiAttached) {
      runApp(
        MaterialApp(
          theme: appTheme(Brightness.dark),
          home: const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          ),
        ),
      );
      await WidgetsBinding.instance.endOfFrame;
    }
    if (uiAttached && defaultTargetPlatform == TargetPlatform.iOS) {
      try {
        await NativeTabs.channel.invokeMethod<bool>('setVisible', {
          'visible': false,
        });
      } catch (_) {
        // The recovery screen itself has no navigation owner or tab handler.
      }
    }
    uiAttached = false;
    taskSubscription?.close();
    taskSubscription = null;
    container?.dispose();
    container = null;
    final previous = library;
    library = null;
    await previous?.close();
  }

  Future<void> start() async {
    if (working) return;
    working = true;
    try {
      await _detach();
      final background =
          Platform.isIOS &&
          await _channel.invokeMethod<bool>('isBackground') == true;
      uiRequested = uiRequested || !background;
      rawPreferences ??= await SharedPreferences.getInstance();
      library = await LibraryRepository.open();
      // Structural and attachment errors go to recovery. Finite metadata that
      // needs normalization can still be inspected/repaired inside the app.
      await library!.snapshot();
      final support = await getApplicationSupportDirectory();
      final preferences = await CoordinatedPreferences.open(
        rawPreferences!,
        library!,
        journalDirectoryPath: '${support.path}/configuration-recovery',
      );
      container = ProviderContainer(
        overrides: [
          preferencesProvider.overrideWithValue(preferences),
          libraryRepositoryProvider.overrideWithValue(library!),
          applicationRecoveryProvider.overrideWithValue(recover),
          applicationStartsInBackgroundProvider.overrideWithValue(background),
        ],
      );
      await container!.read(appLockProvider.notifier).initialize();
      taskSubscription = retainApplicationTasks(container!);
      if (uiRequested) _activateUI();
    } catch (error) {
      await _detach();
      await _showRecovery(userFacingError(error));
    } finally {
      working = false;
    }
  }

  void _activateUI() {
    uiRequested = true;
    final owner = container;
    if (owner == null) {
      if (!working) unawaited(start());
      return;
    }
    owner
        .read(taskCoordinatorProvider)
        .didChangeAppLifecycleState(AppLifecycleState.resumed);
    if (uiAttached) return;
    uiAttached = true;
    runApp(
      UncontrolledProviderScope(container: owner, child: const TachiBooksApp()),
    );
  }

  Future<void> recover() async {
    if (working) return;
    working = true;
    try {
      await _detach();
      await _showRecovery(null);
    } finally {
      working = false;
    }
  }

  Future<void> _showRecovery(String? error) async {
    if (!uiRequested) return;
    uiAttached = true;
    final preferences = rawPreferences;
    // If privacy preferences cannot be read, do not expose backup contents.
    if (preferences == null) {
      runApp(
        MaterialApp(
          theme: appTheme(Brightness.dark),
          home: Scaffold(
            body: Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text(
                      'Chưa đọc được thiết lập bảo mật. Dữ liệu hiện có được giữ nguyên.',
                    ),
                    if (error != null) Text(error),
                    FilledButton(
                      onPressed: start,
                      child: const Text('Thử mở lại'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      return;
    }
    final directory = await getApplicationDocumentsDirectory();
    runApp(
      ProviderScope(
        overrides: [preferencesProvider.overrideWithValue(preferences)],
        child: MaterialApp(
          theme: appTheme(Brightness.dark),
          home: PrivacyGate(
            child: LibraryRecoveryScreen(
              store: LibraryRecoveryStore(Directory(directory.path)),
              startupError: error,
              retry: start,
            ),
          ),
        ),
      ),
    );
  }
}
