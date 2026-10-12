import XCTest
import vbook_runtime

// Standalone pod fixtures. The hosted RunnerTests target additionally exercises
// these public APIs using the app's copied host bundle and full source flow.
final class VbookScriptEngineTests: XCTestCase {
  func testJavaScriptCoreRunsOriginalHostWithHTMLStorageAndLocalLoad() throws {
    let payload: [String: Any] = [
      "manifest": ["metadata": ["source": "https://fixture.test"], "config": ["MODE": ["default": "default"]]],
      "scripts": ["common.js": "function label(value) { return 'label:' + value; }",
        "detail.js": "load('common.js'); function execute(url) { var doc=fetch(url).html(); var count=Number(localStorage.getItem('counter')||0)+1; localStorage.setItem('counter',count); return Response.success({name:doc.select('h1').text(),mode:label(MODE),count:count,first:doc.select('a')[0].attr('href')}); }"],
      "script": "detail.js", "args": ["https://fixture.test/story"], "storage": ["counter": "2"]]
    let result = try VbookScriptEngine().execute(payload, fetchOverride: { request in
      XCTAssertEqual(request["url"] as? String, "https://fixture.test/story")
      return ["status": 200, "ok": true, "url": "https://fixture.test/story", "headers": ["content-type": "text/html"],
        "base64Data": Data("<h1>Fixture story</h1><a href='/chapter'>Chapter</a>".utf8).base64EncodedString(), "charset": "utf-8"]
    })
    let data = try XCTUnwrap(result["data"] as? [String: Any])
    XCTAssertEqual(data["name"] as? String, "Fixture story")
    XCTAssertEqual(data["mode"] as? String, "label:default")
    XCTAssertEqual(data["count"] as? Int, 3)
    XCTAssertEqual(data["first"] as? String, "/chapter")
    XCTAssertEqual((result["storage"] as? [String: String])?["counter"], "3")
  }

  func testHTMLMutationAndExplicitUnsupportedCapability() throws {
    let payload: [String: Any] = ["manifest": ["metadata": ["source": "https://fixture.test"]],
      "scripts": ["chap.js": "function execute() { var d=Html.parse('<div id=content>Hello<b>reader</b><script>bad()</script></div>');d.select('script').remove();return Response.success(d.select('#content').html()); }"],
      "script": "chap.js", "args": [], "storage": [:]]
    let result = try VbookScriptEngine().execute(payload)
    XCTAssertTrue((result["data"] as? String)?.contains("Hello") == true)
    XCTAssertFalse((result["data"] as? String)?.contains("script") == true)
    var bad = payload
    bad["scripts"] = ["chap.js": "function execute(){return Engine.get('x');}"]
    XCTAssertThrowsError(try VbookScriptEngine().execute(bad)) { error in
      XCTAssertEqual((error as? VbookFailure)?.code, "UNSUPPORTED_CAPABILITY")
    }
  }
}
