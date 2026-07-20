# wts.is Swift SDK

Official iOS SDK for wts.is deep links, analytics, identity, and deployless Experiences.

> `0.5.0-alpha.1` · Mobile Protocol V4 · Experiences Protocol V2 · SDK Test Session V2 · iOS 15+ · Swift 5.9+

Pin this alpha exactly. The dashboard, backend, Swift/Android cores, and Flutter/React Native wrappers must use the coordinated `0.5.0-alpha.1` release.

## Install

Swift Package Manager:

```text
https://github.com/wetuscorp/wtsissdk-swift.git
Exact Version: 0.5.0-alpha.1
```

CocoaPods:

```ruby
pod 'WtsSDK', '0.5.0-alpha.1'
```

## One-time integration

The host owns the consent UI. Configure once, restore the stored decision to avoid asking twice, and send the decision when the user makes it:

```swift
import WtsSDK

try await WtsSDK.shared.configure(appKey: "YOUR_PUBLIC_APP_KEY")

switch await WtsSDK.shared.getConsentState() {
case .pending:
    showConsentUI()
case .granted, .denied:
    break
}

try await WtsSDK.shared.setConsent(.granted) // or .denied
```

After grant, existing registered events automatically drive campaigns selected in the dashboard:

```swift
try await WtsSDK.shared.track(
    eventKey: "purchase_completed",
    properties: ["plan": .string("pro")],
    revenue: WtsRevenue(amount: "49.90", currency: "TRY")
)

try await WtsSDK.shared.screen("checkout")
```

No campaign key, placement key, verification key, allowlist, manual renderer, or acknowledgement API belongs in the host application. The SDK refreshes root-verified, source-bound configuration in the foreground and presents supported modal or bottom-sheet Experiences automatically.

Pending and denied states create no install identity and perform no analytics, identity, attribution, Experience, or test-session storage/network work. `handle(url:)` remains available through the data-minimized Mobile V4 functional resolver. Grant enables normal attribution; denial clears local SDK data and closes an active Experience.

## Actions and diagnostics

HTTPS web actions and safe deep links are handled by the SDK. Internal routes and custom callbacks are optional advanced integrations:

```swift
await WtsSDK.shared.onExperienceAction { experience, action in
    guard action.type == .openInternalRoute, let route = action.target else {
        return false
    }
    return router.open(route)
}
```

Returning `false`, omitting the handler, or failing the action records `unhandled` and keeps the Experience open. Unsafe schemes including `http`, `about`, `data`, `file`, and `javascript` are rejected.

```swift
let diagnostics = await WtsSDK.shared.getExperienceDiagnostics()
await WtsSDK.shared.dismissCurrentExperience() // emergency host control
```

## Identity and links

Identity APIs use the same unified grant:

```swift
try await WtsSDK.shared.identify("customer_1842", attributes: ["plan": .string("enterprise")])
```

Forward Universal Links to `handle(url:)`, validate the returned application route, and navigate in host code. `linkId` and `attributionId` are nil for pre-consent functional resolves.

## SDK Test & Validate

Test Session V2 is available only after unified consent is granted. A ready test Experience is shown through the automatic renderer in an isolated test queue and never enters the production Experience queue.

## Trust and release

The long-lived root private key must never enter this repository or backend. The
release environment supplies the ceremony-produced base64 SPKI Ed25519 public
key as `WTS_EXPERIENCE_ROOT_PUBLIC_KEY`; the release workflow validates and
embeds it into `Sources/WtsSDK/ExperienceTrust.swift` before compiling. It
fails closed if the variable is missing, malformed, or not Ed25519. Normal
online leaf-key rotation then requires no app deployment.
