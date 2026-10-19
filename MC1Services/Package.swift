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
    .library(name: "MapperRawLog", targets: ["MapperRawLog"]),
    // MeshWX v5: the weather bot's wire codec (MeshWX_v5_Spec.md) plus the preload
    // tables every decode needs, because the mesh carries only indices and the phone
    // carries the words. See the target below.
    .library(name: "MeshWX", targets: ["MeshWX"])
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
      dependencies: ["MeshCore", "SurveyKit", "MeshWX"]
    ),
    // MeshWX v5 weather protocol: the wire codec, the preload tables it decodes
    // against, and the pure rendering rules of spec §10-11. The app's weather service
    // (queueing requests, storing warnings by identity, driving the map) lands in
    // MC1Services on top of this; the codec itself stays here.
    //
    // Dependency-free on purpose. It is a spec-driven binary format with nine official
    // wire vectors, and the only way to keep it honest is to run those vectors on every
    // build — which means `swift test` on macOS, with no radio, no BLE stack and no
    // CoreBluetooth entitlement in the way. Foundation (and OSLog) only; nothing here
    // imports SwiftUI, MapKit or MeshCore.
    //
    // Resources are the eleven files of the spec §9 preload bundle: the wire carries
    // indices (office byte, station u16, state byte, event byte) and never a name, so an
    // app without the tables can decode a warning but cannot say what or where it is.
    //
    // That includes zones.geojson and counties.geojson — 15 MB of the bundle's 17 MB.
    // Spec §9 makes them an optional download and the owner chose to bundle them anyway:
    // full area fills beat app size for a warning map, and a first-launch download is a
    // thing that fails in exactly the weather where this app matters. Bundling them is
    // not a promise that every area has a polygon: a UGC added after this bundle was cut
    // has none, so the fill path must always fall back to the centroid pins that
    // zones.json and counties.json carry (see MeshWXGeometry).
    //
    // Both are loaded lazily by MeshWXGeometry, never at launch.
    .target(
      name: "MeshWX",
      // Deliberately not named `Resources`: `.copy` keeps the directory name inside the
      // resource bundle, and a flat iOS bundle with a top-level `Resources/` is read as an
      // old-style versioned bundle — `codesign` rejects it ("bundle format unrecognized"),
      // which fails the app build even though `swift test` on macOS is happy.
      resources: [.copy("PreloadBundle")]
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
        "MeshWX",
        .product(name: "MeshCoreTestSupport", package: "MeshCore")
      ]
    ),
    .testTarget(
      name: "MapperRawLogTests",
      dependencies: ["MapperRawLog"]
    ),
    // The nine official wire vectors from the v5 kit ride along as a fixture so the
    // codec is checked against the publisher's own bytes, not against itself.
    .testTarget(
      name: "MeshWXTests",
      dependencies: ["MeshWX"],
      resources: [.copy("Fixtures")]
    )
  ]
)
