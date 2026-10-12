import CryptoKit
import Flutter
import UniformTypeIdentifiers
import UIKit

final class LocalComicFolderFiles {
  private let defaults: UserDefaults
  static let bookmarkKey = "dev.tachibooks.localComicFolderBookmarkV1"
  static let idKey = "dev.tachibooks.localComicFolderIDV1"
  static let labelKey = "dev.tachibooks.localComicFolderLabelV1"
  init(defaults: UserDefaults = .standard) { self.defaults = defaults }
  func failure(_ message: String) -> NSError { NSError(domain: "TachiBooksLocalComics", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
  static func validPath(_ path: String) -> Bool {
    !path.isEmpty && path.utf8.count <= 4096 && !path.hasPrefix("/") &&
      path.rangeOfCharacter(from: .controlCharacters) == nil && !path.contains("\\") && !path.contains(":") &&
      !path.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0.isEmpty || $0 == "." || $0 == ".." })
  }
  func current() -> [String: String]? {
    guard defaults.data(forKey: Self.bookmarkKey) != nil,
      let id = defaults.string(forKey: Self.idKey), let label = defaults.string(forKey: Self.labelKey) else { return nil }
    return ["id": id, "label": label]
  }
  func forget() { for key in [Self.bookmarkKey, Self.idKey, Self.labelKey] { defaults.removeObject(forKey: key) } }
  func select(_ url: URL) throws -> [String: String] {
    let scoped = url.startAccessingSecurityScopedResource(); defer { if scoped { url.stopAccessingSecurityScopedResource() } }
    let info = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
    guard url.isFileURL, info.isDirectory == true, info.isSymbolicLink != true else { throw failure("Chọn thư mục truyện hợp lệ trong Tệp.") }
    var id = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    if let saved = defaults.data(forKey: Self.bookmarkKey), let savedID = defaults.string(forKey: Self.idKey) {
      var stale = false
      if let previous = try? URL(resolvingBookmarkData: saved, options: [], relativeTo: nil, bookmarkDataIsStale: &stale),
        previous.standardizedFileURL == url.standardizedFileURL { id = savedID }
    }
    let bookmark = try url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
    let label = String(url.lastPathComponent.prefix(255))
    guard !label.isEmpty else { throw failure("Không xác định được tên thư mục.") }
    defaults.set(bookmark, forKey: Self.bookmarkKey); defaults.set(id, forKey: Self.idKey); defaults.set(label, forKey: Self.labelKey)
    return ["id": id, "label": label]
  }
  func access<T>(_ id: String, action: (URL) throws -> T) throws -> T {
    guard let saved = defaults.data(forKey: Self.bookmarkKey), defaults.string(forKey: Self.idKey) == id else {
      throw failure("Thư mục truyện đã thay đổi. Chọn lại thư mục rồi quét.")
    }
    var stale = false
    let root = try URL(resolvingBookmarkData: saved, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
    guard !stale, root.isFileURL else { throw failure("Quyền thư mục đã hết hạn. Chọn lại thư mục trong Tệp.") }
    let scoped = root.startAccessingSecurityScopedResource(); defer { if scoped { root.stopAccessingSecurityScopedResource() } }
    var error: NSError?, value: Result<T, Error>?
    NSFileCoordinator().coordinate(readingItemAt: root, options: [], error: &error) { coordinated in
      value = Result {
        let info = try coordinated.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard info.isDirectory == true, info.isSymbolicLink != true else { throw self.failure("Thư mục truyện không còn hợp lệ.") }
        return try action(coordinated)
      }
    }
    if let error = error { throw error }
    guard let value = value else { throw failure("Nhà cung cấp Tệp chưa cho phép truy cập.") }
    return try value.get()
  }
  private func supported(_ url: URL) -> Bool {
    ["jpg", "jpeg", "png", "webp", "gif", "avif", "heic", "heif", "jxl", "zip", "cbz", "rar", "cbr"].contains(url.pathExtension.lowercased()) || url.lastPathComponent == "details.json"
  }
  func list(_ root: URL) throws -> [String: Any] {
    let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
    var enumerationError: Error?
    guard let iterator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles], errorHandler: { _, error in enumerationError = error; return false }) else {
      throw failure("Không quét được thư mục truyện.")
    }
    var records: [[String: Any]] = [], total = 0, count = 0
    for case let file as URL in iterator {
      count += 1; guard count <= 10000 else { throw failure("Thư mục vượt giới hạn 10.000 mục.") }
      let info = try file.resourceValues(forKeys: keys)
      guard info.isSymbolicLink != true else { throw failure("Thư mục chứa liên kết; chọn thư mục chỉ có tệp gốc.") }
      if info.isDirectory == true { continue }
      guard info.isRegularFile == true else { throw failure("Thư mục chứa mục không phải tệp thông thường.") }
      if !supported(file) { continue }
      let relative = String(file.path.dropFirst(root.path.count + (root.path.hasSuffix("/") ? 0 : 1)))
      guard Self.validPath(relative), let size = info.fileSize, let modified = info.contentModificationDate else { throw failure("Thông tin tệp truyện không hợp lệ.") }
      let archive = ["zip", "cbz", "rar", "cbr"].contains(file.pathExtension.lowercased())
      guard size >= 0, size <= (archive ? 100 : 8) * 1024 * 1024 else { throw failure("Tệp truyện vượt giới hạn 8 MB/ảnh hoặc 100 MB/archive.") }
      total += size; guard total <= 200 * 1024 * 1024 else { throw failure("Một lượt quét vượt giới hạn 200 MB. Chọn thư mục nhỏ hơn.") }
      let stamp = Int(modified.timeIntervalSince1970 * 1_000_000)
      guard stamp >= 0 else { throw failure("Ngày sửa tệp truyện không hợp lệ.") }
      records.append(["path": relative, "size": size, "stamp": stamp])
    }
    if let error = enumerationError { throw error }
    records.sort { ($0["path"] as! String) < ($1["path"] as! String) }
    let bytes = try JSONSerialization.data(withJSONObject: records, options: [.sortedKeys])
    let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    return ["digest": digest, "files": records]
  }
  func read(_ root: URL, path: String, size: Int, stamp: Int) throws -> Data {
    guard Self.validPath(path), size >= 0, size <= 100 * 1024 * 1024 else { throw failure("Tệp truyện không hợp lệ.") }
    var file = root
    for part in path.split(separator: "/") {
      file.appendPathComponent(String(part))
      guard try file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw failure("Không đọc liên kết trong thư mục truyện.") }
    }
    func matches() throws -> Bool {
      file.removeAllCachedResourceValues()
      let info = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey])
      return info.isRegularFile == true && info.fileSize == size && info.contentModificationDate.map { Int($0.timeIntervalSince1970 * 1_000_000) == stamp } == true
    }
    guard try matches() else { throw failure("Tệp truyện thay đổi khi đang quét. Quét lại thư mục.") }
    let data = try Data(contentsOf: file)
    guard data.count == size, try matches() else { throw failure("Tệp truyện thay đổi khi đang đọc. Quét lại thư mục.") }
    return data
  }
}

