# AppeekyAnalytics for iOS (Swift)

Native Swift SDK for Appeeky Analytics. It records installs, sessions, screens
and your own events, and links each install to the RevenueCat customer (or
Superwall user), so your Appeeky Analytics server can show revenue by install
source: Apple Search Ads, a campaign or smart link, or organic store traffic.
It behaves like the React Native / Expo SDK
([`@appeeky/analytics-expo`](https://www.npmjs.com/package/@appeeky/analytics-expo)) and sends the same data.

- No IDFA, no App Tracking Transparency prompt. The install id is a random id
  stored in the app.
- Events are queued on the device and sent in batches. They survive offline
  periods and app restarts.
- Apple Search Ads attribution (AdServices) and SKAdNetwork /
  AdAttributionKit conversion values are built in.
- iOS 15+, Swift 5.9+, no third-party dependencies. Thread-safe: call it from
  any thread.

## Install

Swift Package Manager. In Xcode: **File › Add Package Dependencies…**, enter
`https://github.com/appeeky/analytics-swift.git` and add the `AppeekyAnalytics`
library to your app target.
In a `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/appeeky/analytics-swift.git", from: "0.1.0"),
],
targets: [
    .target(name: "MyApp", dependencies: [
        .product(name: "AppeekyAnalytics", package: "AppeekyAnalytics"),
    ]),
]
```

### Info.plist

Add these keys so iOS sends copies of winning SKAdNetwork and
AdAttributionKit postbacks to Appeeky. (The Expo SDK's config plugin adds them
for you; a native app adds them by hand.)

```xml
<key>NSAdvertisingAttributionReportEndpoint</key>
<string>https://appeeky.com</string>
<key>AdAttributionKit</key>
<dict>
    <key>AttributionCopyEndpoint</key>
    <string>https://appeeky.com</string>
</dict>
```

When self-hosting, use your server's registrable domain instead, e.g.
`https://example.com`. Leave them out if another provider already receives
the copies (an app can name only one endpoint).

If your app opens through a URL scheme or universal links, nothing else is
needed in Info.plist for the SDK.

## Set up

Get the app's publishable key (`apk_…`): in Appeeky, turn on Analytics for
the app; on a self-hosted server, create the app (see the
[self-hosting guide](https://docs.appeeky.com/docs/analytics-self-hosting)). The key ships inside your app, so it
can only write events for that app.

Call `configure` once, as early as possible.

**SwiftUI**

```swift
import AppeekyAnalytics
import SwiftUI

@main
struct MyApp: App {
    init() {
        Appeeky.configure(key: "apk_...")
        // Self-hosted: Appeeky.configure(key: "apk_...", endpoint: URL(string: "https://analytics.example.com/v1/ingest")!)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .onOpenURL { Appeeky.handleOpenURL($0) }
                .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { Appeeky.handleUserActivity($0) }
        }
    }
}
```

**UIKit app delegate**

```swift
import AppeekyAnalytics

func application(_ application: UIApplication,
                 didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
    Appeeky.configure(key: "apk_...")
    Appeeky.handleLaunchOptions(launchOptions)
    return true
}

func application(_ app: UIApplication, open url: URL, options: [UIApplication.OpenURLOptionsKey: Any] = [:]) -> Bool {
    Appeeky.handleOpenURL(url)
    return true // or your own routing result
}

func application(_ application: UIApplication, continue userActivity: NSUserActivity,
                 restorationHandler: @escaping ([UIUserActivityRestoring]?) -> Void) -> Bool {
    Appeeky.handleUserActivity(userActivity)
    return true
}
```

**Scene delegate**

```swift
func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
    Appeeky.handleConnectionOptions(connectionOptions) // cold start through a link
    // …
}

func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
    URLContexts.forEach { Appeeky.handleOpenURL($0.url) }
}

func scene(_ scene: UIScene, continue userActivity: NSUserActivity) {
    Appeeky.handleUserActivity(userActivity)
}
```

All options:

```swift
Appeeky.configure(AppeekyOptions(
    key: "apk_...",
    endpoint: nil,                    // Appeeky hosted; self-hosted: ".../v1/ingest"
    flushInterval: 10,                // seconds
    flushAt: 20,
    maxQueueSize: 1_000,
    sessionTimeout: 30 * 60,          // seconds in the background before a new session
    resolveAdServicesOnDevice: true,
    context: DeviceContext(appVersion: "2.3.0"), // override detected fields
    disabled: false,                  // collect and send nothing, e.g. after an opt-out
    debug: false                      // log rejected batches and network errors
))
```

| Option | Default | |
| --- | --- | --- |
| `key` | required | Publishable key (`apk_…`) |
| `endpoint` | Appeeky hosted | A self-hosted server's ingest URL, ending in `/v1/ingest` |
| `resolveAdServicesOnDevice` | `true` | Exchange the AdServices token with Apple from the device |
| `adServicesToken` | built in | Replace the `AAAttribution.attributionToken()` call |
| `flushInterval` | `10` s | How often queued events are sent while the app is open |
| `flushAt` | `20` | Send as soon as this many events are queued |
| `maxQueueSize` | `1000` | Oldest events are dropped beyond this |
| `sessionTimeout` | `1800` s | Time in the background before a new session starts |
| `context` | | Override device context fields |
| `disabled` | `false` | Collect and send nothing |
| `debug` | `false` | Log rejected batches and network errors (os.Logger, subsystem `com.appeeky.analytics`) |

`Appeeky.installId` returns this install's id right after `configure`.

## Identify with RevenueCat or Superwall

```swift
import RevenueCat

Appeeky.identify(Purchases.shared.appUserID)

// After a login:
let (customerInfo, _) = try await Purchases.shared.logIn(userId)
Appeeky.identify(userId)

// On logout:
Appeeky.identify(nil)
```

With Superwall, pass the same user id you give `Superwall.shared.identify(userId:)`;
Superwall's webhook events are matched to the install by it. The id is sent
with every batch, and `identify` makes a batch go out within about a second
so the install is linked before the first purchase.

## Screens and events

```swift
Appeeky.screen("Paywall")
Appeeky.track("onboarding_completed", properties: ["step": 3])
Appeeky.track("export", properties: ["format": "pdf", "shared": true], value: 1)
```

In SwiftUI, call `screen` from `.onAppear` of each top-level view; in UIKit,
from `viewDidAppear`.

Event names may use letters, digits, `_`, `.`, `:` and `-`, up to 64
characters (the server rejects a batch with any other name; `debug: true`
warns about it). Property values are strings (up to 512 characters), numbers,
booleans or `nil`.

`Appeeky.flush()` (async, or `flush(completion:)`) sends everything queued now.
The SDK flushes on its own every `flushInterval`, at `flushAt` events and when
the app goes to the background (inside a short background task).

### What is collected automatically

| Event | When |
| --- | --- |
| `first_open` | First launch after install |
| `session_start` | Launch, or returning after `sessionTimeout` in the background |
| `app_background` | Going to the background, with `foreground_ms`: time on screen since the app came to the foreground. Session time is the sum per session. |
| `identify` / `reset` | `identify(id)` / `identify(nil)` |
| `ad_revenue` | `adRevenue(_:network:adUnit:format:)` |

Foreground and background come from `UIApplication.didBecomeActiveNotification`
and `didEnterBackgroundNotification`. When the system launches the app in
the background (background fetch, a silent push), the first session starts
when the user actually opens it.

## Deep links and smart links

Hand the SDK every URL that opens the app (see *Set up*). Only the first one
counts: on the first launch it is sent as the install's attribution, so
`aky_c=<campaign>` or `utm_*` parameters make it a campaign link install, and
an Appeeky smart link (`aky_l=`) a smart link install. The SDK waits up to two
seconds after `configure` for the URL to arrive.

Create a smart link for a campaign in Appeeky (or `POST /v1/apps/:id/links`
on your server). On iOS it opens the app through its URL scheme when it is
installed (with the campaign appended), otherwise the App Store. iOS has no
deferred deep link through the App Store: matching an install back to a click
needs device fingerprinting, which Apple doesn't allow.

```swift
// First launch opened by a smart link: route the user once.
if let destination = await Appeeky.deferredDeepLink() {
    router.open(destination)
}
```

`deferredDeepLink()` returns the smart link that opened the app on its first
launch, once; `nil` afterwards or when there is none.

## SKAdNetwork and AdAttributionKit

The SDK keeps the SKAdNetwork (iOS 15.4+) and AdAttributionKit (iOS 17.4+)
conversion value up to date so paid campaigns on ad networks report what
installs did. Values only go up:

| Fine value | Coarse | Set by |
| --- | --- | --- |
| 1 | low | first launch (automatic) |
| 2 | medium | came back on a later day (automatic) |
| 8 | medium | `Appeeky.trialStarted()` |
| 16–63 | high | `Appeeky.purchased(valueUsd)`: 16 + $2 steps, capped at $94+ |

```swift
// After a RevenueCat purchase succeeds:
Appeeky.purchased(29.99)
```

`purchased` and `trialStarted` only update the conversion value; revenue
itself comes from RevenueCat or Superwall, so nothing is counted twice.

### Ad revenue

For ad-monetized apps, report each paid impression in USD from your ad SDK's
paid-event callback. It counts as revenue for the install's source.

```swift
Appeeky.adRevenue(0.0042, network: "my_network", adUnit: "rewarded_home", format: "rewarded")
```

## Attribution

| Source | How it is detected |
| --- | --- |
| Campaign link | The URL the app was first opened with carries `aky_c=<campaign>` or `utm_*` parameters. |
| Smart link | The smart link opened the app on its first launch. |
| Apple Search Ads | `AAAttribution.attributionToken()`. The SDK exchanges the token with Apple for the campaign, ad group and keyword, and sends both. If Apple doesn't answer yet, the server retries with the token for up to 24 hours. |
| Organic | Everything else. |

Attribution is collected once, on the first launch. The token and the launch
URL each have 3 seconds to arrive.

## Privacy

The SDK sends the install id, app version, OS version, device model, locale
and the events you track. It never reads advertising identifiers. The package
ships a privacy manifest (`PrivacyInfo.xcprivacy`: no tracking, product
interaction for analytics). In App Store Connect, declare **Usage Data ›
Product Interaction** and **Purchases** as *not linked to the user's
identity* and *not used for tracking*. If your RevenueCat app user id is a
real account id, declare those data types as *linked* instead.

State and the event queue are kept in
`Application Support/AppeekyAnalytics/` (`state.json`, `queue.json`).
Pass `disabled: true` to `configure` after a user opts out.

## Development

```sh
swift build && swift test             # client logic on the Mac host
xcodebuild -scheme AppeekyAnalytics -destination 'generic/platform=iOS Simulator' build
```

Smoke test against a running server (skipped unless both variables are set):

```sh
APPEEKY_SMOKE_ENDPOINT=http://localhost:8817/v1/ingest APPEEKY_SMOKE_KEY=apk_... \
  swift test --filter SmokeTests
```
