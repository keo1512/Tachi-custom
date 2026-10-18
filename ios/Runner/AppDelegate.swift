import Flutter
import UIKit
import Network
import Vision
import Photos
import ImageIO
import SwiftUI
import Translation
import UserNotifications

@main
@objc class AppDelegate: FlutterAppDelegate {
  private(set) var applicationEngine: FlutterEngine?
  private var applicationChannel: FlutterMethodChannel?
  private var nativeTabsBridge: NativeTabsBridge?
  private weak var nativeTabsController: NativeTabsController?
  private var readerBridge: ReaderPlatformBridge?
  private var privacyBridge: PrivacyPlatformBridge?
  private var taskBridge: TaskPlatformBridge?
  private var deepLinkBridge: DeepLinkPlatformBridge?
  private var syncBridge: SyncPlatformBridge?
  private var backupDirectoryBridge: BackupDirectoryBridge?
  private var localComicFilesBridge: LocalComicFilesBridge?
  private var bookCoverBridge: BookCoverPlatformBridge?
  private var deviceToolsBridge: DeviceToolsBridge?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    TaskBackgroundScheduler.shared.register()
    TaskContinuedDownloads.shared.register()
    let engine = FlutterEngine(name: "tachibooks.application", project: nil, allowHeadlessExecution: true)
    applicationEngine = engine
    // Flutter only accepts platform message handlers after its shell is set up.
    // Dart messages wait on the main queue until this launch callback returns.
    guard engine.run() else { applicationEngine = nil; return false }
    let channel = FlutterMethodChannel(name: "dev.tachibooks/application", binaryMessenger: engine.binaryMessenger)
    applicationChannel = channel
    channel.setMethodCallHandler { call, result in
      if call.method == "isBackground" {
        result(UIApplication.shared.applicationState == .background)
      } else { result(FlutterMethodNotImplemented) }
    }
    configureApplicationEngine(engine)
    UNUserNotificationCenter.current().delegate = self
    if let url = launchOptions?[.url] as? URL {
      TachiDeepLinkInbox.shared.accept(url)
    }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  override func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    let request = response.notification.request
    if TaskNotificationSummary.recognizes(request.identifier) {
      if response.actionIdentifier == UNNotificationDefaultActionIdentifier,
        let url = TaskNotificationSummary.destination(identifier: request.identifier, userInfo: request.content.userInfo) {
        // The existing bounded cold/warm inbox feeds the Dart app-lock gate.
        // Receiving a notification never starts queue work or source HTTP.
        TachiDeepLinkInbox.shared.accept(url)
      }
      completionHandler()
      return
    }
    super.userNotificationCenter(center, didReceive: response, withCompletionHandler: completionHandler)
  }

  override func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    if TaskNotificationSummary.recognizes(notification.request.identifier) {
      completionHandler([])
      return
    }
    super.userNotificationCenter(center, willPresent: notification, withCompletionHandler: completionHandler)
  }

  override func application(
    _ application: UIApplication,
    open url: URL,
    options: [UIApplication.OpenURLOptionsKey: Any] = [:]
  ) -> Bool {
    if TachiDeepLinkInbox.shared.accept(url) { return true }
    return super.application(application, open: url, options: options)
  }

  private func configureApplicationEngine(_ engine: FlutterEngine) {
    GeneratedPluginRegistrant.register(with: engine)
    let messenger = engine.binaryMessenger
    readerBridge = ReaderPlatformBridge(messenger: messenger)
    privacyBridge = PrivacyPlatformBridge(messenger: messenger)
    taskBridge = TaskPlatformBridge(messenger: messenger)
    deepLinkBridge = DeepLinkPlatformBridge(messenger: messenger)
    syncBridge = SyncPlatformBridge(messenger: messenger)
    backupDirectoryBridge = BackupDirectoryBridge(messenger: messenger)
    localComicFilesBridge = LocalComicFilesBridge(messenger: messenger)
    bookCoverBridge = BookCoverPlatformBridge(messenger: messenger)
    deviceToolsBridge = DeviceToolsBridge(messenger: messenger)
    let bridge = NativeTabsBridge(messenger: messenger)
    nativeTabsBridge = bridge
    if let controller = nativeTabsController {
      bridge.attach(to: controller)
    }
  }

  func activateApplicationUI() {
    applicationChannel?.invokeMethod("foreground", arguments: nil)
  }

  func attachNativeTabs(to controller: NativeTabsController) {
    nativeTabsController = controller
    nativeTabsBridge?.attach(to: controller)
  }
}

