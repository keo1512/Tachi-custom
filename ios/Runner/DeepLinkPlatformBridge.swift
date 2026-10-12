import Flutter
import UIKit

/// Retains cold scene URLs until the Dart listener is ready. OAuth URLs are
/// deliberately ignored here and must still be forwarded to Flutter plugins.
@MainActor
final class TachiDeepLinkInbox {
  static let shared = TachiDeepLinkInbox()
  private var pending: [String] = []
  var deliver: ((String) -> Void)?
  @discardableResult
  func accept(_ url: URL) -> Bool {
    guard url.scheme?.lowercased() == "tachibooks", url.absoluteString.utf8.count <= 8192 else { return false }
    let value = url.absoluteString
    if let deliver = deliver { deliver(value) }
    else if pending.count < 16 && !pending.contains(value) { pending.append(value) }
    return true
  }
  func drain() -> [String] {
    let values = pending
    pending.removeAll()
    return values
  }
}

@MainActor
final class DeepLinkPlatformBridge {
  private let channel: FlutterMethodChannel
  private let inbox: TachiDeepLinkInbox
  init(messenger: FlutterBinaryMessenger, inbox: TachiDeepLinkInbox = .shared) {
    self.inbox = inbox
    channel = FlutterMethodChannel(name: "dev.tachibooks/deepLinks", binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      DispatchQueue.main.async {
        guard let self = self, call.method == "ready" else { result(FlutterMethodNotImplemented); return }
        // Returning the pending list and enabling warm callbacks share the main
        // actor, so a URL cannot disappear between these two operations.
        let values = self.inbox.drain()
        self.inbox.deliver = { [weak self] value in self?.channel.invokeMethod("openURL", arguments: value) }
        result(values)
      }
    }
  }
}
