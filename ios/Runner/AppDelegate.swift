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
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
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

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    readerBridge = ReaderPlatformBridge(messenger: engineBridge.applicationRegistrar.messenger())
    privacyBridge = PrivacyPlatformBridge(messenger: engineBridge.applicationRegistrar.messenger())
    taskBridge = TaskPlatformBridge(messenger: engineBridge.applicationRegistrar.messenger())
    deepLinkBridge = DeepLinkPlatformBridge(messenger: engineBridge.applicationRegistrar.messenger())
    syncBridge = SyncPlatformBridge(messenger: engineBridge.applicationRegistrar.messenger())
    backupDirectoryBridge = BackupDirectoryBridge(messenger: engineBridge.applicationRegistrar.messenger())
    localComicFilesBridge = LocalComicFilesBridge(messenger: engineBridge.applicationRegistrar.messenger())
    bookCoverBridge = BookCoverPlatformBridge(messenger: engineBridge.applicationRegistrar.messenger())
    deviceToolsBridge = DeviceToolsBridge(messenger: engineBridge.applicationRegistrar.messenger())
    let bridge = NativeTabsBridge(messenger: engineBridge.applicationRegistrar.messenger())
    nativeTabsBridge = bridge
    if let controller = nativeTabsController {
      bridge.attach(to: controller)
    }
  }

  func attachNativeTabs(to controller: NativeTabsController) {
    nativeTabsController = controller
    nativeTabsBridge?.attach(to: controller)
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
    guard ["copyImage", "shareImage", "saveImage", "recognizeText"].contains(call.method) else {
      result(FlutterMethodNotImplemented)
      return
    }
    guard let bytes = call.arguments as? FlutterStandardTypedData,
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
    if call.method == "recognizeText" {
      let data = bytes.data
      DispatchQueue.global(qos: .userInitiated).async {
        do {
          let request = VNRecognizeTextRequest()
          request.recognitionLevel = .accurate
          request.usesLanguageCorrection = true
          if #available(iOS 16.0, *) { request.automaticallyDetectsLanguage = true }
          let supported = try request.supportedRecognitionLanguages()
          let preferred = ["vi-VN", "en-US", "ja-JP", "zh-Hans", "zh-Hant", "ko-KR"]
          let selected = preferred.filter { supported.contains($0) }
          if !selected.isEmpty { request.recognitionLanguages = selected }
          try VNImageRequestHandler(data: data).perform([request])
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
