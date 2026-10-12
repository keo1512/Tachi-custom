enum SecureScreenMode { off, always, incognito }

/// Device-local policy. Authentication secrets never enter preferences or backups.
class PrivacyPreferences {
  const PrivacyPreferences({
    this.enabled = false,
    this.delaySeconds = 0,
    this.idleSeconds = 0,
    this.secureScreen = SecureScreenMode.incognito,
  });

  final bool enabled;
  final int delaySeconds, idleSeconds;
  final SecureScreenMode secureScreen;

  PrivacyPreferences copyWith({
    bool? enabled,
    int? delaySeconds,
    int? idleSeconds,
    SecureScreenMode? secureScreen,
  }) => PrivacyPreferences(
    enabled: enabled ?? this.enabled,
    delaySeconds: delaySeconds ?? this.delaySeconds,
    idleSeconds: idleSeconds ?? this.idleSeconds,
    secureScreen: secureScreen ?? this.secureScreen,
  );

  Map<String, dynamic> toJson() => {
    'enabled': enabled,
    'delaySeconds': delaySeconds,
    if (idleSeconds != 0) 'idleSeconds': idleSeconds,
    'secureScreen': secureScreen.name,
  };

  factory PrivacyPreferences.fromJson(Map<String, dynamic> json) {
    final enabled = json['enabled'] ?? false;
    final delay = json['delaySeconds'] ?? 0;
    final idle = json['idleSeconds'] ?? 0;
    final screen = json['secureScreen'] ?? SecureScreenMode.incognito.name;
    if (enabled is! bool ||
        delay is! int ||
        ![0, 30, 60, 300].contains(delay) ||
        idle is! int ||
        ![0, 60, 300, 900].contains(idle) ||
        !SecureScreenMode.values.any((mode) => mode.name == screen)) {
      throw const FormatException('Thiết lập bảo mật không hợp lệ.');
    }
    return PrivacyPreferences(
      enabled: enabled,
      delaySeconds: delay,
      idleSeconds: idle,
      secureScreen: SecureScreenMode.values.firstWhere(
        (mode) => mode.name == screen,
      ),
    );
  }
}

class PrivacyCapabilities {
  const PrivacyCapabilities({required this.available, this.biometry = 'none'});
  final bool available;
  final String biometry;
  String get label => switch (biometry) {
    'faceID' => 'Face ID hoặc mã khóa thiết bị',
    'touchID' => 'Touch ID hoặc mã khóa thiết bị',
    _ => 'Mã khóa thiết bị',
  };
}
