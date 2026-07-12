import SwiftUI
import WtsSDK

@main
struct QuickstartApp: App {
    @State private var route = "No deep link"

    var body: some Scene {
        WindowGroup {
            Text(route)
                .task { try? await WtsSDK.shared.configure(appKey: "replace-with-public-app-key") }
                .onOpenURL { url in
                    Task {
                        if let link = try? await WtsSDK.shared.handle(url: url) {
                            route = "Resolved \(link.path)"
                        }
                    }
                }
        }
    }
}
