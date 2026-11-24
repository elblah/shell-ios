import UIKit
import GoogleMobileAds
import UserMessagingPlatform

/**
 AdMob + UMP side of the bridge. BRIDGE.md: ads answer `E_DENIED` until consent
 has been resolved, `E_NO_FILL` when the network has nothing, `E_UNAVAILABLE`
 for everything else.

 Loading and showing are separate calls on purpose: the page preloads while the
 user is doing something else, then shows with no wait. An ad object is single
 use, so a show that reached the screen is always followed by a background
 reload of the same unit -- that is how the second show is also instant. Ads go
 stale too: Google stops serving one roughly an hour after it loaded, so every
 cached ad carries its arrival time and is dropped before it can fail in front
 of the user.

 A banner is not a cached object but a view that lives below the WebView in the
 view controller. That is what makes the page reflow when the banner appears.

 Google's public test units are used when the page sends no `adUnit`, so a build
 without an AdMob account still works end to end.
 */
final class AdsManager {

    /// Google's public test units, iOS. Replace for release.
    private static let testInterstitial = "ca-app-pub-3940256099942544/4411468910"
    private static let testRewarded = "ca-app-pub-3940256099942544/1712485313"
    private static let testBanner = "ca-app-pub-3940256099942544/2934735716"

    /// AdMob error code for "the request was fine, there is just nothing to show".
    /// Not the same number as Android (3 there, 1 here).
    private static let noFillCode = 1

    /// An ad is served for about an hour; drop it a little early.
    private static let ttl: TimeInterval = 55 * 60

    /// How long a lazy show waits for a load before giving up.
    private static let defaultShowTimeout: TimeInterval = 6

    private enum State {
        static let none = "none"
        static let loading = "loading"
        static let ready = "ready"
        static let shown = "shown"
        static let hidden = "hidden"
        static let failed = "failed"
    }

    /// A page call parked while a lazy load runs.
    private struct Waiting {
        let id: String?
        let work: DispatchWorkItem
    }

    private let bridge: ShellBridge

    private var interstitial: InterstitialAd?
    private var interstitialUnit = AdsManager.testInterstitial
    private var interstitialAt: Date?
    private var interstitialState = State.none
    private var waitingInterstitial: Waiting?

    private var rewarded: RewardedAd?
    private var rewardedUnit = AdsManager.testRewarded
    private var rewardedAt: Date?
    private var rewardedState = State.none
    private var waitingRewarded: Waiting?

    private var bannerView: BannerView?
    private var bannerUnit = AdsManager.testBanner
    private var bannerState = State.hidden
    private var bannerDelegate: BannerEvents?

    // Strong references: the SDK holds the delegate weakly, and a released
    // delegate means no dismissal callback and a promise that never resolves.
    private var interstitialDelegate: InterstitialPresenter?
    private var rewardedDelegate: RewardedPresenter?

    /// What the last rewarded show earned, reported when the ad closes.
    private var earned = false
    private var earnedAmount = ""
    private var earnedType = ""

    init(bridge: ShellBridge) {
        self.bridge = bridge
    }

    // MARK: - SDK

    /**
     Starts the SDK once per process. Cheap and idempotent on our side; the SDK
     also tolerates being started repeatedly, but the flag keeps the log clean.
     */
    static func start() {
        MobileAds.shared.start(completionHandler: nil)
    }

    private var canRequestAds: Bool {
        ConsentInformation.shared.canRequestAds
    }

    // MARK: - State

    /// Reports what can be shown right now, without touching the network.
    func state(_ id: String?) {
        expireInterstitial()
        expireRewarded()
        bridge.answer(id, true, [
            "interstitial": interstitialState,
            "rewarded": rewardedState,
            "banner": bannerState,
        ])
    }

    private func expireInterstitial() {
        guard let at = interstitialAt else { return }
        if Date().timeIntervalSince(at) <= AdsManager.ttl { return }
        interstitial = nil
        interstitialAt = nil
        interstitialState = State.none
    }

