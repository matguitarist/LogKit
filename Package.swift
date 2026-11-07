// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LogKit",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        // Parsing, filtering, the app's own log store. No SwiftUI.
        .library(name: "LogKit", targets: ["LogKit"]),
        // The log viewer. Re-exports LogKit.
        .library(name: "LogKitUI", targets: ["LogKitUI"]),
    ],
    targets: [
        .target(name: "LogKit"),
        .target(name: "LogKitUI", dependencies: ["LogKit"], resources: [.process("Resources")]),
        .testTarget(name: "LogKitTests", dependencies: ["LogKit"]),
    ]
)
