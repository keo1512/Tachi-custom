import Flutter
import UIKit
import WebKit

@MainActor
final class DeviceToolsBridge {
  private let channel: FlutterMethodChannel
  private let worker = DispatchQueue(label: "dev.tachibooks.device-tools")
  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "dev.tachibooks/device-tools", binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      DispatchQueue.main.async {
        guard let self = self else {
          result(FlutterError(code: "device_tools_closed", message: "Công cụ thiết bị đã đóng.", details: nil)); return
        }
        self.handle(call, result: result)
      }
    }
  }
  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "usage":
      let background = TaskBackgroundScheduler.shared.diagnosticState
      worker.async {
        do {
          let manager = FileManager.default
          let documents = try manager.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
          let support = try manager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
          let docs = try Self.measure(documents)
          let app = try Self.measure(support)
          let temp = try Self.measure(manager.temporaryDirectory)
          var value = ["documentsBytes": docs.total, "supportBytes": app.total,
            "temporaryBytes": temp.total, "backupBytes": docs.backups + app.backups,
            "libraryBytes": docs.library, "httpCacheBytes": URLCache.shared.currentDiskUsage]
          value.merge(background) { _, new in new }
          DispatchQueue.main.async { result(value) }
        } catch { DispatchQueue.main.async { result(Self.failure("Không đọc được dung lượng dữ liệu trên máy.")) } }
      }
    case "clearHttpCache": URLCache.shared.removeAllCachedResponses(); result(nil)
    case "resetMutedDomains": UserDefaults.standard.removeObject(forKey: "dev.tachibooks.browserMutedDomains"); result(nil)
    case "resetUserAgents": UserDefaults.standard.removeObject(forKey: "dev.tachibooks.browserUserAgents"); result(nil)
    case "clearCookies":
      for cookie in HTTPCookieStorage.shared.cookies ?? [] { HTTPCookieStorage.shared.deleteCookie(cookie) }
      let store = WKWebsiteDataStore.default().httpCookieStore
      store.getAllCookies { cookies in
        let group = DispatchGroup()
        for cookie in cookies { group.enter(); store.delete(cookie) { group.leave() } }
        group.notify(queue: .main) { result(nil) }
      }
    case "clearWebData":
      let store = WKWebsiteDataStore.default()
      store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) { result(nil) }
    case "shareLog":
      guard let input = call.arguments as? FlutterStandardTypedData,
        !input.data.isEmpty, input.data.count <= 128 * 1024 else { result(Self.failure("Nhật ký không hợp lệ.")); return }
      guard let scene = UIApplication.shared.connectedScenes.first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene,
        var presenter = scene.windows.first(where: { $0.isKeyWindow })?.rootViewController else { result(Self.failure("Mở ứng dụng để chia sẻ nhật ký.")); return }
      while let next = presenter.presentedViewController { presenter = next }
      let file = FileManager.default.temporaryDirectory.appendingPathComponent("TachiBooks-log-\(UUID().uuidString).json")
      do { try input.data.write(to: file, options: .withoutOverwriting) }
      catch { result(Self.failure("Không tạo được file nhật ký để chia sẻ.")); return }
      let sheet = UIActivityViewController(activityItems: [file], applicationActivities: nil)
      sheet.popoverPresentationController?.sourceView = presenter.view
      sheet.popoverPresentationController?.sourceRect = CGRect(x: presenter.view.bounds.midX, y: presenter.view.bounds.midY, width: 1, height: 1)
      sheet.completionWithItemsHandler = { _, _, _, error in
        try? FileManager.default.removeItem(at: file)
        result(error == nil ? nil : Self.failure("Chia sẻ nhật ký chưa hoàn tất."))
      }
      presenter.present(sheet, animated: true)
    default: result(FlutterMethodNotImplemented)
    }
  }
  static func failure(_ message: String) -> FlutterError { FlutterError(code: "device_tools", message: message, details: nil) }
  nonisolated static func measure(_ root: URL) throws -> (total: Int, backups: Int, library: Int) {
    let manager = FileManager.default
    guard manager.fileExists(atPath: root.path) else { return (0, 0, 0) }
    let rootInfo = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
    guard rootInfo.isDirectory == true, rootInfo.isSymbolicLink != true else { return (0, 0, 0) }
    var enumerationError: Error?
    guard let iterator = manager.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey], options: [], errorHandler: { _, error in
      enumerationError = error; return false
    }) else { throw NSError(domain: "DeviceTools", code: 2) }
    var total = 0, backups = 0, library = 0, count = 0
    for case let url as URL in iterator {
      count += 1
      guard count <= 200000 else { throw NSError(domain: "DeviceTools", code: 1) }
      let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
      if values.isSymbolicLink == true { iterator.skipDescendants(); continue }
      guard values.isRegularFile == true, let size = values.fileSize, size >= 0 else { continue }
      guard size <= Int.max - total else { throw NSError(domain: "DeviceTools", code: 3) }
      total += size
      let name = url.lastPathComponent
      if name.hasPrefix("tachibooks-auto-") || name.hasPrefix("recovery-") || name == "original-backup.bin" { backups += size }
      if url.path.contains("/attachments/") || name == "tachi_books.isar" { library += size }
    }
    if let error = enumerationError { throw error }
    return (total, backups, library)
  }
}
