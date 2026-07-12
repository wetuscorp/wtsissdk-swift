// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "WtsSDK",
    platforms: [.iOS(.v15), .macOS(.v12)],
    products: [.library(name: "WtsSDK", targets: ["WtsSDK"])],
    targets: [
        .target(name: "WtsSDK", resources: [.process("Resources")]),
        .testTarget(name: "WtsSDKTests", dependencies: ["WtsSDK"])
    ]
)
