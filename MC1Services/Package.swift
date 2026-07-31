// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "MC1Services",
  platforms: [.iOS(.v18), .macOS(.v15)],
  products: [
    .library(name: "MC1Services", targets: ["MC1Services"])
  ],
  dependencies: [
    .package(path: "../MeshCore"),
    // Signal mapper logic core: H3 grid math, sampling policy, aggregation, request
    // signing (docs/SIGNAL_MAPPER_V2.md). MC1Services owns the persistence and capture
    // layers on top of it; nothing else in the app links SurveyKit directly.
    .package(path: "../SurveyKit")
  ],
  targets: [
    .target(
      name: "MC1Services",
      dependencies: ["MeshCore", "SurveyKit"]
    ),
    .testTarget(
      name: "MC1ServicesTests",
      dependencies: [
        "MC1Services",
        .product(name: "MeshCoreTestSupport", package: "MeshCore")
      ]
    )
  ]
)
