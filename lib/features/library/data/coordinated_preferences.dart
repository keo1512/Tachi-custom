import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'backup_configuration.dart';
import 'library_repository.dart';
import 'configuration_restore_files.dart';

/// Existing preference APIs remain usable while backup/configuration restores
/// share one mutation queue. App startup must use [open] before exposing it.
class CoordinatedPreferences implements SharedPreferences {
  CoordinatedPreferences._(this._raw);
  final SharedPreferences _raw;
  static final _instances = Expando<CoordinatedPreferences>();
  Future<void> _pending = Future<void>.value();
  final _changes = StreamController<int>.broadcast(sync: true);
  int _generation = 0, _change = 0;
  bool _restoring = false, _recoveryRequired = false;
  ConfigurationRestoreFiles? _files;
  static const journalKey = 'configurationRestoreJournalV1';

  static Future<CoordinatedPreferences> open(
    SharedPreferences raw,
    LibraryRepository repository, {
    String? journalDirectoryPath,
  }) async {
    final preferences = raw is CoordinatedPreferences
        ? raw
        : (_instances[raw] ??= CoordinatedPreferences._(raw));
    if (journalDirectoryPath != null) {
      final files = ConfigurationRestoreFiles(journalDirectoryPath);
      if (preferences._files != null &&
          preferences._files!.directory.path != files.directory.path) {
        throw StateError('Bộ nhớ thiết lập đã mở ở thư mục khác.');
      }
      preferences._files = files;
    }
    await preferences._recover(repository);
    return preferences;
  }

  Stream<int> get changes => _changes.stream;
  int get changeRevision => _change;
  int get mutationGeneration => _generation;

