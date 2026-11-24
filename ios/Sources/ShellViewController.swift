import UIKit
import WebKit

/**
 The one screen of the shell: a WKWebView pointed at the bundled page and
 the bridge that lets the page call into native code.

 Nothing here knows what the page shows. Everything app specific lives in the
 page; this file only owns the plumbing described in BRIDGE.md.
 */
final class ShellViewController: UIViewController {

    private(set) var webView: WKWebView!
    private var bridge: ShellBridge!

    /// Column that stacks the WebView above the banner slot. See setUpWebView.
    private var column: UIStackView!
    private var bannerSlot: UIView!

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        setUpWebView()
        observeKeyboard()
        observeBackground()
    }

    // MARK: - Screen

    /**
     Applies the page's immersive request to the system UI this controller owns.
     Unlike Android this cannot fail, so the answer is always true; the bridge
     still reports it so both hosts give the page the same shape.
     */
    @discardableResult
    func setFullscreen(_ on: Bool) -> Bool {
        Screen.shared.immersive = on
        setNeedsStatusBarAppearanceUpdate()
        setNeedsUpdateOfHomeIndicatorAutoHidden()
        return true
    }

    /// Hiding the bars is the whole of immersive mode on iOS: the window itself
    /// keeps its size, and the page sees the space it had all along.
    override var prefersStatusBarHidden: Bool { Screen.shared.immersive }

    override var prefersHomeIndicatorAutoHidden: Bool { Screen.shared.immersive }

    override var preferredStatusBarUpdateAnimation: UIStatusBarAnimation { .fade }

    /**
     A page that goes to the background must not leave the display lit or the
     bars gone; Android does the same in `onPause`.
     */
    private func observeBackground() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(enterBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
    }

    @objc private func enterBackground() {
        guard Screen.shared.immersive || Screen.shared.awake else { return }
        Screen.shared.reset()
        setNeedsStatusBarAppearanceUpdate()
        setNeedsUpdateOfHomeIndicatorAutoHidden()
    }

    // MARK: - Setup

    private func setUpWebView() {
        let configuration = WKWebViewConfiguration()

        // Bundle contents are served through app://local, see AssetSchemeHandler.
        let root = Bundle.main.resourceURL ?? Bundle.main.bundleURL
        configuration.setURLSchemeHandler(
            AssetSchemeHandler(root: root),
            forURLScheme: AssetSchemeHandler.scheme
        )

        // The page owns the media policy: no autoplay with sound, inline playback.
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = .audio
        // Lets `element.requestFullscreen()` work, which the page's fallback
        // path uses. Video full screen in a WKWebView needs none of this: the
        // player brings its own controller.
        if #available(iOS 15.4, *) {
            configuration.preferences.isElementFullscreenEnabled = true
        }

        bridge = ShellBridge(host: self)
        configuration.userContentController.add(bridge, name: ShellBridge.messageHandlerName)

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.navigationDelegate = self
        webView.allowsBackForwardNavigationGestures = false
        // The page sizes itself against the space it is given; insets would
        // make the viewport and the layout disagree on notched devices.
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.scrollView.backgroundColor = .black

        // WebView on top taking the rest, banner slot below at its natural
        // height. A hidden arranged subview takes no room, so the page gets the
        // pixels back and reflows -- that is the whole point of not using an
        // overlay.
        let column = UIStackView(arrangedSubviews: [webView])
        column.axis = .vertical
        column.distribution = .fill
        column.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            column.topAnchor.constraint(equalTo: view.topAnchor),
            column.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        let slot = UIView()
        slot.isHidden = true
        // The banner keeps its own height; the WebView absorbs what is left.
        webView.setContentHuggingPriority(.defaultLow, for: .vertical)
        slot.setContentHuggingPriority(.required, for: .vertical)
        column.addArrangedSubview(slot)

        self.column = column
        self.bannerSlot = slot
        self.webView = webView

        webView.load(URLRequest(url: AssetSchemeHandler.startURL))
    }

    // MARK: - Banner

    /// Parents an SDK banner view in the slot under the WebView, once.
    func installBanner(_ banner: UIView) {
        guard let slot = bannerSlot else { return }
        banner.translatesAutoresizingMaskIntoConstraints = false
        slot.addSubview(banner)
        NSLayoutConstraint.activate([
            banner.centerXAnchor.constraint(equalTo: slot.centerXAnchor),
            banner.topAnchor.constraint(equalTo: slot.topAnchor),
            banner.bottomAnchor.constraint(equalTo: slot.bottomAnchor),
        ])
    }

    /// Showing the slot takes room from the WebView; hiding gives it back.
    func setBannerVisible(_ visible: Bool) {
        guard let slot = bannerSlot, slot.isHidden == visible else { return }
        UIView.performWithoutAnimation {
            slot.isHidden = !visible
            self.view.layoutIfNeeded()
        }
    }

    /// Height the banner currently occupies, in points.
    func bannerHeight() -> CGFloat {
        guard let slot = bannerSlot, !slot.isHidden else { return 0 }
        return slot.frame.height
    }

    /// Tells the page how much room it has now that a banner may be showing.
    func emitViewport() {
        guard let webView = webView else { return }
        bridge.emit("viewport", [
            "width": Double(webView.frame.width),
            "height": Double(webView.frame.height),
            "banner": Double(bannerHeight()),
        ])
    }

    // MARK: - Keyboard

    private var keyboardVisible = false

    private func observeKeyboard() {
        let center = NotificationCenter.default
        center.addObserver(
            self,
            selector: #selector(keyboardWillChange(_:)),
            name: UIResponder.keyboardWillChangeFrameNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(keyboardWillHide),
            name: UIResponder.keyboardWillHideNotification,
            object: nil
        )
    }

    @objc private func keyboardWillChange(_ note: Notification) {
        guard
            let endFrame = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue
        else { return }
        let frameInView = view.convert(endFrame, from: nil)
        let overlap = view.bounds.intersection(frameInView)
        let height = overlap.isNull ? 0 : overlap.height
        let visible = height > 0
        keyboardVisible = visible
        bridge.emit("keyboard", ["visible": visible, "height": Double(height)])
    }

    @objc private func keyboardWillHide() {
        guard keyboardVisible else { return }
        keyboardVisible = false
        bridge.emit("keyboard", ["visible": false, "height": 0])
    }

    // MARK: - Presentation

    /// Single place that presents system UI (share sheet, consent form, ads).
    func presentShell(_ controller: UIViewController) {
        if let presented = presentedViewController, !presented.isBeingDismissed {
            presented.present(controller, animated: true)
            return
        }
        present(controller, animated: true)
    }

    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }
}

// MARK: - Navigation allowlist

extension ShellViewController: WKNavigationDelegate {

    /**
     The page may only navigate inside app://local. Anything else is somebody
     else's URL and leaves the app instead of replacing the shell.
     */
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }
        if url.scheme == AssetSchemeHandler.scheme {
            decisionHandler(.allow)
            return
        }
        if url.scheme == "about" {
            decisionHandler(.allow)
            return
        }
        // Sub-frame loads (ads, frames) keep their own behaviour.
        if navigationAction.targetFrame?.isMainFrame == false {
            decisionHandler(.allow)
            return
        }
        if let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
            UIApplication.shared.open(url)
        }
        decisionHandler(.cancel)
    }

    func webView(
        _ webView: WKWebView,
        didFinish navigation: WKNavigation!
    ) {
        // Events can only be delivered once the page has its listener; a tap
        // that opened the app from a cold start waits until exactly here.
        bridge.flushPendingTap()
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        NSLog("[shell] provisional navigation failed: %@", error.localizedDescription)
    }
}

