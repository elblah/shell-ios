import Foundation
import UserNotifications

/**
 Local reminders (`schedule.add` / `schedule.cancel`, and the deprecated
 `notify.schedule` / `notify.cancel` aliases).

 One-shot calendar triggers, not repeating ones: a repeating trigger fires every
 day at that wall clock time whether or not the app ever runs again, but it also
 cannot be re-armed if it is lost. Mirroring Android, a reminder is armed for the
 next occurrence of `at` and re-armed each time it fires is NOT done here — the
 system keeps the daily repetition for us, which is what the contract asks for
 ("next occurrence wins, app need not be open").

 Requests are never stored in our own defaults: the notification center is the
 store, keyed by `shell:<id>`, so re-scheduling the same id replaces it.
 */
final class NotifyCenter {

    static let shared = NotifyCenter()

    /// Prefix that keeps the app's reminders apart from anything else queued.
    /// Not private: AppDelegate strips it from a tap before handing the app id
    /// to the page.
    static let prefix = "shell:"

    var isAuthorized: Bool = false

    // --- permission ------------------------------------------------------

    /**
     Asks once, at launch, and remembers the answer. Asking up front keeps
     `notify.schedule` from failing the first time the page uses it.
     */
    func requestAuthorization(completion: (() -> Void)? = nil) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                self.isAuthorized = true
                DispatchQueue.main.async { completion?() }
            case .denied:
                self.isAuthorized = false
                DispatchQueue.main.async { completion?() }
            default:
                center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
                    self.isAuthorized = granted
                    DispatchQueue.main.async { completion?() }
                }
            }
        }
    }

    // --- scheduling ------------------------------------------------------

    enum ScheduleResult {
        case scheduled
        case denied
        case failed(String)
    }

    /**
     Schedules or replaces a reminder.

     `at` is parsed by the caller (it validates the shape); this method receives
     an already checked `(hour, minute)` pair.
     */
    func schedule(
        id: String,
        title: String,
        body: String,
        at: (hour: Int, minute: Int),
        daily: Bool,
        kind: String,
        link: String = "",
        completion: @escaping (ScheduleResult) -> Void
    ) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            let allowed = settings.authorizationStatus == .authorized
                || settings.authorizationStatus == .provisional
                || settings.authorizationStatus == .ephemeral
            guard allowed else {
                DispatchQueue.main.async { completion(.denied) }
                return
            }

            let content = UNMutableNotificationContent()
            content.title = title
            if !body.isEmpty { content.body = body }
            content.sound = .default
            if kind == "alarm", #available(iOS 15.0, *) {
                // Time sensitive breaks through a Focus mode, which is the
                // closest an alarm gets to Android without the Apple-approved
                // critical alert entitlement. It still stays silent in silent
                // mode, and that limit is documented rather than hidden.
                content.interruptionLevel = .timeSensitive
            }
            // Carried to the tap handler so the page can open the right screen
            // even when the app was not running.
            if !link.isEmpty { content.userInfo = ["link": link] }

            var components = DateComponents()
            components.hour = at.hour
            components.minute = at.minute

            let trigger = UNCalendarNotificationTrigger(
                dateMatching: components,
                repeats: daily
            )
            let request = UNNotificationRequest(
                identifier: NotifyCenter.prefix + id,
                content: content,
                trigger: trigger
            )
            center.add(request) { error in
                DispatchQueue.main.async {
                    if let error = error {
                        completion(.failed(error.localizedDescription))
                    } else {
                        completion(.scheduled)
                    }
                }
            }
        }
    }

    func cancel(id: String) {
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: [NotifyCenter.prefix + id])
        UNUserNotificationCenter.current()
            .removeDeliveredNotifications(withIdentifiers: [NotifyCenter.prefix + id])
    }

    // --- immediate delivery ----------------------------------------------

    /**
     Posts a notification right now, with no trigger: the system delivers it as
     soon as it is added. Nothing is stored on our side, so a dismissed banner
     is gone -- the same meaning `notify.show` has on Android.
     */
    func showNow(
        id: String,
        title: String,
        body: String,
        kind: String,
        link: String = "",
        completion: @escaping (ScheduleResult) -> Void
    ) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            let allowed = settings.authorizationStatus == .authorized
                || settings.authorizationStatus == .provisional
                || settings.authorizationStatus == .ephemeral
            guard allowed else {
                DispatchQueue.main.async { completion(.denied) }
                return
            }

            let content = UNMutableNotificationContent()
            content.title = title
            if !body.isEmpty { content.body = body }
            content.sound = .default
            if kind == "alarm", #available(iOS 15.0, *) {
                content.interruptionLevel = .timeSensitive
            }
            // The deep link travels with the notification so a tap can hand it
            // back to the page, exactly as a scheduled one does.
            if !link.isEmpty { content.userInfo = ["link": link] }

            let request = UNNotificationRequest(
                identifier: NotifyCenter.prefix + (id.isEmpty ? UUID().uuidString : id),
                content: content,
                trigger: nil
            )
            center.add(request) { error in
                DispatchQueue.main.async {
                    if let error = error {
                        completion(.failed(error.localizedDescription))
                    } else {
                        completion(.scheduled)
                    }
                }
            }
        }
    }

    /// Permission state in the shell's vocabulary: granted, denied, prompt.
    func permissionState(completion: @escaping (String) -> Void) {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let state: String
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral: state = "granted"
            case .denied: state = "denied"
            default: state = "prompt"
            }
            DispatchQueue.main.async { completion(state) }
        }
    }

    /**
     Everything still queued, for `schedule.list`. The notification center is
     the only store, so this asks it instead of keeping a copy that could drift.
     */
    func pending(completion: @escaping ([[String: Any]]) -> Void) {
        UNUserNotificationCenter.current().getPendingNotificationRequests { requests in
            var items: [[String: Any]] = []
            for request in requests where request.identifier.hasPrefix(NotifyCenter.prefix) {
                let id = String(request.identifier.dropFirst(NotifyCenter.prefix.count))
                var at = ""
                var repeatMode = "once"
                if let trigger = request.trigger as? UNCalendarNotificationTrigger {
                    let components = trigger.dateComponents
                    if let hour = components.hour, let minute = components.minute {
                        at = String(format: "%02d:%02d", hour, minute)
                    }
                    repeatMode = trigger.repeats ? "daily" : "once"
                }
                items.append([
                    "id": id,
                    "title": request.content.title,
                    "body": request.content.body,
                    "at": at,
                    "repeat": repeatMode,
                    // iOS has no stored kind: the channel is decided at
                    // delivery, so everything reads as a reminder.
                    "kind": "reminder",
                    "link": "",
                ])
            }
            DispatchQueue.main.async { completion(items) }
        }
    }

    // --- tap plumbing ----------------------------------------------------

    /**
     A tap can arrive before the page exists (cold start from the banner). The
     payload is kept here until the bridge says the page is ready; that is the
     only place that knows when JavaScript can receive an event.
     */
    private var queuedTap: [String: Any]?

    /// Set by the bridge, which turns it into a `notify.tap` event.
    var onTap: (([String: Any]) -> Void)?

    /// Entry point for the delegate: a delivered notification was opened.
    func handleTap(id: String, userInfo: [AnyHashable: Any]) {
        let payload: [String: Any] = [
            "id": id,
            "kind": "reminder",
            "deepLink": userInfo["link"] as? String ?? "",
        ]
        DispatchQueue.main.async {
            if let onTap = self.onTap {
                onTap(payload)
            } else {
                self.queuedTap = payload
            }
        }
    }

    /// Called once the page can receive events.
    func flushPendingTap() {
        guard let tap = queuedTap else { return }
        queuedTap = nil
        onTap?(tap)
    }

    // --- validation ------------------------------------------------------

    /// `HH:MM` (24 h) to components, or nil when the string is not that shape.
    static func parseAt(_ raw: String) -> (hour: Int, minute: Int)? {
        let parts = raw.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0].count == 2, parts[1].count == 2 else { return nil }
        guard let hour = Int(parts[0]), let minute = Int(parts[1]) else { return nil }
        guard hour >= 0, hour < 24, minute >= 0, minute < 60 else { return nil }
        return (hour, minute)
    }
}
