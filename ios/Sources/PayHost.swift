import StoreKit
import UIKit

/**
 The pay.* ops, shaped like Android's PayHost: ask the store first, report
 honestly why it cannot answer, and let the page fall back to a checkout link
 opened in the browser.

 A checkout link is only announced as "returned" here. Without a server that
 verifies the receipt, this host cannot claim the payment happened.
 */
final class PayHost {

    static let shared = PayHost()

    private weak var bridge: ShellBridge?

    /// Set while the browser is away, so the return is reported once.
    private var pendingLabel: String?
    private var pendingSince: Date?

    private init() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(willBecomeActive),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
    }

    func attach(bridge: ShellBridge) {
        self.bridge = bridge
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - pay.status

    func status() -> [String: Any] {
        let canPay = Self.canMakePayments()
        var native: [String: Any] = ["available": false]
        native["reason"] = canPay ? "no_products_configured" : "purchases_restricted"

        let web: [String: Any] = [
            "available": true,
            "note": "checkout link in the browser; payment is not verified here",
        ]
        return ["native": native, "web": web]
    }

    private static func canMakePayments() -> Bool {
        if #available(iOS 15.0, *) {
            return AppStore.canMakePayments
        }
        return SKPaymentQueue.canMakePayments()
    }

    // MARK: - pay.checkout

    /// Opens a checkout page in the browser; the return is reported later.
    func checkout(_ id: String?, _ payload: [String: Any]) {
        let url = (payload["url"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else {
            bridge?.answer(id, false, ShellBridge.error("E_BAD_REQUEST", "url is required"))
            return
        }
        guard url.hasPrefix("https://"), let target = URL(string: url) else {
            bridge?.answer(id, false, ShellBridge.error("E_BAD_REQUEST", "https only"))
            return
        }
        let label = (payload["label"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        pendingLabel = label
        pendingSince = Date()

        // Answer once, from the completion handler: it runs on the main queue
        // and knows whether anything took the URL.
        UIApplication.shared.open(target, options: [:]) { ok in
            guard ok else {
                // Forget the pending return so no event is invented later.
                self.pendingLabel = nil
                self.pendingSince = nil
                self.bridge?.answer(
                    id,
                    false,
                    ShellBridge.error("E_UNAVAILABLE", "no browser can take it")
                )
                return
            }
            self.bridge?.answer(id, true, ["opened": true, "label": label])
        }
    }

    // MARK: - return

    @objc private func willBecomeActive() {
        guard let label = pendingLabel, let since = pendingSince else { return }
        pendingLabel = nil
        pendingSince = nil

        let ms = Int(Date().timeIntervalSince(since) * 1000)
        bridge?.emit("pay.return", [
            "label": label,
            "elapsedMs": ms,
            "verified": false,
        ])
    }
}
