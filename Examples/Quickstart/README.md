# Quickstart app

Create an iOS 15+ SwiftUI app and add `WtsSDK` through either Swift Package Manager or CocoaPods. Use only one dependency manager for the application target.

For Swift Package Manager, add `https://github.com/wetuscorp/wtsissdk-swift.git` in Xcode and select the exact `0.1.0-alpha.1` version.

For CocoaPods, add the following dependency to the application target and run `bundle exec pod install`:

```ruby
pod 'WtsSDK', '0.1.0-alpha.1'
```

Replace the generated app file with `QuickstartApp.swift`. Add `applinks:YOUR_APP_KEY.links.wts.is` to Associated Domains and replace the sample public app key. The SDK returns a path; production applications must map it through an explicit route allowlist.
