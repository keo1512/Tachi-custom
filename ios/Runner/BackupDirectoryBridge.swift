import CryptoKit
import Flutter
import UniformTypeIdentifiers
import UIKit

/// The selected Files folder is device-local. A bookmark is never exported.
final class BackupDirectoryFiles {
  static let bookmarkKey = "dev.tachibooks.backupFolderBookmark"
  static let labelKey = "dev.tachibooks.backupFolderLabel"
  static let maximumBytes = 128 * 1024 * 1024
  private let defaults: UserDefaults
  init(defaults: UserDefaults = .standard) { self.defaults = defaults }
  static func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
  static func validName(_ name: String) -> Bool {
    name.range(of: "^tachibooks-auto-[0-9]{16,20}\\.json\\z", options: .regularExpression) != nil
  }
  func current() -> [String: String]? {
    guard let bookmark = defaults.data(forKey: Self.bookmarkKey),
      let label = defaults.string(forKey: Self.labelKey) else { return nil }
    return ["id": Self.digest(bookmark), "label": label]
  }
  func forget() {
    defaults.removeObject(forKey: Self.bookmarkKey)
    defaults.removeObject(forKey: Self.labelKey)
  }
  func select(_ url: URL) throws -> [String: String] {
    let scoped = url.startAccessingSecurityScopedResource()
    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
    guard url.isFileURL, try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
      throw failure("Chọn một thư mục trong Tệp.")
    }
    let bookmark = try url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
    let label = String(url.lastPathComponent.prefix(255))
    guard !label.isEmpty else { throw failure("Không xác định được tên thư mục.") }
    defaults.set(bookmark, forKey: Self.bookmarkKey)
    defaults.set(label, forKey: Self.labelKey)
    return ["id": Self.digest(bookmark), "label": label]
  }
  private func failure(_ message: String) -> NSError {
    NSError(domain: "TachiBooksBackupDirectory", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
  }
  func access<T>(_ destination: String, write: Bool, action: (URL) throws -> T) throws -> T {
    guard let bookmark = defaults.data(forKey: Self.bookmarkKey), Self.digest(bookmark) == destination else {
      throw failure("Thư mục sao lưu đã thay đổi. Hãy mở lại danh sách rồi thử lại.")
    }
    var stale = false
    let root = try URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
    guard !stale, root.isFileURL else {
      throw failure("Quyền truy cập thư mục đã hết hạn. Chọn lại thư mục trong Tệp.")
    }
    let scoped = root.startAccessingSecurityScopedResource()
    defer { if scoped { root.stopAccessingSecurityScopedResource() } }
    var coordinationError: NSError?
    var outcome: Result<T, Error>?
    let body: (URL) -> Void = { coordinatedRoot in
      outcome = Result {
        let directory = coordinatedRoot.appendingPathComponent("TachiBooks-Backups", isDirectory: true)
        if FileManager.default.fileExists(atPath: directory.path) {
          let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
          guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw self.failure("Vị trí sao lưu không phải thư mục dữ liệu hợp lệ.")
          }
        } else if write {
          try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        }
        return try action(directory)
      }
    }
    if write {
      NSFileCoordinator().coordinate(writingItemAt: root, options: .forMerging, error: &coordinationError, byAccessor: body)
    } else {
      NSFileCoordinator().coordinate(readingItemAt: root, options: [], error: &coordinationError, byAccessor: body)
    }
    if let error = coordinationError { throw error }
    guard let value = outcome else { throw failure("Nhà cung cấp Tệp chưa cho phép truy cập.") }
    return try value.get()
  }
  func list(_ directory: URL) throws -> [[String: Any]] {
    if !FileManager.default.fileExists(atPath: directory.path) { return [] }
    let files = try FileManager.default.contentsOfDirectory(at: directory,
      includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey], options: [.skipsHiddenFiles])
    guard files.count <= 10000 else { throw failure("Thư mục sao lưu có quá nhiều tệp.") }
    return try files.filter { Self.validName($0.lastPathComponent) }.compactMap { file in
      let info = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
      guard info.isRegularFile == true, info.isSymbolicLink != true else { return nil }
      return ["name": file.lastPathComponent, "size": info.fileSize ?? 0]
    }
  }
  func read(_ directory: URL, name: String) throws -> Data {
    guard Self.validName(name) else { throw failure("Tên bản sao lưu không hợp lệ.") }
    let file = directory.appendingPathComponent(name)
    let info = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
    guard info.isRegularFile == true, info.isSymbolicLink != true,
      let size = info.fileSize, size > 0, size <= Self.maximumBytes else {
      throw failure("Bản sao lưu trống, không hợp lệ hoặc vượt giới hạn 128 MiB.")
    }
    let data = try Data(contentsOf: file)
    guard data.count == size else { throw failure("Tệp sao lưu đã thay đổi khi đang đọc.") }
    return data
  }
  func write(_ directory: URL, name: String, data: Data) throws -> [String: Any] {
    guard Self.validName(name), !data.isEmpty, data.count <= Self.maximumBytes,
      let raw = name.split(separator: "-").last?.split(separator: ".").first,
      var stamp = UInt64(raw) else { throw failure("Nội dung sao lưu không hợp lệ.") }
    var file = directory.appendingPathComponent(name)
    while FileManager.default.fileExists(atPath: file.path) {
      guard stamp < UInt64.max else { throw failure("Không tạo được tên bản sao lưu mới.") }
      stamp += 1
      file = directory.appendingPathComponent("tachibooks-auto-\(stamp).json")
    }
    let pending = directory.appendingPathComponent(".tachibooks-\(UUID().uuidString).pending")
    defer { try? FileManager.default.removeItem(at: pending) }
    try data.write(to: pending, options: [.withoutOverwriting])
    let handle = try FileHandle(forWritingTo: pending)
    try handle.synchronize()
    try handle.close()
    let stored = try Data(contentsOf: pending)
    guard stored.count == data.count, Self.digest(stored) == Self.digest(data) else {
      throw failure("Không xác minh được dữ liệu sao lưu đã ghi.")
    }
    // moveItem refuses to overwrite; failed publication never prunes older files.
    try FileManager.default.moveItem(at: pending, to: file)
    return ["name": file.lastPathComponent, "size": stored.count]
  }
  func delete(_ directory: URL, name: String) throws {
    _ = try read(directory, name: name)
    try FileManager.default.removeItem(at: directory.appendingPathComponent(name))
  }
}

