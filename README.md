# wts.is Swift SDK

Official, source-based SDK for wts.is deep links and mobile attribution. It resolves verified Universal Links, returns an application-owned route, and queues registered custom events and revenue safely while offline. The SDK never navigates your UI.

> `0.3.0-alpha.1` · Mobile Protocol V3 + Identity V1 + Experiences V1 · iOS 15+ · Swift 5.9+

## Installation

Use one dependency manager per application target. Swift Package Manager and CocoaPods ship the same source, module name, privacy manifest, minimum deployment target, and SDK version.

### Swift Package Manager

In Xcode choose **File → Add Package Dependencies** and enter:

```text
https://github.com/wetuscorp/wtsissdk-swift.git
```

Select the exact `0.3.0-alpha.1` version, link the `WtsSDK` product to the application target, then:

```swift
import WtsSDK
```

### CocoaPods

Add the CDN source and pin the same SDK version in your `Podfile`:

```ruby
source 'https://cdn.cocoapods.org/'

platform :ios, '15.0'

target 'YourApp' do
  pod 'WtsSDK', '0.3.0-alpha.1'
end
```

Then install the dependency:

```bash
bundle exec pod install
```

Open the generated `.xcworkspace` and import `WtsSDK`. Do not add the package through Swift Package Manager when the same application target already receives it through CocoaPods.

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

## Screens and Experiences

Screen views are built-in Mobile Protocol V3 events and do not require a
custom-event definition:

```swift
try await WtsSDK.shared.screen(
    "checkout",
    properties: [
        "cart_total": .number(749.90),
        "currency": .string("TRY"),
        "item_count": .number(3)
    ]
)
```

Experiences remains disabled until the host opts in and supplies a separate
consent decision:

```swift
var options = WtsOptions()
options.experiences = WtsExperienceOptions(
    enabled: true,
    renderMode: .automatic,
    allowedInternalRoutes: ["/checkout", "/account"],
    allowedCallbackKeys: ["apply_offer"],
    allowedDeepLinkHosts: ["go.example.com"],
    allowedDeepLinkSchemes: ["example"],
    allowedWebOrigins: ["https://www.example.com"]
)
try await WtsSDK.shared.configure(appKey: "YOUR_PUBLIC_APP_KEY", options: options)
try await WtsSDK.shared.setExperienceConsent(.contextual)
```

Use `.personalized` only after profile consent. `.pending` makes no Experience
request; `.denied` clears local Experience state and unsent interactions.
Automatic mode uses native modal or bottom-sheet presentation. Manual mode
delivers an eligible `WtsExperience` through `onExperienceAvailable` and waits
for `presentNextExperience()`. Application callbacks remain behind the
configured allowlist.

Experience interactions use their own persistent, bounded FIFO queue and UUID
idempotency. Impressions are emitted after one uninterrupted second of native
visibility. `dismissCurrentExperience()` and
`getExperienceDiagnostics()` provide lifecycle and integration control.

To test an unpublished revision on this installation, read
`await WtsSDK.shared.getExperienceDiagnostics().testDeviceToken` and grant it
to the matching Mobile App from the dashboard. The random source-scoped token
contains no install, user, or profile identifier, and test traffic is excluded
from customer analytics and usage.

## User identity and reported attribution

Profile operations require an explicit consent decision from the host application. Use your own stable, opaque customer ID rather than an email address as `externalUserId`; the value is case-sensitive and is not trimmed or normalized.

```swift
try WtsSDK.shared.setProfileConsent(.granted)

try WtsSDK.shared.identify(
    "customer_1842",
    attributes: [
        "email": .string("user@example.com"),
        "plan": .string("enterprise"),
        "subscribed": .boolean(true)
    ]
)

try WtsSDK.shared.updateUser(
    WtsUserUpdate(
        set: ["plan": .string("business")],
        setOnce: ["signup_channel": .string("partner")],
        increment: ["lifetime_orders": 1]
    )
)

try WtsSDK.shared.setReportedAttribution(
    WtsReportedAttribution(
        source: "newsletter",
        medium: "email",
        campaign: "summer_2026",
        externalRef: "mailing-482"
    )
)
```

Call `resetIdentity()` on logout. It removes the current profile binding, rotates the anonymous/session context and preserves the installation identity used for deterministic mobile delivery. Setting profile consent to `.denied` also queues a binding reset while anonymous analytics remains available. Identity mutations use a persistent FIFO queue and are flushed before events.

## Platform behavior

- `handle(url:)` has a 2-second default timeout and a 100-entry/60-second memory cache.
- Errors are typed and retain the original web fallback URL where applicable.
- The install UUID is generated locally and stored in Keychain.
- `getDeferredDeepLink()` intentionally returns `nil` on iOS; deterministic post-install deferred attribution is not promised.
- No IDFA, pasteboard attribution, GAID, fingerprinting, or automatic navigation.

See the installable sample in `Examples/Quickstart`, [security policy](SECURITY.md), and [support policy](SUPPORT.md). Full integration documentation: https://wts.is/en/resources/docs/sdk-ios