    private func expireRewarded() {
        guard let at = rewardedAt else { return }
        if Date().timeIntervalSince(at) <= AdsManager.ttl { return }
        rewarded = nil
        rewardedAt = nil
        rewardedState = State.none
    }

    // MARK: - Consent

    func requestConsent(_ id: String?) {
        let parameters = RequestParameters()
        parameters.isTaggedForUnderAgeOfConsent = false

        ConsentInformation.shared.requestConsentInfoUpdate(with: parameters) { [weak self] error in
            guard let self = self else { return }
            if let error = error {
                self.bridge.answer(id, false,
                    ShellBridge.error("E_UNAVAILABLE", error.localizedDescription))
                return
            }
            DispatchQueue.main.async {
                guard let host = self.bridge.hostController else {
                    self.bridge.answer(id, false,
                        ShellBridge.error("E_UNAVAILABLE", "no view controller"))
                    return
                }
                ConsentForm.loadAndPresentIfRequired(from: host) { [weak self] formError in
                    guard let self = self else { return }
                    if let formError = formError {
                        self.bridge.answer(id, false,
                            ShellBridge.error("E_UNAVAILABLE", formError.localizedDescription))
                        return
                    }
                    self.reportStatus(id)
                }
            }
        }
    }

    private func reportStatus(_ id: String?) {
        bridge.answer(id, true, ["status": canRequestAds ? "obtained" : "required"])
    }

    // MARK: - Interstitial

    func loadInterstitial(_ id: String?, adUnit: String) {
        if !adUnit.isEmpty { interstitialUnit = adUnit }
        guard canRequestAds else {
            bridge.answer(id, false, ShellBridge.error("E_DENIED", "consent not resolved"))
            return
        }
        expireInterstitial()
        if interstitial != nil || interstitialState == State.loading {
            // Already loaded or in flight: answer, do not spend a second request.
            bridge.answer(id, true, [:])
            return
        }
        startInterstitial(id)
    }

    private func startInterstitial(_ id: String?) {
        AdsManager.start()
        interstitialState = State.loading
        emit("interstitial", State.loading, nil)
        InterstitialAd.load(with: interstitialUnit, request: Request()) { [weak self] ad, error in
            guard let self = self else { return }
            DispatchQueue.main.async {
                self.finishInterstitialLoad(id, ad: ad, error: error)
            }
        }
    }

    private func finishInterstitialLoad(_ id: String?, ad: InterstitialAd?, error: Error?) {
        if let error = error {
            interstitial = nil
            interstitialAt = nil
            interstitialState = State.none
            emit("interstitial", State.failed, AdsManager.message(error))
            if let waiting = takeWaitingInterstitial() {
                bridge.answer(waiting, true, AdsManager.miss(error))
                return
            }
            bridge.answer(id, false, AdsManager.loadError(error))
            return
        }
        guard let ad = ad else {
            interstitial = nil
            interstitialState = State.none
            emit("interstitial", State.failed, "load failed")
            if let waiting = takeWaitingInterstitial() {
                bridge.answer(waiting, true, AdsManager.miss("failed"))
                return
            }
            bridge.answer(id, false, ShellBridge.error("E_UNAVAILABLE", "load failed"))
            return
        }
        interstitial = ad
        interstitialAt = Date()
        interstitialState = State.ready
        emit("interstitial", State.ready, nil)
        if let waiting = takeWaitingInterstitial() {
            presentInterstitial(waiting)
            return
        }
        bridge.answer(id, true, [:])
    }

