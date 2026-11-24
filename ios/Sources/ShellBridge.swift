import UIKit
import WebKit

/**
 iOS side of the shell bridge. BRIDGE.md at `poc/shell/` is the contract; this
 class answers it op by op with the same shapes Android uses.

 Rules kept here without exception: every call resolves exactly once, nothing
 throws across the bridge, unknown ops answer `E_NOT_IMPLEMENTED` with the op
 name, and bad input answers `E_BAD_REQUEST` with the same messages Android
 sends (the page tests them).
 */
final class ShellBridge: NSObject, WKScriptMessageHandler {

    /// Name the page posts to: `webkit.messageHandlers.shell.postMessage(json)`.
    static let messageHandlerName = "shell"

    /** Ops this build answers. `toast` is deliberately absent: iOS has none. */
    private static let ops = [
        "device.info",
        "haptics.impact",
        "openExternal",
        "share",
        "screen.keepAwake",
        "screen.fullscreen",
        "schedule.add",
        "schedule.list",
        "schedule.cancel",
        "schedule.state",
        "notify.show",
        "notify.dismiss",
        "notify.permission",
        // Deprecated aliases from before the schedule/notify split.
        "notify.schedule",
        "notify.cancel",
        "ads.consent",
        "ads.state",
        "ads.interstitial.load",
        "ads.interstitial.show",
        "ads.rewarded.load",
        "ads.rewarded.show",
        "ads.banner.show",
        "ads.banner.hide",
        "http.fetch",
        "http.cookies",
        "http.clearCookies",
        "pay.status",
        "pay.checkout",
    ]

    private weak var host: ShellViewController?
    private lazy var ads = AdsManager(bridge: self)
    private let http = HttpFetcher.shared
    private let pay = PayHost.shared

    /// The view controller system UI is presented from, and where the banner
    /// slot lives.
    var hostController: ShellViewController? { host }

    init(host: ShellViewController) {
        self.host = host
        super.init()
        pay.attach(bridge: self)
        // A tap that opened the app must reach the page once it can listen.
        NotifyCenter.shared.onTap = { [weak self] tap in
            self?.emit("notify.tap", tap)
        }
    }

    /// Called by the view controller when the page has finished loading.
    func flushPendingTap() {
        NotifyCenter.shared.flushPendingTap()
    }

