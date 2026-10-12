import 'package:shared_preferences/shared_preferences.dart';

/// Serializes local library display and category changes on one preference store.
class LibraryPreferenceWrites {
  static final _pending = Expando<Future<void>>();

  static Future<T> serialize<T>(
    SharedPreferences preferences,
    Future<T> Function() action,
  ) {
    final result = (_pending[preferences] ?? Future<void>.value()).then(
      (_) => action(),
    );
    _pending[preferences] = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }
}
