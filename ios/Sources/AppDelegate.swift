import UIKit
import UserNotifications

/**
 Process-level setup. The window itself belongs to SceneDelegate, as it must on
 any app that ships a scene manifest (BRIDGE.md keeps the page single-window).
 */
@main
final class AppDelegate: UIResponder, UIApplicationDelegate, UNUserNotificationCenterDelegate {

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // A reminder that fires while the app is open must still show as a
        // banner, otherwise the page's own notification looks broken.
        UNUserNotificationCenter.current().delegate = self

        // Ads refuse every request until consent is resolved, so the SDK has to
        // be started early; the consent round-trip happens on first use.
        AdsManager.start()

        // Ask now, while the user is looking at the app, instead of the first
        // time the page calls notify.schedule.
        NotifyCenter.shared.requestAuthorization()
        return true
    }

    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        UISceneConfiguration(name: "Default", sessionRole: connectingSceneSession.role)
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        if #available(iOS 14.0, *) {
            completionHandler([.banner, .sound, .list])
        } else {
            completionHandler([.alert, .sound])
        }
    }

    /**
     The user opened a notification. The identifier carries our prefix and the
     app id, so the page can tell which scheduled item was tapped; the deep
     link travels in userInfo.
     */
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let request = response.notification.request
        var id = request.identifier
        if id.hasPrefix(NotifyCenter.prefix) {
            id = String(id.dropFirst(NotifyCenter.prefix.count))
        }
        NotifyCenter.shared.handleTap(id: id, userInfo: request.content.userInfo)
        completionHandler()
    }
}
