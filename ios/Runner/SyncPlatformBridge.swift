import Flutter
import UIKit
import Network

/// Network-path notifications do not promise successful internet access.
@MainActor
final class SyncPlatformBridge: NSObject, FlutterStreamHandler {
  private let channel: FlutterMethodChannel
  private let events: FlutterEventChannel
  private var monitor: NWPathMonitor?
  private var generation = 0

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "dev.tachibooks/sync", binaryMessenger: messenger)
    events = FlutterEventChannel(name: "dev.tachibooks/connectivity", binaryMessenger: messenger)
    super.init()
    events.setStreamHandler(self)
    channel.setMethodCallHandler { call, result in
      guard call.method == "openGoogleAccount" else {
        result(FlutterMethodNotImplemented); return
      }
      let urls = ["profile": "https://myaccount.google.com/", "password": "https://myaccount.google.com/signinoptions/password", "recovery": "https://accounts.google.com/signin/recovery"]
      let action = call.arguments == nil ? "profile" : call.arguments as? String
      guard let action = action, let address = urls[action] else {
        result(FlutterError(code: "invalid_account_action", message: "Thao tác tài khoản không hợp lệ.", details: nil)); return
      }
      DispatchQueue.main.async {
        UIApplication.shared.open(URL(string: address)!, options: [:]) { opened in
          if opened { result(nil) }
          else { result(FlutterError(code: "account_unavailable", message: "Chưa mở được quản lý tài khoản Google.", details: nil)) }
        }
      }
    }
  }
  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    generation += 1
    let current = generation
    monitor?.cancel()
    let next = NWPathMonitor()
    monitor = next
    next.pathUpdateHandler = { [weak self] path in
      let connected = path.status == .satisfied
      DispatchQueue.main.async {
        guard let self = self, self.generation == current else { return }
        events(connected)
      }
    }
    next.start(queue: DispatchQueue(label: "dev.tachibooks.sync.network"))
    return nil
  }
  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    generation += 1
    monitor?.cancel()
    monitor = nil
    return nil
  }
}
