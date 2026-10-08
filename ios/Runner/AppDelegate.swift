import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var nativeTabsBridge: NativeTabsBridge?
  private weak var nativeTabsController: NativeTabsController?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
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
