import XCTest
@testable import Runner

final class LocalComicFilesBridgeTests: XCTestCase {
  func testPathsRejectTraversalLinksAndControlNames() {
    for name in ["", "/outside.png", "../outside.png", "a/../b.png", "a//b.png", "C:/x.png", "a\\b.png", "a\n.png"] {
      XCTAssertFalse(LocalComicFolderFiles.validPath(name))
    }
    XCTAssertTrue(LocalComicFolderFiles.validPath("Truyện/Chương 10/1.png"))
  }
  func testNativeFolderBookmarkKeepsIdentityAndConfirmsOriginalFilesWithoutWriting() throws {
    let domain = "TachiBooksComicsTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: domain)!
    defer { defaults.removePersistentDomain(forName: domain) }
    let files = LocalComicFolderFiles(defaults: defaults)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let input = root.appendingPathComponent("1.jpg"), data = Data([1, 2, 3])
    try data.write(to: input)
    let selected = try files.select(root), again = try files.select(root)
    XCTAssertEqual(selected["id"], again["id"])
    let records = try files.list(root)
    let first = (records["files"] as! [[String: Any]])[0]
    XCTAssertEqual(try files.read(root, path: first["path"] as! String, size: first["size"] as! Int, stamp: first["stamp"] as! Int), data)
    XCTAssertEqual(try Data(contentsOf: input), data)
    files.forget()
    XCTAssertNil(files.current())
  }
  func testNativeRarBoundedReaderExpandsStoredCRCCheckedPNGFixture() throws {
    // This owned fixture was validated by 7-Zip 25.01 on Windows. Native test
    // execution is still required; host unpacking does not prove iOS behavior.
    let encoded = "UmFyIRoHAM+QcwAADQAAAAAAAACU13QAgCUARAAAAEQAAAAD5zXQxgAAAAAUMAUApIEAADEucG5niVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jf1kAAAAASUVORK5CYIIEsHsAAAcA"
    let files = try LocalComicRarReader.read(Data(base64Encoded: encoded)!)
    XCTAssertEqual(files.keys.sorted(), ["1.png"])
    XCTAssertEqual(files["1.png"]?.count, 68)
    XCTAssertEqual(files["1.png"]?.prefix(8), Data([137, 80, 78, 71, 13, 10, 26, 10]))
    XCTAssertThrowsError(try LocalComicRarReader.read(Data()))
    XCTAssertThrowsError(try LocalComicRarReader.read(Data([1, 2, 3])))
  }
}
