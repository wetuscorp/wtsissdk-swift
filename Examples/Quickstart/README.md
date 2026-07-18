# Quickstart app

Create an iOS 15+ SwiftUI app and add `WtsSDK` through either Swift Package Manager or CocoaPods. Use only one dependency manager for the application target.

For Swift Package Manager, add `https://github.com/wetuscorp/wtsissdk-swift.git` in Xcode and select a matching published SDK version. SDK Test & Validate requires a published release that explicitly includes the `0.4.0-alpha.1` source-line APIs; this README does not imply a registry release exists.

For CocoaPods, add the following dependency to the application target and run `bundle exec pod install`:

```ruby
pod 'WtsSDK', '<matching-published-version>'
```

Replace the generated app file with `QuickstartApp.swift`. Add `applinks:YOUR_APP_KEY.links.wts.is` to Associated Domains and replace the sample public app key. The SDK returns a path; production applications must map it through an explicit route allowlist.

## SDK Test & Validate

When a dashboard QR opens
`https://<mobile-app-host>/_wts/test/pair?pairing=<dashboard-issued-token>`,
pass that URL to `WtsTestSessionPairing.parse` and
`await WtsSDK.shared.joinTestSession(...)` before the regular `handle(url:)`
flow. Pairing links are not application routes.

After a successful join, show `getTestSessionDiagnostics()`, call
`runTestSessionProbes()`, and use `probeTestSessionUrl(_:)` for a resolver-only
check. A `ready` `experienceDecision` is a manual test preview only; after its
real display or action call `reportTestSessionExperienceInteraction(.impression)`
or `.action`. End the short-lived session with `leaveTestSession()`. No test
operation is sent to normal analytics or Experiences delivery.
