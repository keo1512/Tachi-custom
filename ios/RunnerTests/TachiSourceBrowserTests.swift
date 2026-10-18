import Flutter
import UIKit
import WebKit
import XCTest
import tachi_runtime

private final class BrowserPageLoaded: NSObject, WKNavigationDelegate {
  let loaded: XCTestExpectation
  init(_ loaded: XCTestExpectation) { self.loaded = loaded }
  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loaded.fulfill() }
}

private final class DeferredBrowserUserAgent: WKWebView {
  var pending: ((Any?, Error?) -> Void)?
  override func evaluateJavaScript(_ javaScriptString: String, completionHandler: ((Any?, Error?) -> Void)? = nil) {
    pending = completionHandler
  }
}

private final class BrowserRequestCapture: WKWebView {
  var requests: [URLRequest] = []
  var onRequest: ((URLRequest) -> Void)?
  var backCalls = 0, forwardCalls = 0, reloadCalls = 0
  override var canGoBack: Bool { true }
  override var canGoForward: Bool { true }
  override func goBack() -> WKNavigation? { backCalls += 1; return nil }
  override func goForward() -> WKNavigation? { forwardCalls += 1; return nil }
  override func reload() -> WKNavigation? { reloadCalls += 1; return nil }
  override func load(_ request: URLRequest) -> WKNavigation? {
    requests.append(request)
    onRequest?(request)
    return nil
  }
}

// These are hosted UIKit/WebKit regressions. The nonpersistent cookie store
// and HTML fixtures avoid modifying user cookies or requiring a live website.
final class TachiSourceBrowserTests: XCTestCase {
  private var window: UIWindow!
  private var host: UIViewController!
  private var previousKeyWindow: UIWindow?
  private var animationsEnabled = true
  private let sourceURL = "https://reader.source.test/story"

  @MainActor
  func testBrowserOptionsRejectMismatchedSeedBeforePresentation() {
    let invalid: [[String: Any]] = [
      ["url": "https://other.source.test/", "cookies": []],
      ["url": "https://reader.source.test/story", "cookies": NSNull()],
    ]
    for seed in invalid {
      var calls = 0
      TachiSourceBrowser.open(options: ["url": sourceURL, "automatic": true, "seed": seed]) { result in
        XCTAssertEqual((result as? FlutterError)?.code, "INVALID_BROWSER_SESSION")
        calls += 1
      }
      XCTAssertEqual(calls, 1)
      XCTAssertNil(host.presentedViewController)
    }
  }

