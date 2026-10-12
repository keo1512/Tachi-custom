import UIKit
import XCTest
@testable import Runner

final class PrivacyPlatformBridgeTests: XCTestCase {
  func testShieldPolicySupportsAlwaysIncognitoAndMandatoryLock() {
    MainActor.assumeIsolated {
      let shield = PrivacyScreenShield(windows: { [] })
      XCTAssertFalse(shield.protectsInactive)
      shield.secureMode = "always"
      XCTAssertTrue(shield.protectsInactive)
      shield.secureMode = "incognito"
      shield.incognito = true
      XCTAssertTrue(shield.protectsInactive)
      shield.incognito = false
      XCTAssertFalse(shield.protectsInactive)
      shield.secureMode = "off"
      shield.lockEnabled = true
      XCTAssertTrue(shield.protectsInactive)
    }
  }

  func testShieldCoversAllVisibleWindowsAndRemovesEveryCover() {
    MainActor.assumeIsolated {
      let first = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 800))
      let second = UIWindow(frame: CGRect(x: 0, y: 0, width: 430, height: 932))
      let hidden = UIWindow()
      first.isHidden = false
      second.isHidden = false
      hidden.isHidden = true
      let shield = PrivacyScreenShield(windows: { [first, second, hidden] })
      shield.secureMode = "always"
      shield.show()
      XCTAssertEqual(shield.coveredWindowCount, 2)
      XCTAssertEqual(first.subviews.last?.frame, first.bounds)
      XCTAssertTrue(first.subviews.last?.accessibilityViewIsModal == true)
      shield.show()
      XCTAssertEqual(shield.coveredWindowCount, 2)
      shield.hide()
      XCTAssertEqual(shield.coveredWindowCount, 0)
      XCTAssertTrue(first.subviews.isEmpty)
      XCTAssertTrue(second.subviews.isEmpty)
    }
  }

  func testOffPolicyNeverAddsAnAppSwitcherCover() {
    MainActor.assumeIsolated {
      let window = UIWindow()
      window.isHidden = false
      let shield = PrivacyScreenShield(windows: { [window] })
      shield.secureMode = "off"
      shield.show()
      XCTAssertEqual(shield.coveredWindowCount, 0)
    }
  }
}
