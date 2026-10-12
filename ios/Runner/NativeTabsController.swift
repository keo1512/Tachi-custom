import Flutter
import UIKit

/// UIKit owns the six navigation items; the existing FlutterVC stays mounted.
/// UITabBarController would replace the sixth item with its automatic More UI.
final class NativeTabsController: UIViewController, UITabBarDelegate {
  let flutterViewController: FlutterViewController
  private let nativeTabBar = UITabBar()
  private let originalSafeAreaInsets: UIEdgeInsets
  private var selectedTabIndex = 0
  private var tabsVisible = false
  var onSelectTab: ((Int) -> Void)?

  static let titles = ["Thư viện", "Cập nhật", "Duyệt", "Tải xuống", "Lịch sử", "Thêm"]
  private static let symbols = [
    "books.vertical.fill", "bolt.fill", "safari", "arrow.down.circle", "clock.fill", "gearshape.fill"
  ]
  private static let identifiers = ["library", "updates", "browse", "downloads", "history", "more"]

  init(flutterViewController: FlutterViewController) {
    self.flutterViewController = flutterViewController
    originalSafeAreaInsets = flutterViewController.additionalSafeAreaInsets
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("Use the existing storyboard FlutterViewController")
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    addChild(flutterViewController)
    flutterViewController.view.frame = view.bounds
    flutterViewController.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    view.addSubview(flutterViewController.view)
    flutterViewController.didMove(toParent: self)

    nativeTabBar.delegate = self
    nativeTabBar.itemPositioning = .fill
    nativeTabBar.tintColor = UIColor(red: 175.0 / 255.0, green: 196.0 / 255.0, blue: 1, alpha: 1)
    nativeTabBar.accessibilityIdentifier = "native_main_tabs"
    // Keep UIKit's own background, selection effect and material. SDK 26 adopts
    // the system Liquid Glass appearance without drawing a custom capsule.
    nativeTabBar.setItems(Self.titles.enumerated().map { index, title in
      let item = UITabBarItem(title: title, image: UIImage(systemName: Self.symbols[index]), tag: index)
      item.accessibilityIdentifier = "native_tab_\(Self.identifiers[index])"
      return item
    }, animated: false)
    nativeTabBar.selectedItem = nativeTabBar.items?[selectedTabIndex]
    nativeTabBar.isHidden = !tabsVisible
    view.addSubview(nativeTabBar)
  }

  func configure(index: Int, visible: Bool, titles: [String], dark: Bool?, badges: [String?], order: [Int] = Array(0..<6)) {
    loadViewIfNeeded()
    if let dark = dark {
      overrideUserInterfaceStyle = dark ? .dark : .light
    }
    for (offset, item) in (nativeTabBar.items ?? []).enumerated() {
      let identity = order[offset]
      item.title = titles[offset]
      item.image = UIImage(systemName: Self.symbols[identity])
      item.accessibilityIdentifier = "native_tab_\(Self.identifiers[identity])"
      item.accessibilityLabel = Self.titles[identity]
      item.badgeValue = badges[offset]
    }
    select(index: index)
    setVisible(visible)
  }

  func select(index: Int) {
    selectedTabIndex = index
    if isViewLoaded {
      nativeTabBar.selectedItem = nativeTabBar.items?[index]
    }
  }

  func setVisible(_ visible: Bool) {
    tabsVisible = visible
    guard isViewLoaded else { return }
    nativeTabBar.isHidden = !visible
    view.setNeedsLayout()
    view.layoutIfNeeded()
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    // Position the bar first so UIKit can include its actual bottom safe inset.
    // Re-measure after attachment: rotation and SDK 26 can change native height.
    let fittingSize = CGSize(width: view.bounds.width, height: view.bounds.height)
    positionTabBar(height: nativeTabBar.sizeThatFits(fittingSize).height)
    nativeTabBar.layoutIfNeeded()
    positionTabBar(height: nativeTabBar.sizeThatFits(fittingSize).height)
    var insets = originalSafeAreaInsets
    if tabsVisible {
      insets.bottom += max(0, nativeTabBar.bounds.height - view.safeAreaInsets.bottom)
    }
    // Flutter reports this native clearance in MediaQuery.viewPadding. Its
    // content can paint underneath the glass while controls honor SafeArea.
    if flutterViewController.additionalSafeAreaInsets != insets {
      flutterViewController.additionalSafeAreaInsets = insets
    }
  }

