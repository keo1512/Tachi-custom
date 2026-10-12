import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tachi_books/features/settings/settings_controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('private source navigation preserves recents; normal visits serialize without losing entries', () async {
    SharedPreferences.setMockInitialValues({
      'recentSources': ['old'],
      'incognitoMode': true,
    });
    final preferences = await SharedPreferences.getInstance();
    final container = ProviderContainer(
      overrides: [preferencesProvider.overrideWithValue(preferences)],
    );
    addTearDown(container.dispose);
    await container.read(settingsProvider.notifier).recordSourceUse('private');
    expect(preferences.getStringList('recentSources'), ['old']);
    await container
        .read(settingsProvider.notifier)
        .update(incognitoMode: false);
    final controller = container.read(settingsProvider.notifier);
    await Future.wait([
      controller.recordSourceUse('first'),
      controller.recordSourceUse('second'),
    ]);
    expect(preferences.getStringList('recentSources'), [
      'second',
      'first',
      'old',
    ]);
    final stale = controller.recordSourceUse('queued-before-private');
    final private = controller.update(incognitoMode: true);
    await Future.wait([stale, private]);
    expect(preferences.getStringList('recentSources'), [
      'second',
      'first',
      'old',
    ]);
    await controller.recordSourceUse('private-again');
    expect(preferences.getStringList('recentSources'), [
      'second',
      'first',
      'old',
    ]);
  });
}
