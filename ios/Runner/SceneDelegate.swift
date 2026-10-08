import Flutter
import UIKit

class SceneDelegate: FlutterSceneDelegate {
  override func scene(
    _ scene: UIScene,
    willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions
  ) {
    super.scene(scene, willConnectTo: session, options: connectionOptions)
    installNativeTabsIfNeeded()
  }

  override func sceneDidBecomeActive(_ scene: UIScene) {
    super.sceneDidBecomeActive(scene)
    // A storyboard window may become available after willConnectTo.
    installNativeTabsIfNeeded()
  }

  private func installNativeTabsIfNeeded() {
    guard let window = window else { return }
    let controller: NativeTabsController
    if let existing = window.rootViewController as? NativeTabsController {
      controller = existing
    } else if let flutter = window.rootViewController as? FlutterViewController {
      controller = NativeTabsController(flutterViewController: flutter)
      window.rootViewController = controller
    } else {
      return
    }

    // Flutter's automatic scene discovery only recognizes a FlutterVC root.
    // Keep forwarding scene/plugin events to the same engine after containment.
    if let engine = controller.flutterViewController.engine {
      registerSceneLifeCycle(with: engine)
    }
    (UIApplication.shared.delegate as? AppDelegate)?.attachNativeTabs(to: controller)
  }
}