    /// Shows a loaded ad, or with `policy: "lazy"` loads one first and waits.
    /// A lazy miss is not an error: it answers `shown:false` with a reason so
    /// the page can carry on.
    func showInterstitial(_ id: String?, policy: String, timeoutMs: Int) {
        expireInterstitial()
        if interstitial != nil {
            presentInterstitial(id)
            return
        }
        guard policy == "lazy" else {
            bridge.answer(id, false, ShellBridge.error("E_UNAVAILABLE", "nothing loaded"))
            return
        }
        guard canRequestAds else {
            bridge.answer(id, false, ShellBridge.error("E_DENIED", "consent not resolved"))
            return
        }
        let timeout = timeoutMs > 0
            ? Double(timeoutMs) / 1000.0
            : AdsManager.defaultShowTimeout
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            guard let waiting = self.takeWaitingInterstitial() else { return }
            self.bridge.answer(waiting, true, AdsManager.miss("timeout"))
        }
        waitingInterstitial = Waiting(id: id, work: work)
        if interstitialState != State.loading { startInterstitial(nil) }
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: work)
    }

    private func takeWaitingInterstitial() -> String? {
        guard let waiting = waitingInterstitial else { return nil }
        waiting.work.cancel()
        waitingInterstitial = nil
        return waiting.id
    }

    private func presentInterstitial(_ id: String?) {
        guard let ad = interstitial else { return }
        interstitial = nil
        interstitialAt = nil
        interstitialState = State.none
        guard let host = bridge.hostController, host.view.window != nil else {
            bridge.answer(id, false, ShellBridge.error("E_UNAVAILABLE", "cannot present"))
            return
        }
        let presenter = InterstitialPresenter(id: id, owner: self)
        interstitialDelegate = presenter
        ad.fullScreenContentDelegate = presenter
        ad.present(from: host)
    }

    private func refillInterstitial() {
        // Only called after a show reached the screen, so we know this unit has
        // fill. Refilling after every failed load would just burn requests.
        if canRequestAds { startInterstitial(nil) }
    }

    // MARK: - Rewarded

    func loadRewarded(_ id: String?, adUnit: String) {
        if !adUnit.isEmpty { rewardedUnit = adUnit }
        guard canRequestAds else {
            bridge.answer(id, false, ShellBridge.error("E_DENIED", "consent not resolved"))
            return
        }
        expireRewarded()
        if rewarded != nil || rewardedState == State.loading {
            bridge.answer(id, true, [:])
            return
        }
        startRewarded(id)
    }

    private func startRewarded(_ id: String?) {
        AdsManager.start()
        rewardedState = State.loading
        emit("rewarded", State.loading, nil)
        RewardedAd.load(with: rewardedUnit, request: Request()) { [weak self] ad, error in
            guard let self = self else { return }
            DispatchQueue.main.async {
                self.finishRewardedLoad(id, ad: ad, error: error)
            }
        }
    }

    private func finishRewardedLoad(_ id: String?, ad: RewardedAd?, error: Error?) {
        if let error = error {
            rewarded = nil
            rewardedAt = nil
            rewardedState = State.none
            emit("rewarded", State.failed, AdsManager.message(error))
            if let waiting = takeWaitingRewarded() {
                bridge.answer(waiting, true, AdsManager.miss(error))
                return
            }
            bridge.answer(id, false, AdsManager.loadError(error))
            return
        }
        guard let ad = ad else {
            rewarded = nil
            rewardedState = State.none
            emit("rewarded", State.failed, "load failed")
            if let waiting = takeWaitingRewarded() {
                bridge.answer(waiting, true, AdsManager.miss("failed"))
                return
            }
            bridge.answer(id, false, ShellBridge.error("E_UNAVAILABLE", "load failed"))
            return
        }
        rewarded = ad
        rewardedAt = Date()
        rewardedState = State.ready
        emit("rewarded", State.ready, nil)
        if let waiting = takeWaitingRewarded() {
            presentRewarded(waiting)
            return
        }
        bridge.answer(id, true, [:])
    }

    func showRewarded(_ id: String?, policy: String, timeoutMs: Int) {
        expireRewarded()
        if rewarded != nil {
            presentRewarded(id)
            return
        }
        guard policy == "lazy" else {
            bridge.answer(id, false, ShellBridge.error("E_UNAVAILABLE", "nothing loaded"))
            return
        }
        guard canRequestAds else {
            bridge.answer(id, false, ShellBridge.error("E_DENIED", "consent not resolved"))
            return
        }
        let timeout = timeoutMs > 0
            ? Double(timeoutMs) / 1000.0
            : AdsManager.defaultShowTimeout
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            guard let waiting = self.takeWaitingRewarded() else { return }
            self.bridge.answer(waiting, true, AdsManager.miss("timeout"))
        }
        waitingRewarded = Waiting(id: id, work: work)
        if rewardedState != State.loading { startRewarded(nil) }
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: work)
    }

    private func takeWaitingRewarded() -> String? {
        guard let waiting = waitingRewarded else { return nil }
        waiting.work.cancel()
        waitingRewarded = nil
        return waiting.id
    }

    private func presentRewarded(_ id: String?) {
        guard let ad = rewarded else { return }
        rewarded = nil
        rewardedAt = nil
        rewardedState = State.none
        guard let host = bridge.hostController, host.view.window != nil else {
            bridge.answer(id, false, ShellBridge.error("E_UNAVAILABLE", "cannot present"))
            return
        }
        earned = false
        earnedAmount = ""
        earnedType = ""
        let presenter = RewardedPresenter(id: id, owner: self)
        rewardedDelegate = presenter
        ad.fullScreenContentDelegate = presenter
        ad.present(from: host) { [weak self] in
            guard let self = self else { return }
            // The reward is earned here and nowhere else.
            let reward = ad.adReward
            let amount = reward.amount.stringValue
            self.earned = true
            self.earnedAmount = (Double(amount) ?? 0) > 0 ? amount : "1"
            self.earnedType = reward.type
        }
    }

    private func refillRewarded() {
        if canRequestAds { startRewarded(nil) }
    }

    // MARK: - Banner

    func showBanner(_ id: String?, adUnit: String) {
        if !adUnit.isEmpty { bannerUnit = adUnit }
        guard canRequestAds else {
            bridge.answer(id, false, ShellBridge.error("E_DENIED", "consent not resolved"))
            return
        }
        guard let host = bridge.hostController else {
            bridge.answer(id, false, ShellBridge.error("E_UNAVAILABLE", "no view controller"))
            return
        }
        AdsManager.start()
        if bannerView == nil {
            let view = BannerView(adSize: AdSizeBanner)
            view.adUnitID = bannerUnit
            let events = BannerEvents(owner: self)
            view.delegate = events
            bannerView = view
            bannerDelegate = events
            bannerState = State.loading
            host.installBanner(view)
            view.load(Request())
        }
        host.setBannerVisible(true)
        if bannerState == State.ready { bannerState = State.shown }
        emit("banner", bannerState, nil)
        bridge.answer(id, true, ["shown": true, "height": Int(host.bannerHeight())])
        host.emitViewport()
    }

    func hideBanner(_ id: String?) {
        bridge.hostController?.setBannerVisible(false)
        bannerState = State.hidden
        emit("banner", State.hidden, nil)
        bridge.answer(id, true, ["shown": false, "height": 0])
        bridge.hostController?.emitViewport()
    }

    fileprivate func bannerDidLoad() {
        bannerState = State.shown
        emit("banner", State.ready, nil)
        bridge.hostController?.emitViewport()
    }

    fileprivate func bannerFailed(_ error: Error?) {
        bannerState = State.none
        emit("banner", State.failed, error.map(AdsManager.message) ?? "load failed")
        // An empty strip under the page is worse than no banner: collapse it so
        // the WebView gets its height back.
        bridge.hostController?.setBannerVisible(false)
        bridge.hostController?.emitViewport()
    }

    /// The SDK view has to be dropped on shutdown or it keeps its own timers.
    func destroy() {
        waitingInterstitial?.work.cancel()
        waitingRewarded?.work.cancel()
        waitingInterstitial = nil
        waitingRewarded = nil
        bannerView?.delegate = nil
        bannerDelegate = nil
        interstitial = nil
        rewarded = nil
    }

    // MARK: - Presenters

    private final class InterstitialPresenter: NSObject, FullScreenContentDelegate {
        private let id: String?
        private weak var owner: AdsManager?

        init(id: String?, owner: AdsManager) {
            self.id = id
            self.owner = owner
            super.init()
        }

        func adDidDismissFullScreenContent(_ ad: FullScreenPresentingAd) {
            owner?.emit("interstitial", AdsManager.State.hidden, nil)
            owner?.bridge.answer(id, true, ["shown": true])
            owner?.refillInterstitial()
        }

        func ad(_ ad: FullScreenPresentingAd,
                didFailToPresentFullScreenContentWithError error: Error) {
            let message = (error as NSError).localizedDescription
            owner?.emit("interstitial", AdsManager.State.failed, message)
            owner?.bridge.answer(id, false, ShellBridge.error("E_UNAVAILABLE", message))
        }
    }

    private final class RewardedPresenter: NSObject, FullScreenContentDelegate {
        private let id: String?
        private weak var owner: AdsManager?

        init(id: String?, owner: AdsManager) {
            self.id = id
            self.owner = owner
            super.init()
        }

        func adDidDismissFullScreenContent(_ ad: FullScreenPresentingAd) {
            guard let owner = owner else { return }
            let earned = owner.earned
            let data: [String: Any] = [
                "rewarded": earned,
                "amount": earned ? owner.earnedAmount : "",
                "type": earned ? owner.earnedType : "",
            ]
            owner.earned = false
            owner.earnedAmount = ""
            owner.earnedType = ""
            owner.emit("rewarded", AdsManager.State.hidden, nil)
            owner.bridge.answer(id, true, data)
            owner.refillRewarded()
        }

        func ad(_ ad: FullScreenPresentingAd,
                didFailToPresentFullScreenContentWithError error: Error) {
            let message = (error as NSError).localizedDescription
            owner?.earned = false
            owner?.emit("rewarded", AdsManager.State.failed, message)
            owner?.bridge.answer(id, false, ShellBridge.error("E_UNAVAILABLE", message))
        }
    }

    private final class BannerEvents: NSObject, BannerViewDelegate {
        private weak var owner: AdsManager?

        init(owner: AdsManager) {
            self.owner = owner
            super.init()
        }

        func bannerViewDidReceiveAd(_ bannerView: BannerView) {
            owner?.bannerDidLoad()
        }

        func bannerView(_ bannerView: BannerView,
                        didFailToReceiveAdWithError error: Error) {
            owner?.bannerFailed(error)
        }
    }

    // MARK: - Events

    fileprivate func emit(_ format: String, _ state: String, _ message: String?) {
        var data: [String: Any] = ["format": format, "state": state]
        if let message = message { data["message"] = message }
        bridge.emit("ads.event", data)
    }

    // MARK: - Helpers

    /// A lazy show that found nothing: not an error, just a miss with a reason.
    private static func miss(_ error: Error) -> [String: Any] {
        let nsError = error as NSError
        return ["shown": false, "reason": nsError.code == noFillCode ? "no_fill" : "failed"]
    }

    private static func miss(_ reason: String) -> [String: Any] {
        ["shown": false, "reason": reason]
    }

    private static func message(_ error: Error) -> String {
        (error as NSError).localizedDescription
    }

    private static func loadError(_ error: Error) -> [String: Any] {
        let nsError = error as NSError
        if nsError.code == AdsManager.noFillCode {
            return ShellBridge.error("E_NO_FILL", nsError.localizedDescription)
        }
        return ShellBridge.error("E_UNAVAILABLE", nsError.localizedDescription)
    }
}