  Future<T> exclusive<T>(Future<T> Function() action) {
    final result = _pending.then((_) => action());
    _pending = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  Future<bool> _write(
    String? key,
    Future<bool> Function() action, {
    bool Function()? isCurrent,
  }) {
    final generation = _generation, restoring = _restoring;
    return exclusive(() async {
      if (_recoveryRequired ||
          restoring ||
          generation != _generation ||
          isCurrent?.call() == false) {
        throw StateError('Thiết lập đã được khôi phục. Hãy mở lại màn hình.');
      }
      _ensureReady();
      final portable = key == null || BackupConfiguration.isPortableKey(key);
      final previous = _files != null && portable
          ? BackupConfiguration.capture(this)
          : null;
      // A failed clear must also restore local authentication/privacy values.
      // This image remains in memory and is never written to the portable file.
      final previousRaw = key == null ? _captureRaw() : null;
      var checkpointAttempted = false;
      Future<void> rollback() async {
        Object? failure;
        if (checkpointAttempted && previous != null) {
          try {
            await _files!.writeCheckpoint(previous);
          } catch (error) {
            failure = error;
          }
        }
        try {
          if (previousRaw != null) {
            await _applyValues(previousRaw, portableOnly: false);
          } else if (previous != null) {
            await _apply(previous);
          }
        } catch (error) {
          failure ??= error;
        }
        if (failure != null) {
          _recoveryRequired = true;
          throw failure;
        }
      }

      bool saved;
      try {
        saved = await action();
        if (!saved) {
          await rollback();
          return false;
        }
        if (previous != null) {
          checkpointAttempted = true;
          await _files!.writeCheckpoint(BackupConfiguration.capture(this));
        }
      } catch (_) {
        // Attempt raw rollback even when the checkpoint path is unavailable.
        try {
          await rollback();
        } catch (_) {
          _recoveryRequired = true;
        }
        rethrow;
      }
      if (saved && (key == null || BackupConfiguration.isPortableKey(key))) {
        _changes.add(++_change);
      }
      return saved;
    });
  }

  void _ensureReady() {
    if (_recoveryRequired || _raw.containsKey(journalKey)) {
      throw StateError('Cần mở lại ứng dụng để hoàn tất khôi phục thiết lập.');
    }
  }

  Future<void> _apply(BackupConfiguration configuration) async {
    await _applyValues(configuration.values);
  }

  Map<String, Object> _captureRaw() => {
    for (final key in _raw.getKeys())
      if (_raw.get(key) case final Object value)
        key: value is List<String> ? List<String>.of(value) : value,
  };

  Future<void> _applyValues(
    Map<String, Object> values, {
    bool portableOnly = true,
  }) async {
    final removed = _raw
        .getKeys()
        .where((key) => !portableOnly || BackupConfiguration.isPortableKey(key))
        .where((key) => !values.containsKey(key))
        .toList();
    for (final key in removed) {
      if (!await _raw.remove(key)) {
        throw StateError('Không thể xóa thiết lập cũ: $key.');
      }
    }
    for (final entry in values.entries) {
      final saved = await switch (entry.value) {
        final bool value => _raw.setBool(entry.key, value),
        final int value => _raw.setInt(entry.key, value),
        final double value => _raw.setDouble(entry.key, value),
        final String value => _raw.setString(entry.key, value),
        final List<String> value => _raw.setStringList(entry.key, value),
        _ => throw const FormatException('Kiểu thiết lập không hợp lệ.'),
      };
      if (!saved) throw StateError('Không thể lưu thiết lập: ${entry.key}.');
    }
  }

  Future<void> _saveJournal(Map<String, dynamic> journal) async {
    if (_files != null) {
      try {
        await _files!.writeJournal(journal);
      } catch (_) {
        _recoveryRequired = true;
        rethrow;
      }
      return;
    }
    if (!await _raw.setString(journalKey, jsonEncode(journal))) {
      _recoveryRequired = true;
      throw StateError('Không thể lưu hồ sơ khôi phục thiết lập.');
    }
  }

  Future<void> _clearJournal() async {
    if (_files != null) {
      try {
        await _files!.clearJournal();
      } catch (_) {
        _recoveryRequired = true;
        rethrow;
      }
    }
    if (_raw.containsKey(journalKey) && !await _raw.remove(journalKey)) {
      _recoveryRequired = true;
      throw StateError(
        'Đã ghi dữ liệu; cần mở lại ứng dụng để xác minh khôi phục.',
      );
    }
    _recoveryRequired = false;
  }

  /// Caller holds [exclusive]. The repository calls beforeCommit only after
  /// validating its own CAS and flushing the full recovery image.
  Future<void> restoreLocked({
    required BackupConfiguration incoming,
    required String expectedFingerprint,
    required String oldLibraryFingerprint,
    required String newLibraryFingerprint,
    required Future<void> Function(Future<void> Function() beforeCommit) commit,
  }) async {
    _ensureReady();
    final previous = BackupConfiguration.capture(this);
    if (previous.fingerprint != expectedFingerprint) {
      throw StateError(
        'Thiết lập đã thay đổi sau khi xem trước. Hãy chọn lại bản sao lưu.',
      );
    }
    final journal = <String, dynamic>{
      'version': 1,
      'phase': 'prepared',
      'oldLibrary': oldLibraryFingerprint,
      'newLibrary': newLibraryFingerprint,
      'before': previous.toJson(),
      'after': incoming.toJson(),
    };
    _restoring = true;
    _generation++;
    var prepared = false, committed = false;
    try {
      await _saveJournal(journal);
      prepared = true;
      await commit(() async {
        // No normal preference edit can run while the repository transaction
        // applies configuration. A failure rolls the book transaction back.
        await _files?.writeCheckpoint(incoming);
        await _apply(incoming);
      });
      committed = true;
      await _saveJournal({...journal, 'phase': 'committed'});
      await _clearJournal();
    } catch (_) {
      if (!committed && prepared) {
        try {
          // Record the rollback decision before changing either image. This is
          // essential for configuration-only restores: the unchanged library
          // fingerprint cannot reveal a failed commit or partial rollback.
          await _saveJournal({...journal, 'phase': 'rollback'});
          await _files?.writeCheckpoint(previous);
          await _apply(previous);
          await _clearJournal();
        } catch (_) {
          _recoveryRequired = true;
          // Keep the journal; startup reconciles the durable rollback decision
          // or, if that write failed, the prior prepared image.
        }
      }
      rethrow;
    } finally {
      _restoring = false;
      _generation++;
      if (committed && !_recoveryRequired) _changes.add(++_change);
    }
  }

  Future<void> _recover(LibraryRepository repository) => exclusive(() async {
    final raw = await _files?.readJournal() ?? _raw.get(journalKey);
    if (raw == null) {
      if (_files != null) {
        final checkpoint = await _files!.readCheckpoint();
        if (checkpoint == null) {
          await _files!.writeCheckpoint(BackupConfiguration.capture(this));
        } else {
          await _apply(checkpoint);
        }
      }
      _recoveryRequired = false;
      return;
    }
    _recoveryRequired = true;
    if (raw is! String ||
        utf8.encode(raw).length > BackupConfiguration.maxBytes * 2 + 4096) {
      throw const FormatException(
        'Hồ sơ khôi phục thiết lập không hợp lệ. Dữ liệu được giữ nguyên.',
      );
    }
    final journal = jsonDecode(raw);
    if (journal is! Map<String, dynamic> ||
        journal['version'] != 1 ||
        !['prepared', 'committed', 'rollback'].contains(journal['phase']) ||
        journal.keys.any(
          (key) => ![
            'version',
            'phase',
            'oldLibrary',
            'newLibrary',
            'before',
            'after',
          ].contains(key),
        )) {
      throw const FormatException(
        'Hồ sơ khôi phục thiết lập không hợp lệ. Dữ liệu được giữ nguyên.',
      );
    }
    for (final key in ['oldLibrary', 'newLibrary']) {
      if (journal[key] is! String ||
          !RegExp(r'^[a-f0-9]{64}$').hasMatch(journal[key] as String)) {
        throw const FormatException(
          'Dấu kiểm thư viện khôi phục không hợp lệ.',
        );
      }
    }
    final before = BackupConfiguration.fromJson(journal['before']),
        after = BackupConfiguration.fromJson(journal['after']);
    // A completed journal is only cleanup: later user edits must be retained.
    if (journal['phase'] == 'committed') {
      if (_files != null) {
        final checkpoint = await _files!.readCheckpoint() ?? after;
        await _files!.writeCheckpoint(checkpoint);
        await _apply(checkpoint);
      }
      await _clearJournal();
      return;
    }
    final fingerprint = (await repository.snapshot()).fingerprint;
    BackupConfiguration? selected;
    if (journal['phase'] == 'rollback') {
      // A rollback may have stopped during preference writes. Never complete
      // the incoming configuration just because its book image was identical.
      if (fingerprint == journal['oldLibrary']) selected = before;
    } else if (journal['oldLibrary'] == journal['newLibrary']) {
      if (fingerprint == journal['oldLibrary']) {
        // The atomic checkpoint is the commit point when only settings change.
        // Without it, an older prepared journal has no durable commit evidence
        // and conservatively restores the previous configuration.
        final checkpoint = await _files?.readCheckpoint();
        if (checkpoint == null ||
            checkpoint.fingerprint == before.fingerprint) {
          selected = before;
        } else if (checkpoint.fingerprint == after.fingerprint) {
          selected = after;
        }
      }
    } else if (fingerprint == journal['newLibrary']) {
      selected = after;
    } else if (fingerprint == journal['oldLibrary']) {
      selected = before;
    }
    if (selected == null) {
      throw StateError(
        'Thư viện không khớp hồ sơ khôi phục. Hồ sơ và dữ liệu hiện có được giữ nguyên.',
      );
    }
    _restoring = true;
    try {
      await _files?.writeCheckpoint(selected);
      await _apply(selected);
      await _clearJournal();
    } finally {
      _restoring = false;
      _generation++;
    }
  });

  @override
  Set<String> getKeys() => _raw.getKeys();
  @override
  Object? get(String key) => _raw.get(key);
  @override
  bool? getBool(String key) => _raw.getBool(key);
  @override
  int? getInt(String key) => _raw.getInt(key);
  @override
  double? getDouble(String key) => _raw.getDouble(key);
  @override
  String? getString(String key) => _raw.getString(key);
  @override
  List<String>? getStringList(String key) => _raw.getStringList(key);
  @override
  bool containsKey(String key) => _raw.containsKey(key);
  @override
  Future<bool> setBool(String key, bool value) =>
      _write(key, () => _raw.setBool(key, value));
  @override
  Future<bool> setInt(String key, int value) =>
      _write(key, () => _raw.setInt(key, value));
  @override
  Future<bool> setDouble(String key, double value) =>
      _write(key, () => _raw.setDouble(key, value));
  @override
  Future<bool> setString(String key, String value) =>
      _write(key, () => _raw.setString(key, value));

  /// A reviewed external action also checks its library/privacy token when its
  /// preference write reaches this queue, not just before the HTTP fetch.
  Future<bool> setStringIfCurrent(
    String key,
    String value,
    bool Function() isCurrent,
  ) => _write(key, () async {
    final previous = _raw.getString(key);
    final saved = await _raw.setString(key, value);
    if (isCurrent()) return saved;
    final rolledBack = previous == null
        ? await _raw.remove(key)
        : await _raw.setString(key, previous);
    if (!rolledBack) {
      _recoveryRequired = true;
      throw StateError(
        'Không hoàn tất được khôi phục thiết lập. Hãy mở lại ứng dụng.',
      );
    }
    throw const FormatException(
      'Thư viện hoặc quyền truy cập đã đổi. Hãy mở lại liên kết.',
    );
  }, isCurrent: isCurrent);
  @override
  Future<bool> setStringList(String key, List<String> value) {
    final copied = List<String>.of(value);
    return _write(key, () => _raw.setStringList(key, copied));
  }

  @override
  Future<bool> remove(String key) => _write(key, () => _raw.remove(key));
  @override
  Future<bool> clear() => _write(null, _raw.clear);
  @override
  Future<bool> commit() async => true;
  @override
  Future<void> reload() => exclusive(_raw.reload);
}

class AppConfigurationStore {
  AppConfigurationStore(this.preferences);
  final CoordinatedPreferences preferences;
  BackupConfiguration capture() {
    preferences._ensureReady();
    return BackupConfiguration.capture(preferences);
  }

  Future<T> exclusive<T>(Future<T> Function() action) =>
      preferences.exclusive(action);
}
