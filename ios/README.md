# iOS shell

Same page (`../web`), same contract (`../BRIDGE.md`), iOS host. Swift, UIKit,
programmatic: no storyboards, no CocoaPods, no committed `.xcodeproj`.

There is **no Mac in this project**, so the project is built by GitHub Actions
(`../.github/workflows/ios.yml`, `runs-on: macos-15`). Push and read the job
log; that is the compiler. Nothing here can be built or tested locally.

## What ships

| file | role |
|---|---|
| `project.yml` | XcodeGen spec: the only place sources, settings and packages are declared |
| `Sources/AppDelegate.swift` | starts the ad SDK, asks for notification permission up front, shows reminders as banners while foregrounded |
| `Sources/SceneDelegate.swift` | window + `ShellViewController` |
| `Sources/ShellViewController.swift` | `WKWebView` on `app://local/web/index.html`, keyboard events, navigation allowlist |
| `Sources/AssetSchemeHandler.swift` | serves the bundled `web/` folder over the custom scheme `app://local` |
| `Sources/ShellBridge.swift` | `WKScriptMessageHandler` named `shell`, op dispatch, `resolve`/`event` |
| `Sources/NotifyCenter.swift` | `notify.*` on `UNUserNotificationCenter` |
| `Sources/AdsManager.swift` | AdMob interstitial/rewarded + UMP consent |

`Shell.xcodeproj` and `Info.plist` are **generated** from `project.yml` and are
gitignored. Edit the spec, never the generated files.

## Ops on iOS

`device.info`, `haptics.impact`, `openExternal`, `share`, `screen.keepAwake`,
`screen.fullscreen`, `schedule.add`/`list`/`cancel`/`state`,
`notify.show`/`dismiss`/`permission` (`notify.schedule` and `notify.cancel` are
deprecated aliases), `ads.consent`,
`ads.interstitial.load`/`show`, `ads.rewarded.load`/`show`.

`screen.keepAwake` flips `UIApplication.isIdleTimerDisabled`.
`screen.fullscreen` answers `prefersStatusBarHidden` and
`prefersHomeIndicatorAutoHidden` from the flags in `Sources/Screen.swift`; both
are reset when the app goes to the background, the same rule Android applies on
pause. A full-screen `<video>` needs no host code here: the WKWebView player
brings its own controller, unlike Android, where the shell receives the view.
Element fullscreen (`element.requestFullscreen`) is enabled for iOS 15.4+ in
`ShellViewController.setUpWebView`, so the page's own fallback path works too.

Not on iOS, by contract or by absence:

- `toast` — Android only; the page must draw its own.
- `back` event — no hardware back button; the iOS gesture is disabled instead
  of being forwarded, because it would navigate the web history, not the app.
- `shell.review` — missing on both platforms today.

## Building

Locally, on a Mac (`xcodegen` from Homebrew):

```sh
cd ios
brew install xcodegen
xcodegen generate
open Shell.xcodeproj
```

In CI (what actually happens here): checkout, `brew install xcodegen`,
`xcodegen generate`, then two unsigned `xcodebuild` runs — simulator
(`-sdk iphonesimulator`, compile proof) and device (`-sdk iphoneos`,
`CODE_SIGNING_ALLOWED=NO`, link proof). Logs and the simulator build are
uploaded as the `ios-logs` artifact.

Signing is deliberately absent: a runner has no certificates, and adding one
turns every build into a secret-management problem. Use a local Mac or a signed
export when a real device build or an App Store upload is needed.

## Ads

The SDKs come from Google's Swift package manager repos
(`swift-package-manager-google-mobile-ads`, product `GoogleMobileAds`, which
pulls `GoogleUserMessagingPlatform` with it). Test ad units and Google's sample
app id are baked in (`Info.plist` `GADApplicationIdentifier`), so a build works
without an AdMob account. Replace, before release:

- `GADApplicationIdentifier` in `project.yml`
- the two unit ids at the top of `Sources/AdsManager.swift`

Behaviour matches Android: `E_DENIED` until consent resolves, `E_NO_FILL` when
the network has nothing, `E_UNAVAILABLE` otherwise, one cached ad per kind.

Two differences worth knowing, both already handled in the code:

- the no-fill error code is `1` on iOS (it is `3` on Android);
- the two Google SDKs both export a Swift type named `RequestError`, so
  ambiguity is avoided by reading `NSError` codes and messages instead.

Reminders use a daily repeating calendar trigger, so the system fires them even
when the app is not running; re-scheduling the same `id` replaces the previous
request (same as Android).
