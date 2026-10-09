import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../settings/settings_controller.dart';
import '../domain/library_grouping.dart';

final libraryGroupingProvider =
    NotifierProvider<LibraryGroupingController, LibraryGrouping>(
      LibraryGroupingController.new,
    );

class LibraryGroupingController extends Notifier<LibraryGrouping> {
  @override
  LibraryGrouping build() {
    final stored = ref.watch(preferencesProvider).get('libraryGrouping');
    return LibraryGrouping.values
            .where((mode) => mode.name == stored)
            .firstOrNull ??
        LibraryGrouping.collection;
  }

  Future<void> setGrouping(LibraryGrouping grouping) async {
    if (!await ref
        .read(preferencesProvider)
        .setString('libraryGrouping', grouping.name)) {
      throw StateError('Không lưu được cách nhóm thư viện.');
    }
    if (ref.mounted) state = grouping;
  }
}
