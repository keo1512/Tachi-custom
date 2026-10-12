import 'dart:convert';

/// Null enables every language, including ones added by future repositories.
/// An empty set deliberately hides every language without uninstalling sources.
class SourceLanguages {
  const SourceLanguages(this.enabled);
  final Set<String>? enabled;
  bool allows(String language) => enabled?.contains(language) ?? true;

  factory SourceLanguages.decode(String? raw) {
    if (raw == null) return const SourceLanguages(null);
    final value = jsonDecode(raw);
    if (value is! Map ||
        value['version'] != 1 ||
        value.keys.any((key) => !['version', 'enabled'].contains(key))) {
      throw const FormatException('Thiết lập ngôn ngữ nguồn không hợp lệ.');
    }
    final enabled = value['enabled'];
    if (enabled == null) return const SourceLanguages(null);
    if (enabled is! List ||
        enabled.length > 200 ||
        enabled.any(
          (code) =>
              code is! String ||
              !RegExp(r'^[a-zA-Z0-9_-]{1,32}$').hasMatch(code),
        ) ||
        enabled.toSet().length != enabled.length) {
      throw const FormatException('Danh sách ngôn ngữ nguồn không hợp lệ.');
    }
    return SourceLanguages(Set<String>.unmodifiable(enabled.cast<String>()));
  }

  String encode() => jsonEncode({
    'version': 1,
    'enabled': enabled == null ? null : (enabled!.toList()..sort()),
  });
}
