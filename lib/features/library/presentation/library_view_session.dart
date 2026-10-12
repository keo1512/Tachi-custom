import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// View-only session state never becomes reading progress or library metadata.
class LibraryViewSession {
  String query = '';
  bool searching = false;
  String? selectedGroup;
  int? revision;
  void reset(int nextRevision) {
    query = '';
    searching = false;
    selectedGroup = null;
    revision = nextRevision;
  }
}

final libraryViewSessionProvider = Provider((_) => LibraryViewSession());
final mainPageStorageProvider = Provider((_) => PageStorageBucket());
