import Flutter
import LocalAuthentication
import UIKit

/// Native overlay appears synchronously before iOS takes App Switcher snapshots.
@MainActor
final class PrivacyScreenShield {
  private let windows: () -> [UIWindow]
  private var covers: [UIView] = []
  var lockEnabled = false
  var secureMode = "incognito"
  var incognito = false

  init(windows: @escaping () -> [UIWindow]) { self.windows = windows }

  var protectsInactive: Bool {
    lockEnabled || secureMode == "always" || (secureMode == "incognito" && incognito)
  }

  func show() {
    guard protectsInactive else { return }
    hide()
    for window in windows() where !window.isHidden {
      let cover = UIView(frame: window.bounds)
      cover.autoresizingMask = [.flexibleWidth, .flexibleHeight]
      cover.backgroundColor = .systemBackground
      cover.accessibilityViewIsModal = true
      cover.accessibilityLabel = "TachiBooks đã khóa"
      cover.isAccessibilityElement = true
      let image = UIImageView(image: UIImage(systemName: "lock.shield.fill"))
      image.translatesAutoresizingMaskIntoConstraints = false
      image.tintColor = .secondaryLabel
      image.contentMode = .scaleAspectFit
      cover.addSubview(image)
      NSLayoutConstraint.activate([
        image.centerXAnchor.constraint(equalTo: cover.centerXAnchor),
        image.centerYAnchor.constraint(equalTo: cover.centerYAnchor),
        image.widthAnchor.constraint(equalToConstant: 64),
        image.heightAnchor.constraint(equalToConstant: 64),
      ])
      window.addSubview(cover)
      covers.append(cover)
    }
  }

  func hide() {
    for cover in covers { cover.removeFromSuperview() }
    covers.removeAll()
  }

  var coveredWindowCount: Int { covers.count }
}

@MainActor
final class PrivacyPlatformBridge {
  private let channel: FlutterMethodChannel
  let shield: PrivacyScreenShield
  private var context: LAContext?
  private var pending: FlutterResult?
  private var observers: [NSObjectProtocol] = []
  private let defaults = UserDefaults.standard

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "dev.tachibooks/privacy", binaryMessenger: messenger)
    shield = PrivacyScreenShield(windows: {
      UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap { $0.windows }
    })
    // Nonsecret policy cache protects snapshots before the first Dart frame.
    shield.lockEnabled = defaults.bool(forKey: "privacy.lockEnabled")
    shield.secureMode = defaults.string(forKey: "privacy.secureMode") ?? "incognito"
    shield.incognito = defaults.bool(forKey: "privacy.incognito")
    channel.setMethodCallHandler { [weak self] call, result in
      MainActor.assumeIsolated { self?.handle(call, result: result) }
    }
    observers.append(NotificationCenter.default.addObserver(
      forName: UIApplication.willResignActiveNotification, object: nil, queue: .main
    ) { [weak self] _ in MainActor.assumeIsolated { self?.shield.show() } })
    observers.append(NotificationCenter.default.addObserver(
      forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
    ) { [weak self] _ in MainActor.assumeIsolated { self?.shield.show() } })
    // The overlay stays until Dart has rendered its locked/resumed frame.
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "capabilities":
      let context = LAContext()
      var error: NSError?
      let available = context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error)
      let biometry: String
      switch context.biometryType {
      case .faceID: biometry = "faceID"
      case .touchID: biometry = "touchID"
      default: biometry = "none"
      }
      result(["available": available, "biometry": biometry])
    case "authenticate": authenticate(result)
    case "cancel":
      cancel()
      result(nil)
    case "configure":
      guard let args = call.arguments as? [String: Any],
            let enabled = args["enabled"] as? Bool,
            let mode = args["secureScreen"] as? String,
            ["off", "always", "incognito"].contains(mode),
            let incognito = args["incognito"] as? Bool else {
        result(FlutterError(code: "invalid", message: "Thiết lập bảo mật không hợp lệ.", details: nil))
        return
      }
      shield.lockEnabled = enabled
      shield.secureMode = mode
      shield.incognito = incognito
      defaults.set(enabled, forKey: "privacy.lockEnabled")
      defaults.set(mode, forKey: "privacy.secureMode")
      defaults.set(incognito, forKey: "privacy.incognito")
      if UIApplication.shared.applicationState != .active { shield.show() }
      result(nil)
    case "foregroundReady":
      if UIApplication.shared.applicationState == .active { shield.hide() }
      result(nil)
    default: result(FlutterMethodNotImplemented)
    }
  }

  private func authenticate(_ result: @escaping FlutterResult) {
    guard pending == nil else {
      result(FlutterError(code: "busy", message: "Đang xác thực.", details: nil))
      return
    }
    let next = LAContext()
    next.localizedCancelTitle = "Hủy"
    next.localizedFallbackTitle = "Dùng mã khóa thiết bị"
    var error: NSError?
    guard next.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
      result(FlutterError(code: "unavailable", message: "Đặt mã khóa trong Cài đặt iPhone/iPad.", details: nil))
      return
    }
    context = next
    pending = result
    next.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Mở khóa thư viện TachiBooks") { [weak self] success, _ in
      DispatchQueue.main.async {
        guard let self, self.context === next else { return }
        let reply = self.pending
        self.pending = nil
        self.context = nil
        reply?(success)
      }
    }
  }

  private func cancel() {
    let reply = pending
    pending = nil
    let previous = context
    context = nil
    previous?.invalidate()
    reply?(false)
  }

  deinit {
    for observer in observers { NotificationCenter.default.removeObserver(observer) }
  }
}
