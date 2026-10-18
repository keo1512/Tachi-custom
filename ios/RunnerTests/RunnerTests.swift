import Flutter
import UIKit
import XCTest
import vbook_runtime
@testable import Runner

final class RunnerTests: XCTestCase {
  func testReaderRecognitionRegionConvertsOriginAndRejectsInvalidPayloads() throws {
    let region = try XCTUnwrap(ReaderRecognitionRegion.visionRect([
      "left": 0.1, "top": 0.2, "width": 0.4, "height": 0.5,
    ]))
    XCTAssertEqual(region.minX, 0.1, accuracy: 0.000001)
    XCTAssertEqual(region.minY, 0.3, accuracy: 0.000001)
    XCTAssertEqual(region.width, 0.4, accuracy: 0.000001)
    XCTAssertEqual(region.height, 0.5, accuracy: 0.000001)
    XCTAssertEqual(ReaderRecognitionRegion.visionRect([
      "left": 0, "top": 0, "width": 1, "height": 1,
    ]), CGRect(x: 0, y: 0, width: 1, height: 1))
    let invalid: [[String: Any]] = [
      ["left": -0.1, "top": 0, "width": 1, "height": 1],
      ["left": 0, "top": 0, "width": 0, "height": 1],
      ["left": 0.9, "top": 0, "width": 0.2, "height": 1],
      ["left": 0, "top": Double.nan, "width": 1, "height": 1],
      ["left": false, "top": 0, "width": 1, "height": 1],
      ["left": "0", "top": 0, "width": 1, "height": 1],
    ]
    for payload in invalid { XCTAssertNil(ReaderRecognitionRegion.visionRect(payload)) }
  }
  func testNativeVbookCryptoUsesPinnedLibraryAndSecureRandom() throws {
    let payload: [String: Any] = [
      "manifest": ["metadata": ["source": "https://fixture.test"]],
      "scripts": ["chap.js": "load('crypto.js'); function execute(){var cipher=CryptoJS.AES.encrypt('nội dung','passphrase');return Response.success({sha:CryptoJS.SHA256('abc').toString(),plain:CryptoJS.AES.decrypt(cipher,'passphrase').toString(CryptoJS.enc.Utf8),bytes:CryptoJS.lib.WordArray.random(16).sigBytes});}"],
      "script": "chap.js", "args": [], "storage": [:]
    ]
    let result = try VbookScriptEngine().execute(payload)
    let value = try XCTUnwrap(result["data"] as? [String: Any])
    XCTAssertEqual(value["sha"] as? String, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    XCTAssertEqual(value["plain"] as? String, "nội dung")
    XCTAssertEqual(value["bytes"] as? Int, 16)
  }
  // Use the pod's bundled host instead of providing hostSource. Missing copied
  // resources, SwiftSoup API mismatches and JavaScriptCore failures must fail
  // the hosted test rather than being hidden by a JavaScript-only fixture.
  func testNativeVbookBundledHostRunsSearchDetailTOCAndChapter() throws {
    let scripts: [String: String] = [
      "common.js": "function label(value) { return 'label:' + value; }",
      "search.js": "function execute(query,page) { return Response.success(fetch('https://fixture.test/search',{queries:{q:query,page:page}}).html().select('.story').map(e=>({name:e.text(),link:e.attr('href')}))); }",
      "detail.js": "load('common.js'); function execute(url) { var d=Http.get(url).headers({Referer:url}).html(); var count=Number(localStorage.getItem('counter')||0)+1;localStorage.setItem('counter',count);return Response.success({name:d.select('h1').text(),description:d.select('.intro').html(),mode:label(MODE),count:count}); }",
      "toc.js": "function execute(url) { var out=[];for(var e of fetch(url).html().select('.chapter'))out.push({name:e.text(),url:e.attr('href')});return Response.success(out); }",
      "chap.js": "function execute(url) { var d=fetch(url,{headers:{Referer:'https://fixture.test/story'}}).html();d.select('script').remove();return Response.success(d.select('#content').html()); }",
    ]
    var requests: [[String: Any]] = []
    let fixture: ([String: Any]) throws -> [String: Any] = { request in
      requests.append(request)
      let url = try XCTUnwrap(request["url"] as? String)
      let html: String
      switch url {
      case "https://fixture.test/search":
        html = "<a class='story' href='/story'>Fixture story</a>"
      case "https://fixture.test/story":
        html = "<h1>Fixture story</h1><div class='intro'>A <i>description</i></div>"
      case "https://fixture.test/toc":
        html = "<a class='chapter' href='/one'>Chapter one</a><a class='chapter' href='/two'>Chapter two</a>"
      case "https://fixture.test/one":
        html = "<div id='content'>Hello <b>reader</b><script>bad()</script></div>"
      default:
        XCTFail("Unexpected fixture request: \(url)")
        html = ""
      }
      return [
        "status": 200, "ok": true, "url": url,
        "headers": ["content-type": "text/html; charset=utf-8"],
        "base64Data": Data(html.utf8).base64EncodedString(), "charset": "utf-8",
      ]
    }
    func run(_ script: String, _ args: [String], storage: [String: String] = [:]) throws -> [String: Any] {
      let payload: [String: Any] = [
        "manifest": [
          "metadata": ["source": "https://fixture.test"],
          "config": ["MODE": ["default": "default"]],
        ],
        "scripts": scripts, "script": script, "args": args, "storage": storage,
      ]
      return try VbookScriptEngine().execute(payload, fetchOverride: fixture)
    }

    let search = try XCTUnwrap(try run("search.js", ["story", "2"])["data"] as? [[String: Any]])
    XCTAssertEqual(search.count, 1)
    XCTAssertEqual(search.first?["name"] as? String, "Fixture story")
    XCTAssertEqual(search.first?["link"] as? String, "/story")
    let searchOptions = try XCTUnwrap(requests.first?["options"] as? [String: Any])
    XCTAssertEqual(searchOptions["queries"] as? [String: String], ["q": "story", "page": "2"])

    let detailResult = try run("detail.js", ["https://fixture.test/story"], storage: ["counter": "2"])
    let detail = try XCTUnwrap(detailResult["data"] as? [String: Any])
    XCTAssertEqual(detail["name"] as? String, "Fixture story")
    XCTAssertTrue((detail["description"] as? String)?.contains("<i>description</i>") == true)
    XCTAssertEqual(detail["mode"] as? String, "label:default")
    XCTAssertEqual(detail["count"] as? Int, 3)
    XCTAssertEqual((detailResult["storage"] as? [String: String])?["counter"], "3")
    let detailOptions = try XCTUnwrap(requests.last?["options"] as? [String: Any])
    XCTAssertEqual(detailOptions["headers"] as? [String: String], ["Referer": "https://fixture.test/story"])

    let toc = try XCTUnwrap(try run("toc.js", ["https://fixture.test/toc"])["data"] as? [[String: Any]])
    XCTAssertEqual(toc.compactMap { $0["url"] as? String }, ["/one", "/two"])
    XCTAssertEqual(toc.compactMap { $0["name"] as? String }, ["Chapter one", "Chapter two"])

    let chapter = try XCTUnwrap(try run("chap.js", ["https://fixture.test/one"])["data"] as? String)
    XCTAssertTrue(chapter.contains("Hello"))
    XCTAssertTrue(chapter.contains("<b>reader</b>"))
    XCTAssertFalse(chapter.contains("script"))
    XCTAssertEqual(requests.count, 4)
    let chapterOptions = try XCTUnwrap(requests.last?["options"] as? [String: Any])
    XCTAssertEqual(chapterOptions["headers"] as? [String: String], ["Referer": "https://fixture.test/story"])
  }

  func testNativeVbookHTMLBridgeMutationAndContextIsolation() throws {
    let script = """
      function execute() {
        var d=Html.parse('<div id="content" data-state="old">Hello<b>reader</b><i>after</i><script>bad()</script></div>');
        var content=d.select('#content'), bold=content.children()[0];
        content.attr('data-state','new');bold.tagName('strong');bold.text('reader');
        var next=bold.next(), previous=next.prev();
        var before=content.attributes()['data-state'];content.removeAttr('data-state');
        d.select('script').remove();
        localStorage.setItem('counter',Number(localStorage.getItem('counter')||0)+1);
        return Response.success({html:content.html(),own:content.ownText(),parent:bold.parent().attr('id'),
          next:next.text(),previous:previous.tagName(),before:before,after:content.attr('data-state'),
          count:content.children().size(),clean:Html.clean('<section>A<b>B</b><script>bad()</script></section>',['b'])});
      }
      """
    let payload: [String: Any] = [
      "manifest": ["metadata": ["source": "https://fixture.test"]],
      "scripts": ["chap.js": script], "script": "chap.js", "args": [String](),
      "storage": [String: String](),
    ]
    let engine = VbookScriptEngine()
    let first = try engine.execute(payload)
    let data = try XCTUnwrap(first["data"] as? [String: Any])
    XCTAssertTrue((data["html"] as? String)?.contains("<strong>reader</strong>") == true)
    XCTAssertFalse((data["html"] as? String)?.contains("script") == true)
    XCTAssertEqual(data["own"] as? String, "Hello")
    XCTAssertEqual(data["parent"] as? String, "content")
    XCTAssertEqual(data["next"] as? String, "after")
    XCTAssertEqual(data["previous"] as? String, "strong")
    XCTAssertEqual(data["before"] as? String, "new")
    XCTAssertEqual(data["after"] as? String, "")
    XCTAssertEqual(data["count"] as? Int, 2)
    XCTAssertTrue((data["clean"] as? String)?.contains("<b>B</b>") == true)
    XCTAssertFalse((data["clean"] as? String)?.contains("section") == true)
    XCTAssertFalse((data["clean"] as? String)?.contains("bad()") == true)
    XCTAssertEqual((first["storage"] as? [String: String])?["counter"], "1")
    // The same engine instance still creates a fresh JSContext per invocation.
    let fresh = try engine.execute(payload)
    XCTAssertEqual((fresh["storage"] as? [String: String])?["counter"], "1")
    var restored = payload
    restored["storage"] = first["storage"]
    let resumed = try engine.execute(restored)
    XCTAssertEqual((resumed["storage"] as? [String: String])?["counter"], "2")
  }

  func testNativeVbookUnsupportedCapabilityIsAnExplicitError() throws {
    let payload: [String: Any] = [
      "manifest": ["metadata": ["source": "https://fixture.test"]],
      "scripts": ["chap.js": "function execute(){return Engine.get('x');}"],
      "script": "chap.js", "args": [String](), "storage": [String: String](),
    ]
    XCTAssertThrowsError(try VbookScriptEngine().execute(payload)) { error in
      XCTAssertEqual((error as? VbookFailure)?.code, "UNSUPPORTED_CAPABILITY")
    }
  }

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
