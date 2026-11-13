// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "AidrobeKit",
    defaultLocalization: "zh-Hans",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "AidrobeKit", targets: ["AidrobeKit"]),
    ],
    targets: [
        .target(
            name: "AidrobeKit",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "AidrobeKitTests",
            dependencies: ["AidrobeKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