    // MARK: - Transport

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard message.name == ShellBridge.messageHandlerName else { return }
        let body: String
        if let text = message.body as? String {
            body = text
        } else if let object = message.body as? [String: Any],
                  let data = try? JSONSerialization.data(withJSONObject: object),
                  let text = String(data: data, encoding: .utf8) {
            body = text
        } else {
            return
        }
        // WebKit calls this on the main thread; the hop is kept because every
        // op touches UIKit and one missing hop is a crash nobody can reproduce.
        if Thread.isMainThread {
            dispatch(body)
        } else {
            DispatchQueue.main.async { [weak self] in self?.dispatch(body) }
        }
    }

    private func dispatch(_ raw: String) {
        var id: String?
        do {
            guard let data = raw.data(using: .utf8) else {
                resolve(nil, false, ShellBridge.error("E_INTERNAL", "message is not UTF-8"))
                return
            }
            let parsed = try JSONSerialization.jsonObject(with: data)
            guard let message = parsed as? [String: Any] else {
                resolve(nil, false, ShellBridge.error("E_INTERNAL", "message is not an object"))
                return
            }
            id = message["id"] as? String
            let op = message["op"] as? String ?? ""
            let payload = message["payload"] as? [String: Any] ?? [:]
            handle(id: id, op: op, payload: payload)
        } catch {
            resolve(id, false, ShellBridge.error("E_INTERNAL", error.localizedDescription))
        }
    }

    /// Resolves from outside the dispatcher, when the answer arrives later.
    func answer(_ id: String?, _ ok: Bool, _ data: [String: Any]) {
        resolve(id, ok, data)
    }

    private func resolve(_ id: String?, _ ok: Bool, _ data: [String: Any]) {
        guard let id = id, let webView = host?.webView else { return }
        let json = ShellBridge.jsonString(data) ?? "{}"
        let js = "window.__shell&&window.__shell.resolve("
            + ShellBridge.jsQuote(id) + ","
            + (ok ? "true" : "false") + ","
            + json + ")"
        evaluate(js, on: webView)
    }

    func emit(_ name: String, _ data: [String: Any]) {
        guard let webView = host?.webView else { return }
        let js = "window.__shell&&window.__shell.event("
            + ShellBridge.jsQuote(name) + ","
            + (ShellBridge.jsonString(data) ?? "{}") + ")"
        evaluate(js, on: webView)
    }

    private func evaluate(_ js: String, on webView: WKWebView) {
        if Thread.isMainThread {
            webView.evaluateJavaScript(js, completionHandler: nil)
        } else {
            DispatchQueue.main.async {
                webView.evaluateJavaScript(js, completionHandler: nil)
            }
        }
    }

    // MARK: - Ops

    private func handle(id: String?, op: String, payload: [String: Any]) {
        switch op {
        case "device.info":
            resolve(id, true, deviceInfo())

        case "haptics.impact":
            haptic(style: payload["style"] as? String ?? "light")
            resolve(id, true, [:])

        case "openExternal":
            let url = payload["url"] as? String ?? ""
            if openExternal(url) {
                resolve(id, true, [:])
            } else {
                resolve(id, false, ShellBridge.error("E_BAD_REQUEST", "https only"))
            }

        case "share":
            let text = payload["text"] as? String ?? ""
            let url = payload["url"] as? String ?? ""
            if share(text: text, url: url) {
                resolve(id, true, [:])
            } else {
                resolve(id, false, ShellBridge.error("E_BAD_REQUEST", "text or url is required"))
            }

        case "screen.keepAwake":
            let on = payload["on"] as? Bool ?? false
            Screen.shared.setAwake(on)
            resolve(id, true, ["on": on, "mode": "window"])

        case "screen.fullscreen":
            let on = payload["on"] as? Bool ?? false
            guard let host = host else {
                resolve(id, false, ShellBridge.error("E_UNAVAILABLE", "window cannot go immersive"))
                return
            }
            _ = host.setFullscreen(on)
            resolve(id, true, ["on": on, "mode": "immersive"])

        case "schedule.add", "notify.schedule":
            scheduleReminder(id: id, payload: payload)

        case "schedule.cancel", "notify.cancel":
            let reminderId = (payload["id"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if reminderId.isEmpty {
                resolve(id, false, ShellBridge.error("E_BAD_REQUEST", "id is required"))
                return
            }
            NotifyCenter.shared.cancel(id: reminderId)
            resolve(id, true, [:])

        case "schedule.list":
            NotifyCenter.shared.pending { [weak self] items in
                self?.resolve(id, true, ["items": items])
            }

        case "schedule.state":
            NotifyCenter.shared.permissionState { [weak self] state in
                self?.resolve(id, true, [
                    "native": true,
                    // No exactness knob exists on iOS: a calendar trigger is
                    // the system's own alarm, so the promise is exact.
                    "exact": true,
                    "alarmsAllowed": true,
                    "alarmClock": false,
                    "permission": state,
                ])
            }

        case "notify.show":
            let title = payload["title"] as? String ?? ""
            let body = payload["body"] as? String ?? ""
            if title.isEmpty && body.isEmpty {
                resolve(id, false, ShellBridge.error("E_BAD_REQUEST", "title or body is required"))
                return
            }
            let tag = payload["tag"] as? String ?? payload["id"] as? String ?? ""
            let kind = (payload["kind"] as? String ?? "") == "alarm" ? "alarm" : "reminder"
            let link = payload["link"] as? String ?? ""
            NotifyCenter.shared.showNow(
                id: tag, title: title, body: body, kind: kind, link: link
            ) {
                [weak self] result in
                switch result {
                case .scheduled:
                    self?.resolve(id, true, ["mode": "native", "kind": kind])
                case .denied:
                    self?.resolve(id, false, ShellBridge.error("E_DENIED", "notifications are disabled"))
                case .failed(let message):
                    self?.resolve(id, false, ShellBridge.error("E_UNAVAILABLE", message))
                }
            }

        case "notify.dismiss":
            let tag = payload["tag"] as? String ?? payload["id"] as? String ?? ""
            if tag.isEmpty {
                resolve(id, false, ShellBridge.error("E_BAD_REQUEST", "tag is required"))
                return
            }
            NotifyCenter.shared.cancel(id: tag)
            resolve(id, true, [:])

        case "notify.permission":
            NotifyCenter.shared.permissionState { [weak self] state in
                self?.resolve(id, true, ["state": state])
            }

        case "ads.consent":
            ads.requestConsent(id)

        case "ads.state":
            ads.state(id)

        case "ads.interstitial.load":
            ads.loadInterstitial(id, adUnit: payload["adUnit"] as? String ?? "")

        case "ads.interstitial.show":
            ads.showInterstitial(id,
                policy: payload["policy"] as? String ?? "fail",
                timeoutMs: payload["timeoutMs"] as? Int ?? 0)

        case "ads.rewarded.load":
            ads.loadRewarded(id, adUnit: payload["adUnit"] as? String ?? "")

        case "ads.rewarded.show":
            ads.showRewarded(id,
                policy: payload["policy"] as? String ?? "fail",
                timeoutMs: payload["timeoutMs"] as? Int ?? 0)

        case "ads.banner.show":
            ads.showBanner(id, adUnit: payload["adUnit"] as? String ?? "")

        case "ads.banner.hide":
            ads.hideBanner(id)

        case "http.fetch":
            http.fetch(id, payload, self)

        case "http.cookies":
            resolve(id, true, http.cookies(payload))

        case "pay.status":
            resolve(id, true, pay.status())

        case "pay.checkout":
            pay.checkout(id, payload)

        case "http.clearCookies":
            resolve(id, true, http.clearCookies(payload))

        default:
            // `toast` lands here on purpose: it is Android only.
            resolve(id, false, ShellBridge.error("E_NOT_IMPLEMENTED", op))
        }
    }

    private func scheduleReminder(id: String?, payload: [String: Any]) {
        let reminderId = (payload["id"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if reminderId.isEmpty {
            resolve(id, false, ShellBridge.error("E_BAD_REQUEST", "id is required"))
            return
        }
        let at = payload["at"] as? String ?? ""
        guard let time = NotifyCenter.parseAt(at) else {
            resolve(id, false, ShellBridge.error("E_BAD_REQUEST", "at must be HH:MM"))
            return
        }
        let title = payload["title"] as? String ?? ""
        if title.isEmpty {
            resolve(id, false, ShellBridge.error("E_BAD_REQUEST", "title is required"))
            return
        }
        let body = payload["body"] as? String ?? ""
        let daily = (payload["repeat"] as? String ?? "daily").lowercased() != "once"
        let kind = (payload["kind"] as? String ?? "") == "alarm" ? "alarm" : "reminder"
        let link = payload["link"] as? String ?? ""

        NotifyCenter.shared.schedule(
            id: reminderId,
            title: title,
            body: body,
            at: time,
            daily: daily,
            kind: kind,
            link: link
        ) { [weak self] result in
            switch result {
            case .scheduled:
                self?.resolve(id, true, [
                    "mode": "native",
                    "exact": true,
                    "alarmClock": false,
                    "kind": kind,
                ])
            case .denied:
                self?.resolve(id, false, ShellBridge.error("E_DENIED", "notifications are disabled"))
            case .failed(let message):
                self?.resolve(id, false, ShellBridge.error("E_UNAVAILABLE", message))
            }
        }
    }

    // MARK: - Native helpers

    private func deviceInfo() -> [String: Any] {
        return [
            "platform": "ios",
            "osVersion": UIDevice.current.systemVersion,
            "appVersion": ShellBridge.appVersion(),
            "ops": ShellBridge.ops,
        ]
    }

    private static func appVersion() -> String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? ""
        let build = info?["CFBundleVersion"] as? String ?? ""
        if short.isEmpty { return build }
        if build.isEmpty { return short }
        return short + " (" + build + ")"
    }

    /**
     Same six styles as Android, mapped to the two system generators. Throwing
     the generator away after one impact is correct: it is cheap and the
     prepared state is only worth keeping for a burst.
     */
    private func haptic(style: String) {
        switch style {
        case "light", "medium", "heavy":
            let generator = UIImpactFeedbackGenerator(style: ShellBridge.impactStyle(style))
            generator.prepare()
            generator.impactOccurred()
        case "success":
            let generator = UINotificationFeedbackGenerator()
            generator.prepare()
            generator.notificationOccurred(.success)
        case "warning":
            let generator = UINotificationFeedbackGenerator()
            generator.prepare()
            generator.notificationOccurred(.warning)
        case "error":
            let generator = UINotificationFeedbackGenerator()
            generator.prepare()
            generator.notificationOccurred(.error)
        default:
            let generator = UIImpactFeedbackGenerator(style: .light)
            generator.prepare()
            generator.impactOccurred()
        }
    }

    private static func impactStyle(_ name: String) -> UIImpactFeedbackGenerator.FeedbackStyle {
        switch name {
        case "heavy": return .heavy
        case "medium": return .medium
        default: return .light
        }
    }

    /// https only, and only when a browser exists to take it.
    private func openExternal(_ raw: String) -> Bool {
        guard raw.hasPrefix("https://"), let url = URL(string: raw) else { return false }
        guard let scheme = url.scheme?.lowercased(), scheme == "https" else { return false }
        guard UIApplication.shared.canOpenURL(url) else { return false }
        UIApplication.shared.open(url, options: [:], completionHandler: nil)
        return true
    }

    /**
     Share sheet. Resolves as soon as the sheet is up, like Android: whether the
     user picked something is not the page's business.
     */
    private func share(text: String, url: String) -> Bool {
        guard let host = host else { return false }
        var items: [Any] = []
        if !text.isEmpty { items.append(text) }
        if !url.isEmpty, let link = URL(string: url) { items.append(link) }
        guard !items.isEmpty else { return false }

        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        // iPad shows the sheet in a popover and crashes without an anchor.
        if let popover = controller.popoverPresentationController {
            popover.sourceView = host.view
            popover.sourceRect = CGRect(
                x: host.view.bounds.midX,
                y: host.view.bounds.midY,
                width: 1,
                height: 1
            )
            popover.permittedArrowDirections = []
        }
        host.presentShell(controller)
        return true
    }

    // MARK: - Serialization

    /// JS-safe quoted string. JSON quoting is a superset of JS for these cases.
    static func jsQuote(_ value: String) -> String {
        if let data = try? JSONSerialization.data(withJSONObject: [value]),
           let text = String(data: data, encoding: .utf8),
           text.hasPrefix("["), text.hasSuffix("]") {
            return String(text.dropFirst().dropLast())
        }
        // Fallback that cannot produce an unterminated literal.
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
        return "\"" + escaped + "\""
    }

    static func jsonString(_ object: [String: Any]) -> String? {
        guard JSONSerialization.isValidJSONObject(object) else { return nil }
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func error(_ code: String, _ message: String?) -> [String: Any] {
        var data: [String: Any] = ["error": code]
        if let message = message, !message.isEmpty {
            data["message"] = message
        }
        return data
    }
}
