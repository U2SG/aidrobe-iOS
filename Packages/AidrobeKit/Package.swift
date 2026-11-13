// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "AidrobeKit",
    defaultLocalization: "zh-Hans",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "AidrobeKit", targets: ["AidrobeKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-openapi-generator", from: "1.10.0"),
        .package(url: "https://github.com/apple/swift-openapi-runtime", from: "1.8.0"),
    ],
    targets: [
        // Wire models are generated from contracts/openapi.json (types only);
        // transport, envelope handling and auth stay in APIClient.
        .target(
            name: "AidrobeKit",
            dependencies: [.product(name: "OpenAPIRuntime", package: "swift-openapi-runtime")],
            swiftSettings: [.swiftLanguageMode(.v6)],
            plugins: [.plugin(name: "OpenAPIGenerator", package: "swift-openapi-generator")]
        ),
        .testTarget(
            name: "AidrobeKitTests",
            dependencies: ["AidrobeKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