  override func viewSafeAreaInsetsDidChange() {
    super.viewSafeAreaInsetsDidChange()
    view.setNeedsLayout()
  }

  private func positionTabBar(height: CGFloat) {
    nativeTabBar.frame = CGRect(
      x: 0, y: view.bounds.height - height, width: view.bounds.width, height: height
    )
  }

  func tabBar(_ tabBar: UITabBar, didSelect item: UITabBarItem) {
    guard Self.titles.indices.contains(item.tag) else { return }
    selectedTabIndex = item.tag
    onSelectTab?(item.tag)
  }

  override var childForStatusBarStyle: UIViewController? { flutterViewController }
  override var childForStatusBarHidden: UIViewController? { flutterViewController }
  override var childForHomeIndicatorAutoHidden: UIViewController? { flutterViewController }
  override var childForScreenEdgesDeferringSystemGestures: UIViewController? { flutterViewController }
  override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
    flutterViewController.supportedInterfaceOrientations
  }
  override var shouldAutorotate: Bool { flutterViewController.shouldAutorotate }
}

/// Registration and scene attachment can occur in either order at cold launch.
/// Retain the configuration so an early Dart call is applied to the native bar.
final class NativeTabsBridge {
  private let channel: FlutterMethodChannel
  private weak var controller: NativeTabsController?
  private var index = 0
  private var visible = false
  private var titles = NativeTabsController.titles
  private var dark: Bool?
  private var order = Array(0..<6)
  private var badges = [String?](repeating: nil, count: NativeTabsController.titles.count)

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "dev.tachibooks/native_tabs", binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else {
        result(FlutterError(code: "native_tabs_unavailable", message: "Native tab bridge was released", details: nil))
        return
      }
      self.handle(call, result: result)
    }
  }

  func attach(to controller: NativeTabsController) {
    self.controller = controller
    controller.onSelectTab = { [weak self] index in
      guard let self = self else { return }
      self.index = index
      self.channel.invokeMethod("selectTab", arguments: ["index": index, "tabId": self.order[index]])
    }
    applyConfiguration()
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard ["configure", "select", "setVisible"].contains(call.method) else {
      result(FlutterMethodNotImplemented)
      return
    }
    guard let arguments = call.arguments as? [String: Any] else {
      invalidArguments(result)
      return
    }
    if let value = arguments["index"] {
      guard let number = value as? Int, NativeTabsController.titles.indices.contains(number) else {
        invalidArguments(result)
        return
      }
    }
    if let value = arguments["visible"], !(value is Bool) {
      invalidArguments(result)
      return
    }
    if let value = arguments["dark"], !(value is Bool) {
      invalidArguments(result)
      return
    }
    if let value = arguments["titles"] {
      guard let list = value as? [String], list.count == titles.count else {
        invalidArguments(result)
        return
      }
    }
    if let value = arguments["order"] {
      guard let list = value as? [Int], list.count == titles.count,
        Set(list) == Set(0..<titles.count) else {
        invalidArguments(result)
        return
      }
    }
    if let value = arguments["badges"] {
      guard let list = value as? [Any], list.count == badges.count,
        list.allSatisfy({ $0 is String || $0 is NSNull }) else {
        invalidArguments(result)
        return
      }
    }
    if call.method == "select", arguments["index"] == nil {
      invalidArguments(result)
      return
    }
    if call.method == "setVisible", arguments["visible"] == nil {
      invalidArguments(result)
      return
    }
    if let value = arguments["index"] as? Int { index = value }
    if let value = arguments["visible"] as? Bool { visible = value }
    if let value = arguments["dark"] as? Bool { dark = value }
    if let value = arguments["titles"] as? [String] { titles = value }
    if let value = arguments["order"] as? [Int] { order = value }
    if let value = arguments["badges"] as? [Any] { badges = value.map { $0 as? String } }
    applyConfiguration()
    result(true)
  }

  private func applyConfiguration() {
    controller?.configure(index: index, visible: visible, titles: titles, dark: dark, badges: badges, order: order)
  }

  private func invalidArguments(_ result: FlutterResult) {
    result(FlutterError(
      code: "native_tabs_invalid_arguments",
      message: "Cần chỉ số 0...5, trạng thái hiển thị/giao diện và sáu tab theo thứ tự hợp lệ.",
      details: nil
    ))
  }
}
