import Flutter
import UIKit
import UserNotifications

class SceneDelegate: FlutterSceneDelegate {
  override func scene(
    _ scene: UIScene,
    willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions
  ) {
    super.scene(scene, willConnectTo: session, options: connectionOptions)
    for context in connectionOptions.urlContexts {
      TachiDeepLinkInbox.shared.accept(context.url)
    }
    if let response = connectionOptions.notificationResponse,
      response.actionIdentifier == UNNotificationDefaultActionIdentifier,
      let url = TaskNotificationSummary.destination(
        identifier: response.notification.request.identifier,
        userInfo: response.notification.request.content.userInfo) {
      TachiDeepLinkInbox.shared.accept(url)
    }
    installNativeTabsIfNeeded()
  }

  override func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
    let remaining = Set(URLContexts.filter { !TachiDeepLinkInbox.shared.accept($0.url) })
    if !remaining.isEmpty { super.scene(scene, openURLContexts: remaining) }
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
    registerSceneLifeCycle(with: controller.flutterViewController.engine)
    (UIApplication.shared.delegate as? AppDelegate)?.attachNativeTabs(to: controller)
  }
}
