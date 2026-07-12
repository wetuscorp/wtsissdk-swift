# wts.is Swift SDK

Official, source-based SDK for wts.is deep links and mobile attribution. It resolves verified Universal Links, returns an application-owned route, and queues registered custom events and revenue safely while offline. The SDK never navigates your UI.

> `0.1.0-alpha.1` · protocol V1 · iOS 15+ · Swift 5.9+

## Install

In Xcode choose **File → Add Package Dependencies** and enter:

```text
https://github.com/wetuscorp/wtsissdk-swift.git
```

Select `0.1.0-alpha.1` and link `WtsSDK`. CocoaPods is temporarily supported with `pod 'WtsSDK', '0.1.0-alpha.1'`.

## Configure and handle links

```swift
import WtsSDK

try await WtsSDK.shared.configure(appKey: "YOUR_PUBLIC_APP_KEY")

func open(_ url: URL) async {
    do {
        let link = try await WtsSDK.shared.handle(url: url)
        guard allowedRoutes.contains(link.path) else { return }
        router.navigate(path: link.path, parameters: link.parameters)
    } catch let error as WtsSDKError {
        if let fallback = error.fallbackURL { await openInBrowser(fallback) }
    } catch { /* application logging */ }
}
```

Forward URLs from SwiftUI `onOpenURL` or `application(_:continue:restorationHandler:)`. Configure the app's Associated Domains entitlement with the exact host shown in the wts.is dashboard. Universal Link association is required on both the app and domain.

## Events and revenue

Register event keys and typed properties in the dashboard first. Revenue uses a decimal string internally to avoid binary rounding.

```swift
try await WtsSDK.shared.track(
    eventKey: "purchase_completed",
    properties: ["plan": .string("pro"), "trial": .boolean(false)],
    revenue: WtsRevenue(amount: "49.90", currency: "TRY")
)
await WtsSDK.shared.flush() // optional; automatic flushing is enabled
```

The queue is atomic, FIFO and bounded to 100 events/1 MiB. Batches are capped at 50 events/64 KiB. Retriable failures use exponential backoff with jitter; accepted, duplicate and permanently rejected IDs are removed.

## Platform behavior

- `handle(url:)` has a 2-second default timeout and a 100-entry/60-second memory cache.
- Errors are typed and retain the original web fallback URL where applicable.
- The install UUID is generated locally and stored in Keychain.
- `getDeferredDeepLink()` intentionally returns `nil` on iOS in protocol V1.
- No IDFA, pasteboard attribution, GAID, fingerprinting, or automatic navigation.

See the installable sample in `Examples/Quickstart`, [security policy](SECURITY.md), and [support policy](SUPPORT.md). Full integration documentation: https://wts.is/docs/sdk/ios
