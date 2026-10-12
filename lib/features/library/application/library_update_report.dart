import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/library_update_result.dart';

final libraryUpdateExecutionProvider = Provider<LibraryUpdateExecutionGate>((
  ref,
) {
  final gate = LibraryUpdateExecutionGate();
  ref.onDispose(gate.dispose);
  return gate;
});

class LibraryUpdateCancelled extends StateError {
  LibraryUpdateCancelled()
    : super(
        'iOS đã dừng lượt cập nhật. Kết quả đã ghi được giữ; mở app để kiểm tra lại phần còn lại.',
      );
}

class LibraryUpdateExecution {
  bool _cancelled = false;
  void check() {
    if (_cancelled) throw LibraryUpdateCancelled();
  }
}

/// Source requests wait for the native background grant. Expiry invalidates
/// existing runs permanently, even if a foreground resume permits a new run.
class LibraryUpdateExecutionGate {
  final _runs = <LibraryUpdateExecution>{};
  final _changes = StreamController<void>.broadcast(sync: true);
  Stream<void> get changes => _changes.stream;
  bool get hasWork => _runs.any((run) => !run._cancelled);
  Completer<void>? _permission;
  bool _allowed = true;
  bool _closed = false;
  void _changed() {
    if (!_closed) _changes.add(null);
  }

  LibraryUpdateExecution begin() {
    final run = LibraryUpdateExecution();
    if (_closed || (!_allowed && _permission == null)) run._cancelled = true;
    _runs.add(run);
    _changed();
    return run;
  }

  void finish(LibraryUpdateExecution run) {
    if (_runs.remove(run)) _changed();
  }

  Future<void> wait(LibraryUpdateExecution run) async {
    run.check();
    final pending = _permission;
    if (pending != null) await pending.future;
    run.check();
    if (!_allowed) throw LibraryUpdateCancelled();
  }

  void hold() {
    _allowed = false;
    _permission ??= Completer<void>();
  }

  void allow() {
    _allowed = true;
    final pending = _permission;
    _permission = null;
    pending?.complete();
  }

  void expire() {
    final wasWorking = hasWork;
    _allowed = false;
    for (final run in _runs) {
      run._cancelled = true;
    }
    final pending = _permission;
    _permission = null;
    pending?.complete();
    if (wasWorking) _changed();
  }

  void dispose() {
    if (_closed) return;
    expire();
    _closed = true;
    unawaited(_changes.close());
  }
}

/// Transient results: source credentials and task failures are not exported.
final libraryUpdateReportProvider =
    NotifierProvider<LibraryUpdateReport, LibraryUpdateResult?>(
      LibraryUpdateReport.new,
    );

class LibraryUpdateReport extends Notifier<LibraryUpdateResult?> {
  @override
  LibraryUpdateResult? build() => null;
  void completed(LibraryUpdateResult value) => state = value;
}

final libraryUpdateProgressProvider =
    NotifierProvider<LibraryUpdateActivity, LibraryUpdateProgress?>(
      LibraryUpdateActivity.new,
    );

class LibraryUpdateActivity extends Notifier<LibraryUpdateProgress?> {
  int _generation = 0;
  @override
  LibraryUpdateProgress? build() => null;
  int begin() => ++_generation;
  void report(int generation, LibraryUpdateProgress value) {
    if (generation == _generation) state = value;
  }

  void finish(int generation) {
    if (generation == _generation) state = null;
  }
}
