import XCTest
@testable import Runner

final class BackupDirectoryBridgeTests: XCTestCase {
  func testManagedNamesNeverAcceptPaths() {
    XCTAssertTrue(BackupDirectoryFiles.validName("tachibooks-auto-1790000000000000.json"))
    for value in ["../tachibooks-auto-1790000000000000.json", "other.json", "tachibooks-auto-1790000000000000.json\n", "tachibooks-auto-1.json", "tachibooks-auto-1790000000000000.json.pending"] {
      XCTAssertFalse(BackupDirectoryFiles.validName(value))
    }
  }
  func testWritePublishesVerifiedBytesAndNeverOverwritesExistingFile() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = BackupDirectoryFiles()
    let name = "tachibooks-auto-1790000000000000.json"
    let old = Data("original".utf8), new = Data("new".utf8)
    try old.write(to: root.appendingPathComponent(name))
    let stored = try store.write(root, name: name, data: new)
    XCTAssertEqual(stored["name"] as? String, "tachibooks-auto-1790000000000001.json")
    XCTAssertEqual(try store.read(root, name: name), old)
    XCTAssertEqual(try store.read(root, name: stored["name"] as! String), new)
    XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasSuffix(".pending") })
    XCTAssertThrowsError(try store.write(root, name: "../other.json", data: new))
  }
  func testChangedBookmarkRejectsOldStoreBeforeFileAccess() {
    let suite = "TachiBooks.BackupDirectory.Tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(Data("new bookmark".utf8), forKey: BackupDirectoryFiles.bookmarkKey)
    defaults.set("Selected folder", forKey: BackupDirectoryFiles.labelKey)
    let store = BackupDirectoryFiles(defaults: defaults)
    XCTAssertThrowsError(try store.access(String(repeating: "0", count: 64), write: true) { _ in XCTFail("Must not access stale destination") })
    XCTAssertEqual(store.current()?["label"], "Selected folder")
    store.forget()
    XCTAssertNil(store.current())
  }
}