@MainActor
final class LocalComicFilesBridge: NSObject, UIDocumentPickerDelegate {
  private let channel: FlutterMethodChannel
  private let files = LocalComicFolderFiles()
  private let worker = DispatchQueue(label: "dev.tachibooks.local-comics")
  private var pickerResult: FlutterResult?
  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "dev.tachibooks/local-comics", binaryMessenger: messenger)
    super.init()
    channel.setMethodCallHandler { [weak self] call, result in DispatchQueue.main.async {
      guard let self = self else { result(FlutterError(code: "comics_closed", message: "Bộ nhập truyện đã đóng.", details: nil)); return }
      self.handle(call, result: result)
    } }
  }
  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    if call.method == "choose" {
      guard pickerResult == nil,
        let scene = UIApplication.shared.connectedScenes.first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene,
        var presenter = scene.windows.first(where: { $0.isKeyWindow })?.rootViewController else { result(FlutterError(code: "comics_busy", message: "Mở ứng dụng để chọn thư mục.", details: nil)); return }
      while let next = presenter.presentedViewController { presenter = next }
      let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)
      picker.delegate = self; picker.allowsMultipleSelection = false; pickerResult = result
      presenter.present(picker, animated: true); return
    }
    let files = self.files
    worker.async {
      let value: Result<Any?, Error> = Result {
        if call.method == "current" { return files.current() }
        if call.method == "forget" { files.forget(); return nil }
        if call.method == "extractRar", let typed = call.arguments as? FlutterStandardTypedData {
          let entries = try LocalComicRarReader.read(typed.data)
          return entries.mapValues { FlutterStandardTypedData(bytes: $0) }
        }
        guard let args = call.arguments as? [String: Any], let id = args["folderId"] as? String else { throw files.failure("Yêu cầu thư mục truyện không hợp lệ.") }
        return try files.access(id) { root -> Any? in
          switch call.method {
          case "list": guard Set(args.keys) == ["folderId"] else { throw files.failure("Yêu cầu quét không hợp lệ.") }; return try files.list(root)
          case "confirm":
            guard Set(args.keys) == ["folderId", "digest"], let digest = args["digest"] as? String,
              try files.list(root)["digest"] as? String == digest else { throw files.failure("Thư mục thay đổi khi đang quét. Dữ liệu đã nhập được giữ nguyên; quét lại.") }
            return nil
          case "read":
            guard Set(args.keys) == ["folderId", "path", "size", "stamp"], let path = args["path"] as? String, let size = args["size"] as? Int, let stamp = args["stamp"] as? Int else { throw files.failure("Yêu cầu đọc tệp không hợp lệ.") }
            return FlutterStandardTypedData(bytes: try files.read(root, path: path, size: size, stamp: stamp))
          default: throw files.failure("Thao tác thư mục chưa được hỗ trợ.")
          }
        }
      }
      DispatchQueue.main.async {
        switch value { case .success(let value): result(value)
          case .failure(let error): result(FlutterError(code: "comics_failed", message: error.localizedDescription, details: nil)) }
      }
    }
  }
  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { let result = pickerResult; pickerResult = nil; result?(nil) }
  func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
    let result = pickerResult; pickerResult = nil
    guard let result = result, let url = urls.first else { result?(nil); return }
    let files = self.files
    worker.async {
      let value = Result { try files.select(url) }
      DispatchQueue.main.async { switch value { case .success(let folder): result(folder)
        case .failure(let error): result(FlutterError(code: "comics_failed", message: error.localizedDescription, details: nil)) } }
    }
  }
}
