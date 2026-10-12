import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'catalogue.dart';

/// Original installed packages and explicitly public preferences. Never includes
/// runtime directories, converted classes, cookies or script localStorage.
class ExtensionBackup {
  ExtensionBackup(Iterable<ExtensionBackupPackage> packages)
    : packages = List.unmodifiable(packages) {
    final ids = <String>{};
    if (this.packages.length > 512 ||
        this.packages.any((package) => !ids.add(package.identity))) {
      throw const FormatException(
        'Danh sách extension sao lưu bị trùng hoặc quá lớn.',
      );
    }
  }

  final List<ExtensionBackupPackage> packages;
  factory ExtensionBackup.fromJson(Object? value) {
    final root = _object(value);
    if (root.keys.any((key) => !{'version', 'packages'}.contains(key)) ||
        root['version'] is! int ||
        root['version'] != 1 ||
        root['packages'] is! List ||
        (root['packages'] as List).length > 512) {
      throw const FormatException('Định dạng sao lưu extension không hợp lệ.');
    }
    return ExtensionBackup(
      (root['packages'] as List).map(ExtensionBackupPackage.fromJson),
    );
  }

  Map<String, dynamic> toJson() {
    final ordered = packages.toList()
      ..sort((a, b) => a.identity.compareTo(b.identity));
    return {
      'version': 1,
      'packages': ordered.map((package) => package.toJson()).toList(),
    };
  }

  String get fingerprint =>
      sha256.convert(utf8.encode(jsonEncode(toJson()))).toString();
}

class ExtensionBackupPackage {
  ExtensionBackupPackage._({
    required this.engine,
    required this.id,
    required this.name,
    required this.version,
    required this.digest,
    required Uint8List bytes,
    required this.origin,
    required this.sourceIds,
    required this.preferences,
  }) : _bytes = Uint8List.fromList(bytes);

  final SourceEngine engine;
  final String id, name, version, digest, origin;
  final Uint8List _bytes;
  Uint8List get bytes => Uint8List.fromList(_bytes);
  final List<String> sourceIds;
  final Map<String, Map<String, PublicSourcePreference>> preferences;
  String get identity => '${engine.name}:$id';

  factory ExtensionBackupPackage.create({
    required SourceEngine engine,
    required String id,
    required String name,
    String version = '',
    required Uint8List bytes,
    String origin = '',
    List<String> sourceIds = const [],
    Map<String, Map<String, PublicSourcePreference>> preferences = const {},
  }) => ExtensionBackupPackage.fromJson({
    'engine': engine.name,
    'id': id,
    'name': name,
    'version': version,
    'sha256': sha256.convert(bytes).toString(),
    'data': base64Encode(bytes),
    'origin': publicPackageUrl(origin),
    'sourceIds': sourceIds,
    'preferences': {
      for (final source in preferences.entries)
        source.key: {
          for (final entry in source.value.entries)
            entry.key: entry.value.toJson(),
        },
    },
  });

