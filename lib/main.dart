import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app.dart';
import 'features/library/data/library_repository.dart';
import 'features/library/presentation/library_view_model.dart';
import 'features/settings/settings_controller.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    final preferences = await SharedPreferences.getInstance();
    final library = await LibraryRepository.open();
    runApp(
      ProviderScope(
        overrides: [
          preferencesProvider.overrideWithValue(preferences),
          libraryRepositoryProvider.overrideWithValue(library),
        ],
        child: const TachiBooksApp(),
      ),
    );
  } catch (e) {
    runApp(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                'Không mở được bộ nhớ TachiBooks. Dữ liệu hiện có được giữ nguyên.\n$e',
              ),
            ),
          ),
        ),
      ),
    );
  }
}
