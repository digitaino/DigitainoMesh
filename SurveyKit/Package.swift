// swift-tools-version:6.0
import PackageDescription

// SurveyKit is the logic core of the signal mapper (docs/SIGNAL_MAPPER_V2.md):
// grid math, sampling policy, quality thresholds, validation limits, and request
// signing. It compiles into the iOS app; the TypeScript server does not link it but
// consumes the same shared test fixtures (HMAC + wire vectors), so the two sides
// cannot drift silently.
//
// CH3 vendors the official uber/h3 C library (Apache-2.0, v4.4.1) — see
// Sources/CH3/LICENSE. Only SurveyKit's SurveyGrid wraps it; no other target may
// import CH3 directly.
let package = Package(
    name: "SurveyKit",
    platforms: [
        .iOS(.v18),
        .macOS(.v14),
    ],
    products: [
        .library(name: "SurveyKit", targets: ["SurveyKit"])
    ],
    dependencies: [
        // HMAC request signing shared by client and server (works on Linux too).
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0")
    ],
    targets: [
        .target(
            name: "CH3",
            exclude: ["LICENSE"]
        ),
        .target(
            name: "SurveyKit",
            dependencies: [
                "CH3",
                .product(name: "Crypto", package: "swift-crypto"),
            ]
        ),
        .testTarget(
            name: "SurveyKitTests",
            dependencies: ["SurveyKit"]
        ),
    ]
)