  factory ExtensionBackupPackage.fromJson(Object? value) {
    final root = _object(value);
    if (root.keys.any(
      (key) => !{
        'engine',
        'id',
        'name',
        'version',
        'sha256',
        'data',
        'origin',
        'sourceIds',
        'preferences',
      }.contains(key),
    )) {
      throw const FormatException('Gói extension có trường không được hỗ trợ.');
    }
    final engine = switch (root['engine']) {
      'tachimanga' => SourceEngine.tachimanga,
      'vbook' => SourceEngine.vbook,
      _ => throw const FormatException('Engine extension không hợp lệ.'),
    };
    final id = _string(root, 'id', 250),
        name = _string(root, 'name', 512),
        version = _string(root, 'version', 100),
        digest = _string(root, 'sha256', 64),
        origin = _string(root, 'origin', 4096);
    if (id.isEmpty ||
        name.trim().isEmpty ||
        !(engine == SourceEngine.tachimanga
            ? RegExp(r'^eu\.kanade\.tachiyomi\.extension\.[A-Za-z0-9_.]+$')
                  .hasMatch(id)
            : RegExp(r'^vb-[a-f0-9]{24}$').hasMatch(id)) ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(digest) ||
        (origin.isNotEmpty && publicPackageUrl(origin) != origin)) {
      throw const FormatException(
        'Danh tính hoặc URL extension sao lưu không hợp lệ.',
      );
    }
    final raw = root['data'],
        limit = engine == SourceEngine.tachimanga
            ? 32 * 1024 * 1024
            : 64 * 1024 * 1024;
    if (raw is! String || raw.length > (limit + 2) ~/ 3 * 4) {
      throw const FormatException('Gói extension sao lưu vượt giới hạn.');
    }
    final bytes = base64Decode(raw);
    if (bytes.length < 4 ||
        bytes.length > limit ||
        bytes[0] != 0x50 ||
        bytes[1] != 0x4b ||
        bytes[2] != 3 ||
        bytes[3] != 4 ||
        sha256.convert(bytes).toString() != digest) {
      throw const FormatException(
        'Nội dung extension không khớp mã kiểm tra hoặc không phải ZIP/APK.',
      );
    }
    final rawIds = root['sourceIds'];
    if (rawIds is! List ||
        rawIds.length > 2048 ||
        rawIds.any((id) => id is! String) ||
        rawIds.toSet().length != rawIds.length) {
      throw const FormatException('Danh sách ID nguồn không hợp lệ.');
    }
    final sourceIds = rawIds.cast<String>();
    for (final sourceId in sourceIds) {
      final signed = BigInt.tryParse(sourceId);
      if (engine == SourceEngine.tachimanga
          ? signed == null ||
                signed.toSigned(64) != signed ||
                signed.toString() != sourceId
          : sourceId != id) {
        throw const FormatException('ID nguồn phải giữ danh tính String gốc.');
      }
    }
    final prefs = _object(root['preferences']);
    final preferences = <String, Map<String, PublicSourcePreference>>{};
    if (utf8.encode(jsonEncode(prefs)).length > 2 * 1024 * 1024) {
      throw const FormatException(
        'Tùy chọn nguồn sao lưu vượt giới hạn 2 MiB.',
      );
    }
    for (final source in prefs.entries) {
      if (!sourceIds.contains(source.key)) {
        throw const FormatException(
          'Tùy chọn tham chiếu nguồn không thuộc gói.',
        );
      }
      final values = _object(source.value);
      if (values.length > 512) {
        throw const FormatException('Quá nhiều tùy chọn nguồn.');
      }
      preferences[source.key] = Map.unmodifiable({
        for (final entry in values.entries)
          entry.key: PublicSourcePreference.fromJson(entry.key, entry.value),
      });
    }
    return ExtensionBackupPackage._(
      engine: engine,
      id: id,
      name: name,
      version: version,
      digest: digest,
      bytes: bytes,
      origin: origin,
      sourceIds: List.unmodifiable(sourceIds),
      preferences: Map.unmodifiable(preferences),
    );
  }

  Map<String, dynamic> toJson() => {
    'engine': engine.name,
    'id': id,
    'name': name,
    'version': version,
    'sha256': digest,
    'data': base64Encode(_bytes),
    'origin': origin,
    'sourceIds': sourceIds.toList()..sort(),
    'preferences': {
      for (final id in preferences.keys.toList()..sort())
        id: {
          for (final key in preferences[id]!.keys.toList()..sort())
            key: preferences[id]![key]!.toJson(),
        },
    },
  };
}