  @MainActor
  func testBrowserSeedImportsAllPathsAndKeepsUnrelatedCookies() throws {
    let cancelled = expectation(description: "Seed test closed")
    let (navigation, browser, _) = try open { value in
      XCTAssertEqual((value as? [String: Any])?["cancelled"] as? Bool, true)
      cancelled.fulfill()
    }
    let webView = readyPage()
    try replaceWebView(browser, with: webView)
    let stored = expectation(description: "Old source and unrelated cookies stored")
    stored.expectedFulfillmentCount = 2
    for domain in ["reader.source.test", "other.source.test"] {
      let cookie = try XCTUnwrap(HTTPCookie(properties: [.name: "old", .value: "old", .domain: domain, .path: "/"]))
      webView.configuration.websiteDataStore.httpCookieStore.setCookie(cookie) { stored.fulfill() }
    }
    wait(for: [stored], timeout: 5)
    browser.setValue(["url": sourceURL, "cookies": [[
      "name": "path-session", "value": "new", "domain": "reader.source.test", "path": "/chapter",
      "hostOnly": true, "secure": true, "httpOnly": true,
    ]]], forKey: "seed")
    let loaded = expectation(description: "Seeded source requested")
    webView.onRequest = { request in
      XCTAssertEqual(request.url?.absoluteString, self.sourceURL)
      loaded.fulfill()
    }
    browser.perform(NSSelectorFromString("seedAndLoad"))
    wait(for: [loaded], timeout: 5)
    let checked = expectation(description: "Real WebKit seed inspected")
    webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
      XCTAssertFalse(cookies.contains { $0.name == "old" && $0.domain == "reader.source.test" })
      XCTAssertTrue(cookies.contains { $0.name == "old" && $0.domain == "other.source.test" })
      let imported = cookies.first { $0.name == "path-session" }
      XCTAssertEqual(imported?.path, "/chapter")
      XCTAssertEqual(imported?.value, "new")
      XCTAssertEqual(imported?.isSecure, true)
      XCTAssertEqual(imported?.isHTTPOnly, true)
      XCTAssertNil(imported?.expiresDate)
      checked.fulfill()
    }
    wait(for: [checked], timeout: 5)
    navigation.dismiss(animated: false)
    wait(for: [cancelled], timeout: 3)
  }

  @MainActor
  func testAutomaticClearanceNeedsSuccessfulMainPageAndCompletesOnce() throws {
    let finished = expectation(description: "Verified session automatically completed")
    var completions = 0
    let (_, browser, _) = try open { value in
      let result = value as? [String: Any]
      XCTAssertEqual(result?["verified"] as? Bool, true)
      XCTAssertEqual(result?["cancelled"] as? Bool, false)
      completions += 1
      finished.fulfill()
    }
    let webView = readyPage()
    try replaceWebView(browser, with: webView)
    browser.setValue(true, forKey: "automatic")
    browser.setValue(true, forKey: "pageReady")
    browser.setValue(false, forKey: "mainResponseAllowed")
    let stored = expectation(description: "Clearance stored")
    let cookie = try XCTUnwrap(HTTPCookie(properties: [
      .name: "cf_clearance", .value: "local-fixture", .domain: "reader.source.test", .path: "/", .secure: "TRUE",
    ]))
    webView.configuration.websiteDataStore.httpCookieStore.setCookie(cookie) { stored.fulfill() }
    wait(for: [stored], timeout: 5)
    browser.perform(NSSelectorFromString("checkClearance"))
    XCTAssertEqual(completions, 0)
    browser.setValue(true, forKey: "mainResponseAllowed")
    browser.perform(NSSelectorFromString("checkClearance"))
    browser.perform(NSSelectorFromString("checkClearance"))
    wait(for: [finished], timeout: 5)
    XCTAssertEqual(completions, 1)
  }

  @MainActor
  func testAutomaticBrowserCancelsWhenAppGoesToBackground() throws {
    let cancelled = expectation(description: "Automatic browser cancelled")
    var calls = 0
    let (_, browser, _) = try open { value in
      XCTAssertEqual((value as? [String: Any])?["cancelled"] as? Bool, true)
      calls += 1
      cancelled.fulfill()
    }
    browser.setValue(true, forKey: "automatic")
    NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
    wait(for: [cancelled], timeout: 3)
    XCTAssertEqual(calls, 1)
  }

  override func setUpWithError() throws {
    XCTAssertTrue(Thread.isMainThread)
    try MainActor.assumeIsolated { try setUpBrowserWindow() }
  }

  @MainActor
  private func setUpBrowserWindow() throws {
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .first { $0.activationState == .foregroundActive })
    previousKeyWindow = scene.windows.first { $0.isKeyWindow }
    animationsEnabled = UIView.areAnimationsEnabled
    UIView.setAnimationsEnabled(false)
    host = UIViewController()
    window = UIWindow(windowScene: scene)
    window.rootViewController = host
    window.makeKeyAndVisible()
    host.loadViewIfNeeded()
  }

  override func tearDownWithError() throws {
    try MainActor.assumeIsolated { try tearDownBrowserWindow() }
  }

  @MainActor
  private func tearDownBrowserWindow() throws {
    if host.presentedViewController != nil {
      let closed = expectation(description: "Clean up presented source sheet")
      host.dismiss(animated: false) { closed.fulfill() }
      wait(for: [closed], timeout: 3)
      // The browser's programmatic-dismiss fallback runs after UIKit has
      // cleared the presentation relationship, on the next main turn.
      let settled = expectation(description: "Browser cancellation settled")
      DispatchQueue.main.async { settled.fulfill() }
      wait(for: [settled], timeout: 3)
    }
    window.isHidden = true
    previousKeyWindow?.makeKey()
    UIView.setAnimationsEnabled(animationsEnabled)
    window = nil
    host = nil
  }

  @MainActor
  private func open(_ result: @escaping FlutterResult) throws -> (UINavigationController, TachiSourceBrowser, WKWebView) {
    TachiSourceBrowser.open(url: sourceURL, result: result)
    let navigation = try XCTUnwrap(host.presentedViewController as? UINavigationController)
    let browser = try XCTUnwrap(navigation.topViewController as? TachiSourceBrowser)
    browser.loadViewIfNeeded()
    let webView = try XCTUnwrap(browser.view.subviews.compactMap { $0 as? WKWebView }.first)
    let shown = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
      navigation.presentingViewController != nil && browser.view.window != nil
    }, object: nil)
    wait(for: [shown], timeout: 3)
    return (navigation, browser, webView)
  }

  @MainActor
  private func replaceWebView(_ browser: TachiSourceBrowser, with fixture: WKWebView) throws {
    let original = try XCTUnwrap(browser.view.subviews.compactMap { $0 as? WKWebView }.first)
    if let observer = browser as? WKHTTPCookieStoreObserver {
      original.configuration.websiteDataStore.httpCookieStore.remove(observer)
      browser.setValue(false, forKey: "observingCookies")
    }
    fixture.navigationDelegate = original.navigationDelegate
    fixture.uiDelegate = original.uiDelegate
    original.stopLoading()
    original.navigationDelegate = nil
    original.uiDelegate = nil
    original.removeFromSuperview()
    fixture.frame = browser.view.bounds
    browser.view.addSubview(fixture)
    // Substitute only the WebKit dependency. The actual browser's buttons,
    // completion, presentation delegate and lifecycle remain in use.
    browser.setValue(fixture, forKey: "webView")
  }

  @MainActor
  private func readyPage(_ html: String = "<body>Source fixture</body>") -> BrowserRequestCapture {
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
    let webView = BrowserRequestCapture(frame: .zero, configuration: configuration)
    let loaded = expectation(description: "Local WebKit HTML fixture loaded")
    let observer = BrowserPageLoaded(loaded)
    webView.navigationDelegate = observer
    webView.loadHTMLString(html, baseURL: nil)
    withExtendedLifetime(observer) { wait(for: [loaded], timeout: 5) }
    return webView
  }

  @MainActor
  private func done(_ browser: TachiSourceBrowser) throws {
    let button = try XCTUnwrap(browser.navigationItem.rightBarButtonItem)
    let action = try XCTUnwrap(button.action)
    XCTAssertTrue(UIApplication.shared.sendAction(action, to: button.target, from: button, for: nil))
  }

  @MainActor
  func testInvalidSchemeAndCredentialsFailOnceOnMainThread() {
    for url in ["file:///private/data", "javascript:alert(1)", "https://user:password@reader.source.test/", "https:///missing-host"] {
      var count = 0
      TachiSourceBrowser.open(url: url) { value in
        XCTAssertTrue(Thread.isMainThread)
        XCTAssertEqual((value as? FlutterError)?.code, "INVALID_SOURCE_URL")
        count += 1
      }
      XCTAssertEqual(count, 1)
      XCTAssertNil(host.presentedViewController)
    }
  }

  @MainActor
  func testOneSheetAtATimeAndProgrammaticDismissResolvesCancellation() throws {
    let cancelled = expectation(description: "Original browser cancelled")
    var count = 0
    let (navigation, browser, webView) = try open { value in
      XCTAssertTrue(Thread.isMainThread)
      XCTAssertEqual((value as? [String: Any])?["cancelled"] as? Bool, true)
      count += 1
      cancelled.fulfill()
    }
    XCTAssertEqual(browser.title, "reader.source.test")
    XCTAssertTrue(webView.configuration.websiteDataStore.isPersistent)
    XCTAssertNotNil(webView.navigationDelegate)
    XCTAssertNotNil(webView.uiDelegate)
    var duplicates = 0
    TachiSourceBrowser.open(url: sourceURL) { value in
      XCTAssertTrue(Thread.isMainThread)
      XCTAssertEqual((value as? FlutterError)?.code, "BROWSER_ALREADY_OPEN")
      duplicates += 1
    }
    XCTAssertEqual(duplicates, 1)
    XCTAssertTrue(host.presentedViewController === navigation)
    navigation.dismiss(animated: false)
    wait(for: [cancelled], timeout: 3)
    XCTAssertEqual(count, 1)
    XCTAssertNil(host.presentedViewController)
  }

  @MainActor
  func testRealWebKitUserAgentAndCookieStoreKeepSelectedSourceScope() throws {
    let finished = expectation(description: "Source cookie session completed")
    var count = 0
    var session: [String: Any]?
    let (_, browser, _) = try open { value in
      XCTAssertTrue(Thread.isMainThread)
      session = value as? [String: Any]
      count += 1
      finished.fulfill()
    }
    let webView = readyPage()
    try replaceWebView(browser, with: webView)
    let fixtures: [(String, String)] = [
      ("exact-host", "reader.source.test"), ("parent-host", "source.test"),
      ("parent-domain", ".source.test"), ("other-domain", ".elsewhere.test"),
      ("lookalike", ".not-source.test"), ("child-host", "child.reader.source.test"),
    ]
    let stored = expectation(description: "Cookie fixtures stored")
    stored.expectedFulfillmentCount = fixtures.count
    for (name, domain) in fixtures {
      let cookie = try XCTUnwrap(HTTPCookie(properties: [
        .name: name, .value: "fixture-value", .domain: domain, .path: "/",
        .secure: "TRUE", HTTPCookiePropertyKey("HttpOnly"): "TRUE",
        .expires: Date(timeIntervalSinceNow: 600),
      ]))
      webView.configuration.websiteDataStore.httpCookieStore.setCookie(cookie) { stored.fulfill() }
    }
    wait(for: [stored], timeout: 5)
    try done(browser)
    try done(browser)
    wait(for: [finished], timeout: 5)
    XCTAssertEqual(count, 1)
    XCTAssertEqual(session?["url"] as? String, sourceURL)
    XCTAssertEqual(session?["cancelled"] as? Bool, false)
    XCTAssertTrue((session?["userAgent"] as? String)?.contains("AppleWebKit") == true)
    let cookies = try XCTUnwrap(session?["cookies"] as? [[String: Any]])
    XCTAssertEqual(Set(cookies.compactMap { $0["name"] as? String }), ["exact-host", "parent-domain"])
    let exact = try XCTUnwrap(cookies.first { $0["name"] as? String == "exact-host" })
    let domain = try XCTUnwrap(cookies.first { $0["name"] as? String == "parent-domain" })
    XCTAssertEqual(exact["hostOnly"] as? Bool, true)
    XCTAssertEqual(domain["hostOnly"] as? Bool, false)
    XCTAssertEqual(exact["secure"] as? Bool, true)
    XCTAssertEqual(exact["httpOnly"] as? Bool, true)
    XCTAssertNotNil(exact["expiresAt"] as? NSNumber)
    XCTAssertNil(host.presentedViewController)
  }

  @MainActor
  func testLateUserAgentAfterDismissCannotCompleteOrDismissNextBrowser() throws {
    let cancelled = expectation(description: "Pending capture cancelled")
    var count = 0
    let (navigation, browser, _) = try open { value in
      XCTAssertTrue(Thread.isMainThread)
      XCTAssertEqual((value as? [String: Any])?["cancelled"] as? Bool, true)
      count += 1
      cancelled.fulfill()
    }
    let deferred = DeferredBrowserUserAgent(frame: .zero, configuration: WKWebViewConfiguration())
    try replaceWebView(browser, with: deferred)
    try done(browser)
    let callback = try XCTUnwrap(deferred.pending)
    XCTAssertTrue(navigation.isModalInPresentation)
    navigation.dismiss(animated: false)
    wait(for: [cancelled], timeout: 3)
    let nextCancelled = expectation(description: "Next browser cancelled")
    let (next, _, _) = try open { value in
      XCTAssertEqual((value as? [String: Any])?["cancelled"] as? Bool, true)
      nextCancelled.fulfill()
    }
    callback("Fixture WebKit user agent", nil)
    let settled = expectation(description: "Late capture callback settled")
    DispatchQueue.main.async { settled.fulfill() }
    wait(for: [settled], timeout: 3)
    XCTAssertEqual(count, 1)
    XCTAssertTrue(host.presentedViewController === next)
    next.dismiss(animated: false)
    wait(for: [nextCancelled], timeout: 3)
  }

  @MainActor
  func testNewWindowLinksStayInTheSourceSheetAndBlockOtherHosts() throws {
    let cancelled = expectation(description: "Popup fixture browser cancelled")
    let (navigation, browser, _) = try open { value in
      XCTAssertEqual((value as? [String: Any])?["cancelled"] as? Bool, true)
      cancelled.fulfill()
    }
    let webView = readyPage("""
      <a id="same" target="_blank" href="https://reader.source.test/next">Same source</a>
      <a id="other" target="_blank" href="https://elsewhere.test/next">Other host</a>
      """)
    try replaceWebView(browser, with: webView)
    let forwarded = expectation(description: "Same-host popup forwarded into current view")
    webView.onRequest = { request in
      XCTAssertEqual(request.url?.absoluteString, "https://reader.source.test/next")
      forwarded.fulfill()
    }
    webView.evaluateJavaScript("document.getElementById('same').click()")
    wait(for: [forwarded], timeout: 5)
    let blocked = expectation(description: "Off-source popup must not load")
    blocked.isInverted = true
    webView.onRequest = { _ in blocked.fulfill() }
    webView.evaluateJavaScript("document.getElementById('other').click()")
    wait(for: [blocked], timeout: 0.5)
    XCTAssertEqual(webView.requests.count, 1)
    XCTAssertTrue(host.presentedViewController === navigation)
    XCTAssertNil(navigation.presentedViewController)
    navigation.dismiss(animated: false)
    wait(for: [cancelled], timeout: 3)
  }

  @MainActor
  func testBrowserControlsUseWebKitNavigationAndRestoreDefaultUserAgent() throws {
    let preferenceKey = "dev.tachibooks.browserUserAgents"
    let previous = UserDefaults.standard.object(forKey: preferenceKey)
    defer {
      if let previous { UserDefaults.standard.set(previous, forKey: preferenceKey) }
      else { UserDefaults.standard.removeObject(forKey: preferenceKey) }
    }
    let cancelled = expectation(description: "Controls fixture cancelled")
    let (navigation, browser, _) = try open { value in
      XCTAssertEqual((value as? [String: Any])?["cancelled"] as? Bool, true)
      cancelled.fulfill()
    }
    let webView = readyPage()
    try replaceWebView(browser, with: webView)
    browser.perform(NSSelectorFromString("updateNavigationButtons"))
    let buttons = try XCTUnwrap(browser.toolbarItems)
    XCTAssertEqual(buttons.first?.accessibilityLabel, "Trang trước")
    XCTAssertEqual(buttons[1].accessibilityLabel, "Trang tiếp theo")
    for button in buttons.prefix(2) {
      let action = try XCTUnwrap(button.action)
      XCTAssertTrue(UIApplication.shared.sendAction(action, to: button.target, from: button, for: nil))
    }
    XCTAssertEqual(webView.backCalls, 1)
    XCTAssertEqual(webView.forwardCalls, 1)
    browser.perform(NSSelectorFromString("setBrowserUserAgent:"), with: "Custom source UA")
    XCTAssertEqual(webView.customUserAgent, "Custom source UA")
    XCTAssertEqual(UserDefaults.standard.dictionary(forKey: preferenceKey)?["reader.source.test"] as? String, "Custom source UA")
    browser.perform(NSSelectorFromString("setBrowserUserAgent:"), with: "Invalid\nagent")
    XCTAssertEqual(webView.customUserAgent, "Custom source UA")
    browser.perform(NSSelectorFromString("setBrowserUserAgent:"), with: "")
    // WebKit on iOS 27 exposes an unset override as either nil or empty.
    XCTAssertTrue(webView.customUserAgent?.isEmpty ?? true)
    XCTAssertNil(UserDefaults.standard.dictionary(forKey: preferenceKey)?["reader.source.test"])
    XCTAssertEqual(webView.reloadCalls, 2)
    navigation.dismiss(animated: false)
    wait(for: [cancelled], timeout: 3)
  }

  @MainActor
  func testClearSourceCookiesRetainsUnrelatedCookiesAndReturnsEmptySourceSession() throws {
    let finished = expectation(description: "Cleared cookie session completed")
    let (_, browser, _) = try open { value in
      let session = value as? [String: Any]
      XCTAssertEqual(session?["cancelled"] as? Bool, false)
      XCTAssertEqual((session?["cookies"] as? [[String: Any]])?.count, 0)
      finished.fulfill()
    }
    let webView = readyPage()
    try replaceWebView(browser, with: webView)
    let stored = expectation(description: "Cookies to clear stored")
    stored.expectedFulfillmentCount = 2
    for domain in ["reader.source.test", "unrelated.source.test"] {
      let cookie = try XCTUnwrap(HTTPCookie(properties: [
        .name: "session", .value: "fixture", .domain: domain, .path: "/",
        .expires: Date(timeIntervalSinceNow: 600),
      ]))
      webView.configuration.websiteDataStore.httpCookieStore.setCookie(cookie) { stored.fulfill() }
    }
    wait(for: [stored], timeout: 5)
    browser.perform(NSSelectorFromString("clearSourceCookies"))
    wait(for: [finished], timeout: 5)
    let checked = expectation(description: "Other source cookie retained")
    webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
      XCTAssertEqual(cookies.map { $0.domain }, ["unrelated.source.test"])
      checked.fulfill()
    }
    wait(for: [checked], timeout: 5)
  }
}
