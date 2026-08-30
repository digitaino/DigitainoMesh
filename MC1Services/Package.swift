// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "MC1Services",
  platforms: [.iOS(.v18), .macOS(.v15)],
  products: [
    .library(name: "MC1Services", targets: ["MC1Services"]),
    // Raw ride log for the signal mapper's active-survey mode
    // (docs/ACTIVE_SURVEY_M3_5.md §2.4). See the target below for why it is a separate
    // module rather than a folder inside MC1Services.
    .library(name: "MapperRawLog", targets: ["MapperRawLog"])
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
    // THE DEPENDENCY DIRECTION IS THE PRIVACY GUARANTEE: MC1Services must never import
    // MapperRawLog (cycle = compile error), so no future upload code in MC1Services can
    // reach raw rows.
    //
    // The raw ride log is the one store in the app that keeps precise coordinates, full
    // repeater public keys and per-event timestamps (docs/ACTIVE_SURVEY_M3_5.md §3). The
    // aggregate mapper pipeline that M2 uploads from lives in MC1Services and must stay
    // structurally unable to see any of it. A folder, a naming convention or a code
    // review would all be things somebody can forget; a dependency edge is checked by the
    // compiler on every build.
    .target(
      name: "MapperRawLog",
      dependencies: ["MC1Services"]
    ),
    .testTarget(
      name: "MC1ServicesTests",
      dependencies: [
        "MC1Services",
        .product(name: "MeshCoreTestSupport", package: "MeshCore")
      ]
    ),
    .testTarget(
      name: "MapperRawLogTests",
      dependencies: ["MapperRawLog"]
    )
  ]
)