@MainActor
final class BackupDirectoryBridge: NSObject, UIDocumentPickerDelegate {
  private let channel: FlutterMethodChannel
  private let files = BackupDirectoryFiles()
  private let worker = DispatchQueue(label: "dev.tachibooks.backup-directory")
  private var pickerResult: FlutterResult?
  private var picker: UIDocumentPickerViewController?
  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "dev.tachibooks/backup-directory", binaryMessenger: messenger)
    super.init()
    channel.setMethodCallHandler { [weak self] call, result in
      DispatchQueue.main.async {
        guard let self = self else {
          result(FlutterError(code: "backup_folder_closed", message: "Bộ chọn thư mục đã đóng.", details: nil)); return
        }
        self.handle(call, result: result)
      }
    }
  }
  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    if call.method == "choose" {
      guard pickerResult == nil else {
        result(FlutterError(code: "folder_busy", message: "Đang chọn thư mục sao lưu.", details: nil)); return
      }
      guard let scene = UIApplication.shared.connectedScenes.first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene,
        var presenter = scene.windows.first(where: { $0.isKeyWindow })?.rootViewController else {
        result(FlutterError(code: "folder_no_window", message: "Mở ứng dụng để chọn thư mục.", details: nil)); return
      }
      while let next = presenter.presentedViewController { presenter = next }
      let next = UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)
      next.delegate = self
      next.allowsMultipleSelection = false
      pickerResult = result
      picker = next
      presenter.present(next, animated: true)
      return
    }
    let store = files
    worker.async {
      let outcome: Result<Any?, Error> = Result {
        if call.method == "current" { return store.current() }
        if call.method == "forget" { store.forget(); return nil }
        guard let args = call.arguments as? [String: Any], let id = args["destination"] as? String,
          Set(args.keys).isSubset(of: ["destination", "name", "bytes"]) else {
          throw NSError(domain: "BackupDirectory", code: 1)
        }
        return try store.access(id, write: ["write", "delete"].contains(call.method)) { (directory: URL) -> Any? in
          switch call.method {
          case "list": return try store.list(directory)
          case "read", "write", "delete":
            guard let name = args["name"] as? String else { throw NSError(domain: "BackupDirectory", code: 1) }
            if call.method == "read" { return FlutterStandardTypedData(bytes: try store.read(directory, name: name)) }
            if call.method == "delete" { try store.delete(directory, name: name); return nil }
            guard let bytes = args["bytes"] as? FlutterStandardTypedData else { throw NSError(domain: "BackupDirectory", code: 1) }
            return try store.write(directory, name: name, data: bytes.data)
          default: return FlutterMethodNotImplemented
          }
        }
      }
      DispatchQueue.main.async {
        switch outcome {
        case .success(let value): result(value)
        case .failure(let error):
          let message = (error as NSError).domain == "TachiBooksBackupDirectory"
            ? error.localizedDescription : "Không truy cập được thư mục sao lưu. Kiểm tra quyền, kết nối nhà cung cấp Tệp và dung lượng trống; chọn lại thư mục nếu cần."
          result(FlutterError(code: "backup_folder_failed", message: message, details: nil))
        }
      }
    }
  }
  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    guard controller === picker else { return }
    let result = pickerResult; pickerResult = nil; picker = nil; result?(nil)
  }
  func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
    guard controller === picker, let result = pickerResult else { return }
    pickerResult = nil; picker = nil
    guard urls.count == 1 else { result(nil); return }
    let store = files
    worker.async {
      let outcome = Result { try store.select(urls[0]) }
      DispatchQueue.main.async {
        switch outcome {
        case .success(let value): result(value)
        case .failure:
          result(FlutterError(code: "backup_folder_failed", message: "Không lưu được quyền truy cập thư mục. Hãy chọn lại.", details: nil))
        }
      }
    }
  }
}
