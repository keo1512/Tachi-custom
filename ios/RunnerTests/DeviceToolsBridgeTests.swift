import XCTest
@testable import Runner

final class DeviceToolsBridgeTests: XCTestCase {
  func testUsageCountsOwnFilesAndNeverFollowsExternalLinksOrChangesInput() throws {
    let manager = FileManager.default
    let root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let outside = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try manager.createDirectory(at: root, withIntermediateDirectories: false)
    try manager.createDirectory(at: outside, withIntermediateDirectories: false)
    defer { try? manager.removeItem(at: root); try? manager.removeItem(at: outside) }
    let attachments = root.appendingPathComponent("attachments", isDirectory: true)
    try manager.createDirectory(at: attachments, withIntermediateDirectories: false)
    let data = Data([1, 2, 3]), external = Data(repeating: 9, count: 20)
    let file = attachments.appendingPathComponent("page.png")
    try data.write(to: file)
    try Data([4, 5]).write(to: root.appendingPathComponent("tachibooks-auto-123.json"))
    try external.write(to: outside.appendingPathComponent("private.bin"))
    try manager.createSymbolicLink(at: root.appendingPathComponent("external"), withDestinationURL: outside)
    let usage = try DeviceToolsBridge.measure(root)
    XCTAssertEqual(usage.total, 5)
    XCTAssertEqual(usage.library, 3)
    XCTAssertEqual(usage.backups, 2)
    XCTAssertEqual(try Data(contentsOf: file), data)
    XCTAssertEqual(try Data(contentsOf: outside.appendingPathComponent("private.bin")), external)
    XCTAssertEqual(try DeviceToolsBridge.measure(root.appendingPathComponent("external")).total, 0)
  }
  func testMissingDirectoryDoesNotBecomeAnErrorOrCreateFiles() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    XCTAssertEqual(try DeviceToolsBridge.measure(root).total, 0)
    XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
  }
}
