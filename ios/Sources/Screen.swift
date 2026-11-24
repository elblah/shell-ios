import UIKit

/**
 The two screen states the page can ask for, kept in one place so the host has
 a single answer to both: bars hidden (immersive) and display kept lit.

 Android keeps the same pair in `Screen.java`. iOS has no window flag to flip:
 the status bar and the home indicator are answered by the view controller that
 asks this object (`prefersStatusBarHidden`, `prefersHomeIndicatorAutoHidden`),
 and the display is kept lit through the shared application's idle timer.
 */
final class Screen {

    static let shared = Screen()

    /// Page asked for the system bars to go away.
    var immersive = false
    /// Page asked to keep the display lit while it is in front.
    var awake = false

    private init() {}

    func setAwake(_ on: Bool) {
        awake = on
        UIApplication.shared.isIdleTimerDisabled = on
    }

    /**
     Whatever the page asked for dies with the page: a reminder cannot keep the
     display lit, and a restored page must not find the bars gone. Mirrors
     `ShellBridge.onPause` on Android.
     */
    func reset() {
        setAwake(false)
        immersive = false
    }
}
