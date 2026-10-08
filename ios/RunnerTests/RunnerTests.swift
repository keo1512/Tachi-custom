import Flutter
import UIKit
import XCTest
@testable import Runner

final class RunnerTests: XCTestCase {
  @MainActor
  func testNativeTabsShareFlutterEngineAndSynchronizeNavigation() async throws {
    await waitUntil("Storyboard scene attaches UIKit tabs and receives Dart configure") {
      guard let controller = self.sceneTabsController,
        let bar = self.tabBar(in: controller) else { return false }
      return controller.view.window != nil && !bar.isHidden && bar.bounds.height > 0
    }

    let controller = try XCTUnwrap(sceneTabsController)
    let bar = try XCTUnwrap(tabBar(in: controller))
    let items = try XCTUnwrap(bar.items)
    let flutter = controller.flutterViewController
    let engine = try XCTUnwrap(flutter.engine)
    let window = try XCTUnwrap(controller.view.window)
    let expectedTitles = ["Thư viện", "Cập nhật", "Duyệt", "Tải xuống", "Lịch sử", "Thêm"]

    XCTAssertTrue(window.rootViewController === controller)
    XCTAssertEqual(items.count, 6, "UIKit must retain all six items, without automatic More overflow")
    XCTAssertEqual(items.map { $0.tag }, Array(0..<6))
    XCTAssertEqual(items.compactMap { $0.title }, expectedTitles)
    XCTAssertTrue(items.allSatisfy { $0.image != nil })
    XCTAssertTrue((bar.delegate as? NativeTabsController) === controller)
    XCTAssertTrue(flutter.parent === controller)
    XCTAssertEqual(controller.children.count, 1)
    XCTAssertTrue(controller.children.first === flutter)
    XCTAssertTrue(engine.viewController === flutter)
    XCTAssertTrue(flutter.view.window === window)

    guard items.count == 6 else { return }
    // Do not set selectedItem here. The native delegate sends selectTab to
    // Dart; only a successful route change and Dart's select call can update
    // this UIKit selection. Exercise all six routes, including Downloads.
    for index in [5, 0, 1, 2, 3, 4, 5, 0] {
      let previous = bar.selectedItem?.tag
      XCTAssertNotEqual(previous, index)
      bar.delegate?.tabBar?(bar, didSelect: items[index])
      await waitUntil("Native tab \(index) reaches Dart navigation and returns to UIKit") {
        bar.selectedItem?.tag == index && !bar.isHidden
      }
      XCTAssertTrue(flutter.engine === engine, "Switching tabs must reuse the startup engine")
      XCTAssertTrue(engine.viewController === flutter)
      XCTAssertTrue(flutter.parent === controller)
      XCTAssertEqual(controller.children.count, 1)
    }

    let visibleInsets = flutter.additionalSafeAreaInsets
    XCTAssertGreaterThan(visibleInsets.bottom, 0)
    XCTAssertGreaterThanOrEqual(
      flutter.view.safeAreaInsets.bottom + 0.5,
      controller.view.bounds.height - bar.frame.minY,
      "Flutter controls must receive clearance for the whole native tab bar"
    )

    // Go through Flutter's real navigation channel to a page outside the
    // six-tab shell; this checks the route observer, not a direct UI setter.
    flutter.pushRoute("/source")
    await waitUntil("Subpage hides native tabs and releases their additional safe inset") {
      bar.isHidden && flutter.additionalSafeAreaInsets.bottom < visibleInsets.bottom
    }
    let hiddenInsets = flutter.additionalSafeAreaInsets
    XCTAssertEqual(hiddenInsets.top, visibleInsets.top, accuracy: 0.5)
    XCTAssertEqual(hiddenInsets.left, visibleInsets.left, accuracy: 0.5)
    XCTAssertEqual(hiddenInsets.right, visibleInsets.right, accuracy: 0.5)
    XCTAssertEqual(
      flutter.view.safeAreaInsets.bottom,
      controller.view.safeAreaInsets.bottom + hiddenInsets.bottom,
      accuracy: 0.5
    )

    flutter.pushRoute("/")
    await waitUntil("Returning to Library restores native tabs and the original visible inset") {
      !bar.isHidden && bar.selectedItem?.tag == 0
        && abs(flutter.additionalSafeAreaInsets.bottom - visibleInsets.bottom) < 0.5
    }
    XCTAssertTrue(window.rootViewController === controller)
    XCTAssertTrue(flutter.engine === engine)
    XCTAssertTrue(engine.viewController === flutter)
    XCTAssertEqual(controller.children.count, 1)
  }

  @MainActor
  private var sceneTabsController: NativeTabsController? {
    UIApplication.shared.connectedScenes
      .compactMap { ($0 as? UIWindowScene)?.windows }
      .flatMap { $0 }
      .first { $0.isKeyWindow }?.rootViewController as? NativeTabsController
  }

  @MainActor
  private func tabBar(in controller: NativeTabsController) -> UITabBar? {
    controller.view.subviews.compactMap { $0 as? UITabBar }.first
  }

  @MainActor
  private func waitUntil(_ message: String, condition: @escaping () -> Bool) async {
    let expectation = XCTNSPredicateExpectation(
      predicate: NSPredicate { _, _ in condition() }, object: nil
    )
    expectation.expectationDescription = message
    // XCTest evaluates these predicates on the main actor when awaiting
    // fulfillment, so UIKit inspection never runs on its polling thread.
    await fulfillment(of: [expectation], timeout: 30)
  }
}
