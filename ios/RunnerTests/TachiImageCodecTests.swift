import Foundation
import XCTest
import tachi_runtime

final class TachiImageCodecTests: XCTestCase {
  private let stripes = "iVBORw0KGgoAAAANSUhEUgAAABAAAAAgCAIAAACU62+bAAAAIUlEQVR4nGP4z8BAEiJN9aiGUQ1DS8OgdNSohlENA6MBAEGm/hCBgiIOAAAAAElFTkSuQmCC"

  func testOriginalScanlineOrderAndPngJpegRoundTrips() throws {
    let input = try XCTUnwrap(Data(base64Encoded: stripes))
    let image = try XCTUnwrap(TachiImageCodec.decode(input))
    XCTAssertEqual(image["width"] as? Int, 16)
    XCTAssertEqual(image["height"] as? Int, 32)
    let pixels = try XCTUnwrap(image["pixels"] as? Data)
    let colors = pixels.withUnsafeBytes { Array($0.bindMemory(to: UInt32.self)) }
    XCTAssertEqual(colors.count, 16 * 32)
    XCTAssertEqual(colors[8], 0xffff0000) // First scanline: red.
    XCTAssertEqual(colors[31 * 16 + 8], 0xff0000ff) // Last: blue.
    for format in ["png", "jpeg"] {
      let encoded = try XCTUnwrap(TachiImageCodec.encode(pixels, width: 16, height: 32, format: format, quality: 95))
      let decoded = try XCTUnwrap(TachiImageCodec.decode(encoded))
      let again = try XCTUnwrap(decoded["pixels"] as? Data)
      let actual = again.withUnsafeBytes { Array($0.bindMemory(to: UInt32.self)) }
      XCTAssertGreaterThan((actual[8] >> 16) & 255, 200)
      XCTAssertLessThan(actual[8] & 255, 40)
      XCTAssertGreaterThan(actual[31 * 16 + 8] & 255, 200)
      XCTAssertLessThan((actual[31 * 16 + 8] >> 16) & 255, 40)
    }
  }

  func testInvalidAndOversizedImageInputsAreRejected() {
    XCTAssertNil(TachiImageCodec.decode(Data()))
    XCTAssertNil(TachiImageCodec.decode(Data("invalid".utf8)))
    XCTAssertNil(TachiImageCodec.decode(Data(count: 8 * 1024 * 1024 + 1)))
    XCTAssertNil(TachiImageCodec.encode(Data(count: 4), width: 0, height: 1, format: "png", quality: 95))
    XCTAssertNil(TachiImageCodec.encode(Data(count: 4), width: 20000, height: 1, format: "png", quality: 95))
    XCTAssertNil(TachiImageCodec.encode(Data(count: 4), width: 1, height: 1, format: "invalid", quality: 95))
    XCTAssertNil(TachiImageCodec.encode(Data(count: 4), width: 1, height: 1, format: "png", quality: 101))
    XCTAssertNil(TachiImageCodec.encode(Data(), width: 1, height: 1, format: "png", quality: 95))
  }
}
