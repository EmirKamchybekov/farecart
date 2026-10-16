// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "FarecartKit",
    defaultLocalization: "en",
    platforms: [.iOS(.v26), .macOS(.v15)],
    products: [
        .library(name: "FarecartKit", targets: ["FarecartKit"])
    ],
    targets: [
        // Pure Foundation. No UIKit / SwiftUI / MapKit so it builds and tests on macOS with `swift test`.
        .target(
            name: "FarecartKit",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "FarecartKitTests",
            dependencies: ["FarecartKit"],
            resources: [.copy("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
