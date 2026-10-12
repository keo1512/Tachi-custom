import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class BackupDirectoryLocation {
  const BackupDirectoryLocation(this.id, this.label);
  final String id, label;

  factory BackupDirectoryLocation.parse(Object? value) {
    if (value is! Map ||
        value['id'] is! String ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(value['id'] as String) ||
        value['label'] is! String ||
        (value['label'] as String).isEmpty ||
        (value['label'] as String).length > 255) {
      throw const FormatException('Thư mục sao lưu không hợp lệ.');
    }
    return BackupDirectoryLocation(
      value['id'] as String,
      value['label'] as String,
    );
  }
}

abstract interface class BackupDirectoryPlatform {
  Future<BackupDirectoryLocation?> current();
  Future<BackupDirectoryLocation?> choose();
  Future<void> forget();
  Future<List<Map<String, dynamic>>> list(String destination);
  Future<Uint8List> read(String destination, String name);
  Future<Map<String, dynamic>> write(
    String destination,
    String name,
    Uint8List bytes,
  );
  Future<void> delete(String destination, String name);
}

final backupDirectoryPlatformProvider = Provider<BackupDirectoryPlatform>(
  (ref) => NativeBackupDirectoryPlatform(),
);
final backupDirectoryLocationProvider =
    FutureProvider<BackupDirectoryLocation?>(
      (ref) => ref.watch(backupDirectoryPlatformProvider).current(),
    );

/// Bookmark bytes remain in native device storage; never in public preferences.
class NativeBackupDirectoryPlatform implements BackupDirectoryPlatform {
  static const channel = MethodChannel('dev.tachibooks/backup-directory');
  bool get supported => !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

  @override
  Future<BackupDirectoryLocation?> current() async {
    if (!supported) return null;
    final value = await channel.invokeMethod<Object?>('current');
    return value == null ? null : BackupDirectoryLocation.parse(value);
  }

  @override
  Future<BackupDirectoryLocation?> choose() async {
    if (!supported) {
      throw UnsupportedError('Chọn thư mục sao lưu cần thiết bị iOS.');
    }
    final value = await channel.invokeMethod<Object?>('choose');
    return value == null ? null : BackupDirectoryLocation.parse(value);
  }

  @override
  Future<void> forget() => channel.invokeMethod<void>('forget');

  Map<String, Object> _arguments(String id, [String? name]) {
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(id) ||
        (name != null &&
            RegExp(r'^tachibooks-auto-\d{16,20}\.json$').stringMatch(name) !=
                name)) {
      throw const FormatException('Vị trí hoặc tên bản sao lưu không hợp lệ.');
    }
    return {'destination': id, 'name': ?name};
  }

  @override
  Future<List<Map<String, dynamic>>> list(String destination) async {
    final result = await channel.invokeListMethod<Object?>(
      'list',
      _arguments(destination),
    );
    if (result == null ||
        result.length > 10000 ||
        result.any((item) => item is! Map)) {
      throw const FormatException('Danh sách sao lưu không hợp lệ.');
    }
    return result
        .map((item) => Map<String, dynamic>.from(item as Map))
        .toList();
  }

  @override
  Future<Uint8List> read(String destination, String name) async {
    final bytes = await channel.invokeMethod<Uint8List>(
      'read',
      _arguments(destination, name),
    );
    if (bytes == null || bytes.isEmpty || bytes.length > 128 * 1024 * 1024) {
      throw const FormatException(
        'Bản sao lưu trống hoặc vượt giới hạn 128 MiB.',
      );
    }
    return bytes;
  }

  @override
  Future<Map<String, dynamic>> write(
    String destination,
    String name,
    Uint8List bytes,
  ) async {
    if (bytes.isEmpty || bytes.length > 128 * 1024 * 1024) {
      throw const FormatException(
        'Bản sao lưu trống hoặc vượt giới hạn 128 MiB.',
      );
    }
    final result = await channel.invokeMapMethod<String, dynamic>('write', {
      ..._arguments(destination, name),
      'bytes': bytes,
    });
    if (result == null) {
      throw const FormatException('Chưa xác nhận bản sao lưu đã được ghi.');
    }
    return result;
  }

  @override
  Future<void> delete(String destination, String name) =>
      channel.invokeMethod<void>('delete', _arguments(destination, name));
}
