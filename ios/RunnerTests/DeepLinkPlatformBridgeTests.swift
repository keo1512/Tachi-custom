import UIKit
import XCTest
@testable import Runner

final class DeepLinkPlatformBridgeTests: XCTestCase {
  func testColdLinksAreBoundedDeduplicatedAndKeepOAuthForPlugins() async {
    await MainActor.run {
      let inbox = TachiDeepLinkInbox()
      XCTAssertFalse(inbox.accept(URL(string: "com.googleusercontent.apps.client:/oauth")!))
      XCTAssertFalse(inbox.accept(URL(string: "tachibooks://book/" + String(repeating: "a", count: 8192))!))
      let first = URL(string: "tachibooks://book/9223372036854775807")!
      XCTAssertTrue(inbox.accept(first))
      XCTAssertTrue(inbox.accept(first))
      for index in 0..<40 { inbox.accept(URL(string: "tachibooks://book/\(index)")!) }
      let pending = inbox.drain()
      XCTAssertEqual(pending.count, 16)
      XCTAssertEqual(pending.first, first.absoluteString)
      XCTAssertTrue(inbox.drain().isEmpty)
    }
  }
  func testWarmDeliveryKeepsTheOriginalURLAndDoesNotRequeue() async {
    await MainActor.run {
      let inbox = TachiDeepLinkInbox()
      var values: [String] = []
      inbox.deliver = { values.append($0) }
      let link = URL(string: "tachibooks://read/book?chapterId=%2Fchapter%2F28")!
      XCTAssertTrue(inbox.accept(link))
      XCTAssertEqual(values, [link.absoluteString])
      let mixedCase = URL(string: "TachiBooks://book/book")!
      XCTAssertTrue(inbox.accept(mixedCase))
      XCTAssertEqual(values, [link.absoluteString, mixedCase.absoluteString])
      XCTAssertTrue(inbox.drain().isEmpty)
    }
  }
}
