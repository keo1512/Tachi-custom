/// The entire public system continued work payload. Content identities, text from a
/// source, paths and errors deliberately have no place in this contract.
enum ContinuedWorkOperation { downloads, updates, backup }

enum ContinuedWorkState { running, paused, completed, failed }

class ContinuedWorkExpiry {
  const ContinuedWorkExpiry(this.operation, this.sessionId);
  final ContinuedWorkOperation operation;
  final String sessionId;
  static ContinuedWorkExpiry? decode(Object? raw) {
    if (raw is! Map ||
        raw.length != 2 ||
        !raw.containsKey('operation') ||
        !raw.containsKey('sessionId') ||
        raw['operation'] is! String ||
        raw['sessionId'] is! String ||
        !RegExp(r'^[A-Za-z0-9_-]{1,128}$')
            .hasMatch(raw['sessionId'] as String)) {
      return null;
    }
    for (final operation in ContinuedWorkOperation.values) {
      if (operation.name == raw['operation']) {
        return ContinuedWorkExpiry(operation, raw['sessionId'] as String);
      }
    }
    return null;
  }
}

class ContinuedWork {
  ContinuedWork({
    required this.operation,
    required this.state,
    required this.completed,
    required this.total,
    required this.failed,
    required this.sequence,
    required this.sessionId,
  }) {
    if (total < 1 ||
        total > 1000000 ||
        completed < 0 ||
        completed > total ||
        failed < 0 ||
        failed > completed ||
        sequence < 0 ||
        sequence > 1000000 ||
        !RegExp(r'^[A-Za-z0-9_-]{1,128}$').hasMatch(sessionId)) {
      throw ArgumentError('Tiến độ hoạt động không hợp lệ.');
    }
  }

  final ContinuedWorkOperation operation;
  final ContinuedWorkState state;

  /// Chapters for downloads, books for updates, one generic unit for backup.
  /// Failed work is a subset of processed work.
  final int completed, total, failed, sequence;
  final String sessionId;

  Map<String, Object> toMap() => {
    'operation': operation.name,
    'state': state.name,
    'completed': completed,
    'total': total,
    'failed': failed,
    'sequence': sequence,
    'sessionId': sessionId,
  };
}

class ContinuedWorkResult {
  const ContinuedWorkResult({
    this.supported = false,
    this.enabled = false,
    this.visible = false,
    this.deferred = false,
  });
  final bool supported, enabled, visible, deferred;

  factory ContinuedWorkResult.fromMap(Object? raw) {
    if (raw is! Map) return const ContinuedWorkResult();
    return ContinuedWorkResult(
      supported: raw['supported'] == true,
      enabled: raw['enabled'] == true,
      visible: raw['visible'] == true,
      deferred: raw['deferred'] == true,
    );
  }
}
