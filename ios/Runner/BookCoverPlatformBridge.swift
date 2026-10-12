import Flutter
import UIKit
import PhotosUI
import UniformTypeIdentifiers
import ImageIO

@MainActor
final class BookCoverPlatformBridge: NSObject, PHPickerViewControllerDelegate {
  private let channel: FlutterMethodChannel
  private var pending: FlutterResult?
  nonisolated private static let maxBytes = 8 * 1024 * 1024

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "dev.tachibooks/book-cover", binaryMessenger: messenger)
    super.init()
    channel.setMethodCallHandler { [weak self] call, result in
      DispatchQueue.main.async {
        guard let self = self else {
          result(FlutterError(code: "cover_closed", message: "Bộ chọn bìa đã đóng.", details: nil)); return
        }
        self.handle(call, result: result)
      }
    }
  }

  private func presenter() -> UIViewController? {
    guard let scene = UIApplication.shared.connectedScenes.first(where: {
      $0.activationState == .foregroundActive
    }) as? UIWindowScene,
      let root = scene.windows.first(where: { $0.isKeyWindow })?.rootViewController else { return nil }
    var controller = root
    while let next = controller.presentedViewController { controller = next }
    return controller
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard ["choosePhoto", "shareLink"].contains(call.method) else {
      result(FlutterMethodNotImplemented); return
    }
    guard let host = presenter() else {
      result(FlutterError(code: "cover_unavailable", message: "Chưa mở được bộ chọn ảnh.", details: nil)); return
    }
    if call.method == "shareLink" {
      guard let value = call.arguments as? String, value.utf8.count <= 8192,
        let url = URL(string: value), ["http", "https", "tachibooks"].contains(url.scheme?.lowercased() ?? ""),
        url.host?.isEmpty == false else {
        result(FlutterError(code: "invalid_link", message: "Liên kết chia sẻ không hợp lệ.", details: nil)); return
      }
      let sheet = UIActivityViewController(activityItems: [url], applicationActivities: nil)
      if let popover = sheet.popoverPresentationController {
        popover.sourceView = host.view
        popover.sourceRect = CGRect(x: host.view.bounds.midX, y: host.view.bounds.midY, width: 1, height: 1)
      }
      host.present(sheet, animated: true) { result(nil) }
      return
    }
    guard pending == nil else {
      result(FlutterError(code: "cover_busy", message: "Bộ chọn ảnh đang mở.", details: nil)); return
    }
    var configuration = PHPickerConfiguration(photoLibrary: .shared())
    configuration.filter = .images
    configuration.selectionLimit = 1
    let picker = PHPickerViewController(configuration: configuration)
    picker.delegate = self
    pending = result
    host.present(picker, animated: true)
  }

  func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
    picker.dismiss(animated: true)
    guard let callback = pending else { return }
    pending = nil
    guard let selected = results.first else { callback(nil); return }
    selected.itemProvider.loadFileRepresentation(forTypeIdentifier: UTType.image.identifier) { url, _ in
      guard let url else {
        DispatchQueue.main.async {
          callback(FlutterError(code: "cover_read", message: "Không đọc được ảnh đã chọn.", details: nil))
        }; return
      }
      do {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0 && size <= Self.maxBytes else { throw CoverFailure.tooLarge }
        let bytes = try Data(contentsOf: url, options: .mappedIfSafe)
        guard bytes.count > 0 && bytes.count <= Self.maxBytes,
          let source = CGImageSourceCreateWithData(bytes as CFData, nil),
          let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 2048,
            kCGImageSourceCreateThumbnailWithTransform: true
          ] as CFDictionary),
          let encoded = UIImage(cgImage: thumbnail).jpegData(compressionQuality: 0.9),
          encoded.count > 0 && encoded.count <= Self.maxBytes else { throw CoverFailure.invalid }
        // Re-encoding strips EXIF/location and bounds pixels as well as bytes.
        DispatchQueue.main.async { callback(FlutterStandardTypedData(bytes: encoded)) }
      } catch {
        DispatchQueue.main.async {
          callback(FlutterError(code: "cover_read", message: "Ảnh không hợp lệ hoặc vượt giới hạn 8 MB.", details: nil))
        }
      }
    }
  }

  private enum CoverFailure: Error { case tooLarge, invalid }
}