/// String inputs are deliberately excluded. List values must match declared
/// options again at restore time, not just this untrusted backup declaration.
class PublicSourcePreference {
  PublicSourcePreference._(this.type, this.value);
  final String type;
  final Object value;
  static bool safeKey(String key) =>
      key.isNotEmpty &&
      key.length <= 512 &&
      !RegExp(r'[\x00-\x1f]').hasMatch(key) &&
      !RegExp(
        r'password|passwd|secret|token|cookie|credential|login|username|email|api.?key|auth|session',
        caseSensitive: false,
      ).hasMatch(key);
  factory PublicSourcePreference.fromJson(String key, Object? input) {
    final root = _object(input), type = root['type'], value = root['value'];
    if (!safeKey(key) ||
        root.keys.any((key) => !{'type', 'value'}.contains(key))) {
      throw const FormatException(
        'Tùy chọn nguồn bí mật hoặc không hợp lệ bị từ chối.',
      );
    }
    if (type == 'boolean' && value is bool) {
      return PublicSourcePreference._('boolean', value);
    }
    if (type == 'list' && value is String && value.length <= 2048) {
      return PublicSourcePreference._('list', value);
    }
    if (type == 'set' &&
        value is List &&
        value.length <= 512 &&
        value.every((item) => item is String && item.length <= 2048) &&
        value.toSet().length == value.length) {
      return PublicSourcePreference._(
        'set',
        List<String>.unmodifiable(value.cast<String>().toList()..sort()),
      );
    }
    throw const FormatException(
      'Chỉ sao lưu lựa chọn nguồn công khai đã được xác minh.',
    );
  }
  Map<String, dynamic> toJson() => {'type': type, 'value': value};

  static PublicSourcePreference? fromScreen(Map<String, dynamic> item) {
    final props = item['props'] is Map
        ? Map<String, dynamic>.from(item['props'] as Map)
        : item;
    final key = props['key'];
    if (key is! String ||
        !safeKey(key) ||
        props['visible'] == false ||
        props['enabled'] == false) {
      return null;
    }
    final type = item['type'], value = props['currentValue'] ?? item['value'];
    final values = props['entryValues'];
    if (type == 'SwitchPreferenceCompat' || type == 'CheckBoxPreference') {
      return value is bool ? PublicSourcePreference._('boolean', value) : null;
    }
    if (type == 'ListPreference' &&
        value is String &&
        values is List &&
        values.contains(value)) {
      return PublicSourcePreference._('list', value);
    }
    if (type == 'MultiSelectListPreference' &&
        value is List &&
        values is List &&
        value.every((entry) => entry is String && values.contains(entry))) {
      return PublicSourcePreference.fromJson(key, {
        'type': 'set',
        'value': value,
      });
    }
    return null;
  }

  bool matchesScreen(Map<String, dynamic> item) {
    final props = item['props'] is Map
        ? Map<String, dynamic>.from(item['props'] as Map)
        : item;
    final values = props['entryValues'];
    return props['enabled'] != false &&
        props['visible'] != false &&
        switch (type) {
          'boolean' => [
            'SwitchPreferenceCompat',
            'CheckBoxPreference',
          ].contains(item['type']),
          'list' =>
            item['type'] == 'ListPreference' &&
                values is List &&
                values.contains(value),
          'set' =>
            item['type'] == 'MultiSelectListPreference' &&
                values is List &&
                (value as List).every(values.contains),
          _ => false,
        };
  }
}

String publicPackageUrl(String value) {
  final uri = Uri.tryParse(value);
  return uri != null &&
          ['http', 'https'].contains(uri.scheme) &&
          uri.host.isNotEmpty &&
          uri.userInfo.isEmpty &&
          !uri.hasQuery &&
          !uri.hasFragment
      ? uri.toString()
      : '';
}

Map<String, dynamic> _object(Object? value) {
  if (value is! Map || value.keys.any((key) => key is! String)) {
    throw const FormatException('Sao lưu extension phải là JSON object.');
  }
  return Map<String, dynamic>.from(value);
}

String _string(Map<String, dynamic> value, String key, int maximum) {
  final result = value[key];
  if (result is! String ||
      result.length > maximum ||
      RegExp(r'[\x00-\x1f]').hasMatch(result)) {
    throw FormatException('Trường $key của extension không hợp lệ.');
  }
  return result;
}