// Flutter uses a top-left origin; Vision uses a bottom-left origin.
enum ReaderRecognitionRegion {
  static func visionRect(_ value: Any?) -> CGRect? {
    guard let values = value as? [String: Any] else { return nil }
    func number(_ key: String) -> Double? {
      guard let value = values[key] as? NSNumber,
        CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite else { return nil }
      return value.doubleValue
    }
    guard let left = number("left"), let top = number("top"),
      let width = number("width"), let height = number("height"),
      left >= 0, top >= 0, width > 0, height > 0,
      left + width <= 1, top + height <= 1 else { return nil }
    return CGRect(x: left, y: max(0, 1 - top - height), width: width, height: height)
  }
}

@MainActor
private final class ReaderPlatformBridge {
  private let channel: FlutterMethodChannel
  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "dev.tachibooks/reader", binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      DispatchQueue.main.async {
        guard let self = self else {
          result(FlutterError(code: "reader_unavailable", message: "Trình đọc đã đóng.", details: nil))
          return
        }
        self.handle(call, result: result)
      }
    }
  }
  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    if call.method == "translateText" {
      guard let text = call.arguments as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        text.utf8.count <= 64 * 1024 else {
        result(FlutterError(code: "invalid_text", message: "Chọn đoạn chữ cần dịch, tối đa 64 KiB.", details: nil))
        return
      }
      guard #available(iOS 17.4, *) else {
        result(FlutterError(code: "translation_unavailable", message: "Dịch bằng iOS cần phiên bản 17.4 trở lên.", details: nil))
        return
      }
      guard let scene = UIApplication.shared.connectedScenes.first(where: {
        $0.activationState == .foregroundActive
      }) as? UIWindowScene, var presenter = scene.windows.first(where: { $0.isKeyWindow })?.rootViewController else {
        result(FlutterError(code: "no_window", message: "Không có cửa sổ để mở dịch văn bản.", details: nil))
        return
      }
      while let presented = presenter.presentedViewController { presenter = presented }
      let sheet = UIHostingController(rootView: ReaderTranslationView(text: text, onClose: { [weak presenter] in
        presenter?.dismiss(animated: true)
      }).environment(\.locale, Locale(identifier: "vi_VN")))
      sheet.overrideUserInterfaceStyle = presenter.traitCollection.userInterfaceStyle
      sheet.modalPresentationStyle = .formSheet
      presenter.present(sheet, animated: true) { result(nil) }
      return
    }
    if call.method == "conditions" {
      let monitor = NWPathMonitor()
      var finished = false
      func complete(_ path: NWPath?) {
        guard !finished else { return }
        finished = true
        monitor.cancel()
        guard let path = path else { result(nil); return }
        let device = UIDevice.current
        let wasEnabled = device.isBatteryMonitoringEnabled
        device.isBatteryMonitoringEnabled = true
        let charging = device.batteryState == .charging || device.batteryState == .full
        device.isBatteryMonitoringEnabled = wasEnabled
        result(["wifi": path.status == .satisfied && path.usesInterfaceType(.wifi),
                "unmetered": path.status == .satisfied && !path.isExpensive,
                "charging": charging])
      }
      monitor.pathUpdateHandler = { path in DispatchQueue.main.async { complete(path) } }
      monitor.start(queue: DispatchQueue(label: "dev.tachibooks.conditions"))
      DispatchQueue.main.asyncAfter(deadline: .now() + 3) { complete(nil) }
      return
    }
    if call.method == "keepAwake", let value = call.arguments as? Bool {
      UIApplication.shared.isIdleTimerDisabled = value
      result(nil)
      return
    }
    guard ["copyImage", "shareImage", "saveImage", "recognizeText", "recognizeTextRegion"].contains(call.method) else {
      result(FlutterMethodNotImplemented)
      return
    }
    let recognitionPayload = call.method == "recognizeTextRegion" ? call.arguments as? [String: Any] : nil
    let region: CGRect
    if call.method == "recognizeTextRegion" {
      guard let selected = ReaderRecognitionRegion.visionRect(recognitionPayload?["region"]) else {
        result(FlutterError(code: "invalid_region", message: "Vùng nhận dạng phải nằm trong ảnh.", details: nil))
        return
      }
      region = selected
    } else { region = CGRect(x: 0, y: 0, width: 1, height: 1) }
    let imageArgument: Any? = call.method == "recognizeTextRegion" ? recognitionPayload?["bytes"] : call.arguments
    guard let bytes = imageArgument as? FlutterStandardTypedData,
          !bytes.data.isEmpty, bytes.data.count <= 8 * 1024 * 1024,
          let source = CGImageSourceCreateWithData(bytes.data as CFData, nil),
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
          let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
          let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
          width.doubleValue > 0, height.doubleValue > 0,
          width.doubleValue * height.doubleValue <= 40_000_000,
          let image = UIImage(data: bytes.data) else {
      result(FlutterError(code: "invalid_image", message: "Ảnh trống hoặc không hợp lệ.", details: nil))
      return
    }
    if call.method == "copyImage" {
      UIPasteboard.general.image = image
      result(nil)
      return
    }
    if call.method == "recognizeText" || call.method == "recognizeTextRegion" {
      let data = bytes.data
      let rawOrientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.uint32Value ?? 1
      let orientation = CGImagePropertyOrientation(rawValue: rawOrientation) ?? .up
      DispatchQueue.global(qos: .userInitiated).async {
        do {
          let request = VNRecognizeTextRequest()
          request.recognitionLevel = .accurate
          request.usesLanguageCorrection = true
          request.regionOfInterest = region
          if #available(iOS 16.0, *) { request.automaticallyDetectsLanguage = true }
          let supported = try request.supportedRecognitionLanguages()
          let preferred = ["vi-VN", "en-US", "ja-JP", "zh-Hans", "zh-Hant", "ko-KR"]
          let selected = preferred.filter { supported.contains($0) }
          if !selected.isEmpty { request.recognitionLanguages = selected }
          try VNImageRequestHandler(data: data, orientation: orientation).perform([request])
          let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
          DispatchQueue.main.async { result(text) }
        } catch {
          DispatchQueue.main.async { result(FlutterError(code: "recognition_failed", message: error.localizedDescription, details: nil)) }
        }
      }
      return
    }
    if call.method == "saveImage" {
      let data = bytes.data
      PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
        guard status == .authorized || status == .limited else {
          DispatchQueue.main.async { result(FlutterError(code: "photos_denied", message: "Chưa được phép lưu vào Ảnh. Bật quyền thêm ảnh trong Cài đặt iOS.", details: nil)) }
          return
        }
        PHPhotoLibrary.shared().performChanges({
          PHAssetCreationRequest.forAsset().addResource(with: .photo, data: data, options: nil)
        }, completionHandler: { success, error in
          DispatchQueue.main.async {
            if success { result(nil) }
            else { result(FlutterError(code: "photos_failed", message: error?.localizedDescription ?? "Chưa lưu được ảnh.", details: nil)) }
          }
        })
      }
      return
    }
    guard let scene = UIApplication.shared.connectedScenes.first(where: {
      $0.activationState == .foregroundActive
    }) as? UIWindowScene, var presenter = scene.windows.first(where: { $0.isKeyWindow })?.rootViewController else {
      result(FlutterError(code: "no_window", message: "Không có cửa sổ để chia sẻ.", details: nil))
      return
    }
    while let presented = presenter.presentedViewController { presenter = presented }
    let sheet = UIActivityViewController(activityItems: [image], applicationActivities: nil)
    sheet.popoverPresentationController?.sourceView = presenter.view
    sheet.popoverPresentationController?.sourceRect = CGRect(x: presenter.view.bounds.midX,
      y: presenter.view.bounds.midY, width: 1, height: 1)
    sheet.completionWithItemsHandler = { _, _, _, error in
      if let error = error {
        result(FlutterError(code: "share_failed", message: error.localizedDescription, details: nil))
      } else { result(nil) }
    }
    presenter.present(sheet, animated: true)
  }
}

@available(iOS 17.4, *)
private struct ReaderTranslationView: View {
  let text: String
  let onClose: () -> Void
  @State private var translationVisible = false
  var body: some View {
    NavigationView {
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          Text(verbatim: text).textSelection(.enabled)
          Button("Dịch bằng iOS") { translationVisible = true }
        }.padding()
          .translationPresentation(isPresented: $translationVisible, text: text)
      }
      .navigationTitle("Dịch văn bản")
      .toolbar { ToolbarItem(placement: .navigationBarTrailing) { Button("Xong", action: onClose) } }
    }
  }
}
